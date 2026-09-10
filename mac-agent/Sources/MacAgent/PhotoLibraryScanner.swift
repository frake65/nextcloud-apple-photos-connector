import Foundation
import Photos
import OSLog
import InventoryCore

/// Serial background isolation keeps PhotoKit enumeration off the UI thread.
actor PhotoLibraryScanner {
    struct Result: Sendable {
        let json: String
        let summary: ScanSummary
        let limited: Bool
        let missingAlbumIdentities: [String]
    }

    private let logger = Logger(subsystem: "de.applephotosconnector.macagent", category: "CloudIdentifier")
    private let albumLogger = Logger(subsystem: "de.applephotosconnector.macagent", category: "Albums")

    enum ScanError: LocalizedError {
        case denied, restricted, unavailable

        var errorDescription: String? {
            switch self {
            case .denied:
                "Fotozugriff verweigert. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Fotos erlauben."
            case .restricted:
                "Der Fotozugriff ist durch Systemvorgaben eingeschränkt."
            case .unavailable:
                "Der Fotozugriff konnte nicht freigegeben werden."
            }
        }
    }

    func currentSourceId() throws -> UUID { try PhotoSourceStore.applicationStore().loadOrCreate().sourceId }

    func requestPhotoAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        logger.info("photos.authorization.status=\(String(describing: status.rawValue), privacy: .public)")
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        logger.info("photos.authorization.status.afterRequest=\(String(describing: status.rawValue), privacy: .public)")
        switch status { case .authorized, .limited: return; case .denied: throw ScanError.denied; case .restricted: throw ScanError.restricted; default: throw ScanError.unavailable }
    }

    func scan() async throws -> Result {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        logger.info("photos.scan.authorization.status=\(String(describing: status.rawValue), privacy: .public)")
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        logger.info("photos.authorization.status.afterRequest=\(String(describing: status.rawValue), privacy: .public)")
        switch status {
        case .authorized, .limited: break
        case .denied: throw ScanError.denied
        case .restricted: throw ScanError.restricted
        default: throw ScanError.unavailable
        }

        let source = try PhotoSourceStore.applicationStore().loadOrCreate()
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(with: options)
        logger.info("photos.fetch.asset_count=\(fetched.count, privacy: .public)")
        var inventory: [AssetInventory] = []
        inventory.reserveCapacity(fetched.count)
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            let record = autoreleasepool {
                let asset = fetched.object(at: index)
                let resources = PHAssetResource.assetResources(for: asset)
                let originalType: PHAssetResourceType? = switch asset.mediaType {
                case .image: .photo
                case .video: .video
                case .audio: .audio
                default: nil
                }
                // Prefer the original primary resource, not edits or a Live Photo's paired video.
                let filename = resources.first { $0.type == originalType }?.originalFilename
                let mediaType: String = switch asset.mediaType {
                case .image: "image"
                case .video: "video"
                case .audio: "audio"
                default: "unknown"
                }
                return AssetInventory(
                    localIdentifier: asset.localIdentifier,
                    mediaType: mediaType,
                    creationDate: asset.creationDate,
                    filename: filename
                )
            }
            inventory.append(record)
        }
        let library = PHPhotoLibrary.shared()
        let batchSize = 500
        for start in stride(from: 0, to: inventory.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, inventory.count)
            let identifiers = inventory[start..<end].map(\.localIdentifier)
            let mappings = library.cloudIdentifierMappings(forLocalIdentifiers: identifiers)
            for index in start..<end {
                let identifier = inventory[index].localIdentifier
                switch mappings[identifier] {
                case .success(let cloudIdentifier):
                    inventory[index].cloudIdentifier = CloudIdentifierCodec.encode(cloudIdentifier)
                case .failure(let error):
                    let nsError = error as NSError
                    logger.error("Cloud-Identifier fehlt für \(identifier, privacy: .private): \(nsError.domain, privacy: .public) (\(nsError.code)) – \(nsError.localizedDescription, privacy: .private)")
                case nil:
                    logger.error("Kein Mapping zurückgegeben für \(identifier, privacy: .private)")
                }
            }
        }
        inventory.sort { $0.localIdentifier < $1.localIdentifier }
        return Result(json: try InventoryJSON.encode(inventory, source: source), summary: ScanSummary(assets: inventory), limited: status == .limited, missingAlbumIdentities: [])
    }

    func scan(candidates: Set<String>? = nil) async throws -> Result {
        let result = try await scan()
        guard let candidates else { return result }
        logger.info("inventory.candidate.input selected=\(candidates.count, privacy: .public) scanned=\(result.summary.totalAssets, privacy: .public)")
        let filtered = try InventoryJSON.filteringByStableIdentity(result.json, allowed: candidates)
        logger.info("inventory.candidate.accepted=\(filtered.summary.totalAssets, privacy: .public) rejected=\(result.summary.totalAssets - filtered.summary.totalAssets, privacy: .public)")
        return Result(json: filtered.json, summary: filtered.summary, limited: result.limited, missingAlbumIdentities: [])
    }

    func scanAlbums() async throws -> AlbumInventoryDocument {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { throw ScanError.denied }
        let source = try PhotoSourceStore.applicationStore().loadOrCreate()
        var result: [AlbumInventory] = []
        let allAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        let allLists = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        albumLogger.info("PhotoKit all PHAssetCollection count=\(allAlbums.count, privacy: .public), PHCollectionList count=\(allLists.count, privacy: .public)")
        func walk(_ collection: PHCollection, parent: String?) {
            if let album = collection as? PHAssetCollection {
                let f = PHAsset.fetchAssets(in: album, options: nil)
                var assets: [String] = []; for j in 0..<f.count { assets.append(f.object(at: j).localIdentifier) }
                let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [album.localIdentifier])[album.localIdentifier]
                let cloud = mapping.flatMap { if case .success(let value) = $0 { return CloudIdentifierCodec.encode(value) }; return nil }
                albumLogger.info("PHAssetCollection type=\(album.assetCollectionType.rawValue, privacy: .public) subtype=\(album.assetCollectionSubtype.rawValue, privacy: .public) title=\(album.localizedTitle ?? "", privacy: .private) id=\(album.localIdentifier, privacy: .private) assets=\(assets.count, privacy: .public) cloud=\(cloud != nil, privacy: .public)")
                result.append(AlbumInventory(localIdentifier: album.localIdentifier, cloudIdentifier: cloud, name: album.localizedTitle ?? "", kind: "album", parentLocalIdentifier: parent, assetIdentities: assets))
            } else if let folder = collection as? PHCollectionList {
                albumLogger.info("PHCollectionList title=\(folder.localizedTitle ?? "", privacy: .private) id=\(folder.localIdentifier, privacy: .private) parent=\(parent ?? "", privacy: .private)")
                result.append(AlbumInventory(localIdentifier: folder.localIdentifier, name: folder.localizedTitle ?? "", kind: "folder", parentLocalIdentifier: parent))
                let children = PHCollection.fetchCollections(in: folder, options: nil)
                for i in 0..<children.count { walk(children.object(at: i), parent: folder.localIdentifier) }
            }
        }
        let top = PHCollection.fetchTopLevelUserCollections(with: nil)
        albumLogger.info("PhotoKit top-level collections: \(top.count, privacy: .public)")
        for i in 0..<top.count { walk(top.object(at: i), parent: nil) }
        albumLogger.info("PhotoKit album/collection inventory: \(result.count, privacy: .public) entries")
        return AlbumInventoryDocument(source: source, albums: result.sorted{$0.localIdentifier<$1.localIdentifier})
    }
}
