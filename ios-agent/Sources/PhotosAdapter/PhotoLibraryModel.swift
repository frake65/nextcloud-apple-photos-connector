import Foundation
import Combine
import Photos
import UIKit
import InventoryCore

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var authorization: PhotoAuthorizationState
    @Published private(set) var assets: [GalleryAsset] = []
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedInitialState = false
    @Published private(set) var errorMessage: String?

    private let imageManager = PHCachingImageManager()
    private var refreshTask: Task<Void, Never>?

    init() {
        IOSImportDiagnostics.log("[Startup] PhotoKit model init")
        authorization = PhotoAuthorizationState(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        hasLoadedInitialState = authorization != .notDetermined && !authorization.canRead
    }

    func requestAccess() {
        guard authorization == .notDetermined else { refreshAuthorizationAndLoad(); return }
        IOSImportDiagnostics.log("[Startup] PhotoKit authorization request begin")
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                IOSImportDiagnostics.log("[Startup] PhotoKit authorization callback")
                guard let self else { return }
                self.authorization = PhotoAuthorizationState(status: status)
                if self.authorization.canRead { self.loadLibrary() }
                else { self.hasLoadedInitialState = true }
            }
        }
    }

    func refreshAuthorizationAndLoad() {
        authorization = PhotoAuthorizationState(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if authorization.canRead { loadLibrary() }
        else {
            assets = []; albums = []
            if authorization != .notDetermined { hasLoadedInitialState = true }
        }
    }

    func loadLibrary() {
        guard authorization.canRead else { return }
        IOSImportDiagnostics.log("[Startup] PhotoKit load begin")
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            self.errorMessage = nil
            defer { self.isLoading = false; self.hasLoadedInitialState = true }
            let fetched = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [GalleryAlbum]) in
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                var all: [PHAsset] = []
                result.enumerateObjects { asset, _, _ in
                    if asset.mediaType == .image || asset.mediaType == .video { all.append(asset) }
                }
                let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                var albums: [GalleryAlbum] = []
                collections.enumerateObjects { collection, _, _ in
                    let albumOptions = PHFetchOptions()
                    albumOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    let members = PHAsset.fetchAssets(in: collection, options: albumOptions)
                    let count = members.countOfAssets(with: .image) + members.countOfAssets(with: .video)
                    guard count > 0 else { return }
                    albums.append(GalleryAlbum(collection: collection, count: count, cover: members.firstObject))
                }
                return (all, albums.sorted { ($0.collection.localizedTitle ?? "") < ($1.collection.localizedTitle ?? "") })
            }.value
            guard !Task.isCancelled else { return }
            self.assets = fetched.0.map(GalleryAsset.init).sorted { $0.creationDate > $1.creationDate }
            self.albums = fetched.1
            IOSImportDiagnostics.log("[Startup] PhotoKit load end")
        }
    }

    func assets(in album: GalleryAlbum) -> [GalleryAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album.collection, options: options)
        var assets: [GalleryAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(GalleryAsset(asset: asset))
        }
        return assets.sorted { $0.creationDate > $1.creationDate }
    }

    func inventory(for selection: [GalleryAsset]) throws -> [AssetInventory] {
        let localIDs = selection.map(\.id)
        guard Set(localIDs).count == localIDs.count else { throw InventoryCheckError.invalidResponse }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil)
        var available: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in available[asset.localIdentifier] = asset }
        guard available.count == localIDs.count else { throw InventoryCheckError.unavailableAsset }

        let cloudMappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIDs)
        return try localIDs.map { localID in
            guard let asset = available[localID] else { throw InventoryCheckError.unavailableAsset }
            let cloudIdentifier: String?
            if case .success(let identifier)? = cloudMappings[localID] { cloudIdentifier = IOSCloudIdentifierCodec.encode(identifier) }
            else { cloudIdentifier = nil }
            let preferredType: PHAssetResourceType? = switch asset.mediaType {
            case .image: .photo
            case .video: .video
            default: nil
            }
            let mediaType: String = asset.mediaType == .video ? "video" : "image"
            let originalFilename = preferredType.flatMap { type in PHAssetResource.assetResources(for: asset).first { $0.type == type }?.originalFilename }
            let filename = IOSFilenamePolicy.resolved(originalFilename: originalFilename, localIdentifier: localID, mediaType: mediaType)
            if originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { IOSImportDiagnostics.log("inventory filename fallback asset=\(localID.prefix(8)) mediaType=\(mediaType)") }
            return PhotoKitInventoryMapper.make(localIdentifier: localID, cloudIdentifier: cloudIdentifier, mediaType: mediaType, creationDate: asset.creationDate, filename: filename)
        }
    }

    func albumInventory() throws -> [AlbumInventory] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        let albumIDs = (0..<collections.count).map { collections.object(at: $0).localIdentifier }
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: albumIDs)
        var memberAssets: [(PHAssetCollection, [PHAsset])] = []
        var memberIDs: [String] = []
        collections.enumerateObjects { collection, _, _ in
            let members = PHAsset.fetchAssets(in: collection, options: PHFetchOptions())
            var filtered: [PHAsset] = []
            members.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                filtered.append(asset); memberIDs.append(asset.localIdentifier)
            }
            memberAssets.append((collection, filtered))
        }
        let memberMappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: Array(Set(memberIDs)))
        var result: [AlbumInventory] = []
        for (collection, members) in memberAssets {
            var identities: [String] = []
            for asset in members {
                if case .success(let cloud)? = memberMappings[asset.localIdentifier] {
                    identities.append("cloud:\(IOSCloudIdentifierCodec.encode(cloud))")
                } else { identities.append("local:\(asset.localIdentifier)") }
            }
            let cloudID: String? = mappings[collection.localIdentifier].flatMap { result in
                if case .success(let cloud) = result { return IOSCloudIdentifierCodec.encode(cloud) }
                return nil
            }
            result.append(AlbumInventory(localIdentifier: collection.localIdentifier, cloudIdentifier: cloudID, name: collection.localizedTitle ?? "Album", assetIdentities: identities))
        }
        return result
    }

    struct ExportedOriginal: Sendable {
        let url: URL
        let filename: String
        let resourceType: PHAssetResourceType
    }

    /// Exports the same deterministic .photo/.video resource rule used by
    /// the macOS PhotoOriginalExporter. The caller owns the temporary file
    /// and must remove its containing directory when finished.
    func exportOriginal(for galleryAsset: GalleryAsset, progress: (@Sendable (Double) -> Void)? = nil, diagnosticAssetID: String? = nil, diagnosticJob: Int? = nil) async throws -> ExportedOriginal {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [galleryAsset.id], options: nil)
        guard let asset = fetched.firstObject else { throw InventoryCheckError.unavailableAsset }
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == type }) else { throw UploadError.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("original")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress?(value) }
        do {
            IOSImportDiagnostics.memory(phase: "photokit-writeData-start", asset: diagnosticAssetID, job: diagnosticJob)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        IOSImportDiagnostics.memory(phase: "photokit-writeData-completion", asset: diagnosticAssetID, job: diagnosticJob)
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            } onCancel: { }
            return ExportedOriginal(url: url, filename: IOSFilenamePolicy.resolved(originalFilename: resource.originalFilename, localIdentifier: galleryAsset.id, mediaType: type == .video ? "video" : "image"), resourceType: type)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    #if DEBUG
    func identityDiagnostics(for selection: [GalleryAsset]) throws -> [PhotoIdentityDiagnostic] {
        let inventory = try inventory(for: selection)
        return zip(selection, inventory).map { asset, record in
            PhotoIdentityDiagnostic(
                localIdentifier: record.localIdentifier,
                cloudIdentifier: record.cloudIdentifier,
                inventoryIdentifier: record.stableIdentity
            )
        }
    }

    func originalContentDiagnostic(
        for selection: GalleryAsset,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> OriginalContentDiagnostic {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [selection.id], options: nil)
        guard let asset = fetched.firstObject else { throw OriginalContentDiagnosticError.unavailableAsset }
        let resourceType: PHAssetResourceType
        switch asset.mediaType {
        case .image: resourceType = .photo
        case .video: resourceType = .video
        default: throw OriginalContentDiagnosticError.unsupportedAsset
        }
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == resourceType }) else {
            throw OriginalContentDiagnosticError.originalUnavailable
        }

        let cloudMapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])[asset.localIdentifier]
        let cloudIdentifier: String?
        if case .success(let identifier)? = cloudMapping { cloudIdentifier = IOSCloudIdentifierCodec.encode(identifier) }
        else { cloudIdentifier = nil }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fileURL = directory.appendingPathComponent("original")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in
            Task { @MainActor in progress(value) }
        }

        do {
            defer { try? FileManager.default.removeItem(at: directory) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            progress(1)
            let identity = try await Task.detached(priority: .userInitiated) {
                try ContentIdentity.read(fileURL)
            }.value
            return OriginalContentDiagnostic(
                localIdentifier: asset.localIdentifier,
                cloudIdentifier: cloudIdentifier,
                resourceType: Self.resourceTypeName(resource.type),
                filename: resource.originalFilename,
                byteSize: identity.bytes,
                sha256: identity.sha256
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is OriginalContentDiagnosticError { throw error }
            throw OriginalContentDiagnosticError.exportFailed(error.localizedDescription)
        }
    }

    private static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        default: String(describing: type)
        }
    }
    #endif

    func requestThumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in completion(image) }
    }

    func cancelThumbnail(_ requestID: PHImageRequestID) { imageManager.cancelImageRequest(requestID) }
}

#if DEBUG
struct PhotoIdentityDiagnostic: Identifiable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let cloudIdentifier: String?
    let inventoryIdentifier: String
}

#if DEBUG
struct OriginalContentDiagnostic: Identifiable {
    var id: String { localIdentifier }
    let localIdentifier: String
    let cloudIdentifier: String?
    let resourceType: String
    let filename: String
    let byteSize: Int64
    let sha256: String
}

enum OriginalContentDiagnosticError: LocalizedError {
    case unavailableAsset
    case unsupportedAsset
    case originalUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableAsset: "Das ausgewählte Foto ist in der aktuellen Mediathek nicht verfügbar."
        case .unsupportedAsset: "Für dieses Asset wird nur die Diagnose normaler Fotos und Videos unterstützt."
        case .originalUnavailable: "Die passende Originalressource (.photo oder .video) ist nicht verfügbar."
        case .exportFailed(let reason): "PhotoKit konnte das Original nicht exportieren: \(reason)"
        }
    }
}
#endif
#endif

private enum IOSCloudIdentifierCodec {
    static func encode(_ identifier: PHCloudIdentifier) -> String {
        if #available(iOS 18.2, *) { return identifier.archivalStringValue }
        return identifier.stringValue
    }
}

enum PhotoKitInventoryMapper {
    static func make(localIdentifier: String, cloudIdentifier: String?, mediaType: String, creationDate: Date?, filename: String?) -> AssetInventory {
        AssetInventory(localIdentifier: localIdentifier, cloudIdentifier: cloudIdentifier, mediaType: mediaType, creationDate: creationDate, filename: filename)
    }
}

enum IOSFilenamePolicy {
    static func resolved(originalFilename: String?, localIdentifier: String, mediaType: String) -> String {
        if let originalFilename {
            let trimmed = originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.utf8.count <= 4096, isSafe(trimmed) { return trimmed }
        }
        let safeID = localIdentifier.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII && (scalar.value == 45 || scalar.value == 95 || (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)) { return Character(scalar) }
            return "_"
        }
        return "asset-\(String(safeID).prefix(120)).\(mediaType == "video" ? "mov" : "jpg")"
    }

    private static func isSafe(_ value: String) -> Bool {
        value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains { $0.value < 32 }
    }
}
