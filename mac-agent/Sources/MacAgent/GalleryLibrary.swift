import Foundation
import Photos
import AppKit
import InventoryCore

struct GalleryAsset: Sendable, Equatable {
    let localIdentifier: String
    let isVideo: Bool
    let duration: TimeInterval
    let identity: String
}

struct GalleryAlbum: Sendable {
    let inventory: AlbumInventory
    let photos: Int
    let videos: Int
    let cover: String?
}

struct GallerySelection: Sendable {
    var identities: Set<String> = []
    var photos = 0
    var videos = 0
}

struct GalleryChangeResult: Sendable {
    let requiresFullRefresh: Bool
    let changedAssetIDs: Set<String>
    let removedAssetIDs: Set<String>
}

struct GalleryChangeDelta: Sendable, Equatable {
    let insertedIndexes: IndexSet
    let removedAssetIDs: Set<String>
    let changedAssetIDs: Set<String>
    let isIncremental: Bool
    let newCount: Int
}

struct AlbumChangeDelta: Sendable, Equatable {
    let insertedAlbumIDs: Set<String>
    let removedAlbumIDs: Set<String>
    let changedAlbumIDs: Set<String>
    let isIncremental: Bool
}

struct AlbumMembershipDelta: Sendable, Equatable {
    let albumID: String
    let insertedAssetIDs: Set<String>
    let removedAssetIDs: Set<String>
    let changedAssetIDs: Set<String>
    let revision: UInt64
    let requiresFullRefresh: Bool
}

enum AlbumMembershipSelection {
    static func applying(_ delta: AlbumMembershipDelta, to members: Set<String>) -> Set<String> {
        guard !delta.requiresFullRefresh else { return [] }
        return members
            .subtracting(delta.removedAssetIDs.map { "local:\($0)" })
            .union(delta.insertedAssetIDs.map { "local:\($0)" })
            .union(delta.changedAssetIDs.map { "local:\($0)" })
    }

    static func effective(manual: Set<String>, albums: [Set<String>]) -> Set<String> {
        manual.union(albums.reduce(into: Set<String>()) { $0.formUnion($1) })
    }
}

extension GalleryChangeDelta {
    static func invalidatedCacheKeys(_ keys: Set<String>, removed: Set<String>, changed: Set<String>) -> Set<String> {
        keys.subtracting(removed.union(changed))
    }
}

protocol GalleryLibraryProviding: Sendable {
    func open() async throws -> Int
    func currentCount() async -> Int
    func cell(at index: Int) async throws -> GalleryAsset
    func resolveAll() async throws -> GallerySelection
    func resolveSelection(_ identities: Set<String>) async throws -> GallerySelection
    func albumCatalog() async throws -> [GalleryAlbum]
    func albumAssets(_ local: String) async throws -> GallerySelection
    func albumIDs(containing identities: Set<String>) async throws -> Set<String>
    func asset(local: String) async throws -> GalleryAsset?
    func apply(change: PHChange) async -> GalleryChangeResult
    func applyAlbumChange(change: PHChange) async -> AlbumChangeDelta
    func setObservedAlbumIDs(_ ids: Set<String>) async
    func applyMembershipChanges(change: PHChange) async -> [AlbumMembershipDelta]
}

extension GalleryLibraryProviding {
    func currentCount() async -> Int { 0 }
    func apply(change: PHChange) async -> GalleryChangeResult {
        GalleryChangeResult(requiresFullRefresh: true, changedAssetIDs: [], removedAssetIDs: [])
    }
    func applyAlbumChange(change: PHChange) async -> AlbumChangeDelta {
        AlbumChangeDelta(insertedAlbumIDs: [], removedAlbumIDs: [], changedAlbumIDs: [], isIncremental: false)
    }
    func setObservedAlbumIDs(_ ids: Set<String>) async { }
    func applyMembershipChanges(change: PHChange) async -> [AlbumMembershipDelta] { [] }
    func albumIDs(containing identities: Set<String>) async throws -> Set<String> { [] }
}

enum GalleryDebug {
    private static let logger = DebugFileLogger(enabled: true)
    static func log(_ event: String, category: String? = nil) {
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        guard defaults.bool(forKey: UploadPreferences.debugModeKey) else { return }
        Task { @MainActor in DebugLogStore.shared.append(event, category: category) }
        logger.log(event)
    }
}

/// PhotoKit objects never cross this actor boundary. The fetch stays indexable;
/// only requested cells/explicit selections become small Sendable records.
actor GalleryLibrary: GalleryLibraryProviding {
    private var fetched: PHFetchResult<PHAsset>?
    private var albumCollections: PHFetchResult<PHAssetCollection>?
    private var observedAlbumFetches: [String: PHFetchResult<PHAsset>] = [:]
    private var membershipRevision: UInt64 = 0
    private var cache: [String: GalleryAsset] = [:]
    private let gate: SettingsWorkGate
    private let batchSize = 128
    init(gate: SettingsWorkGate = .shared) { self.gate = gate }

    private func options() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        return options
    }

    func open() async throws -> Int {
        try await gate.checkpoint()
        fetched = PHAsset.fetchAssets(with: options())
        albumCollections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        cache.removeAll()
        let count = fetched?.count ?? 0
        GalleryDebug.log("gallery.fetch.count=\(count)")
        return count
    }

    func applyAlbumChange(change: PHChange) async -> AlbumChangeDelta {
        guard let old = albumCollections, let details = change.changeDetails(for: old) else {
            return AlbumChangeDelta(insertedAlbumIDs: [], removedAlbumIDs: [], changedAlbumIDs: [], isIncremental: false)
        }
        let inserted = Set(details.insertedObjects.map(\.localIdentifier))
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        let changed = Set(details.changedObjects.map(\.localIdentifier))
        albumCollections = details.fetchResultAfterChanges
        return AlbumChangeDelta(insertedAlbumIDs: inserted, removedAlbumIDs: removed,
                                changedAlbumIDs: changed, isIncremental: details.hasIncrementalChanges)
    }

    func setObservedAlbumIDs(_ ids: Set<String>) async {
        observedAlbumFetches = observedAlbumFetches.filter { ids.contains($0.key) }
        for id in ids where observedAlbumFetches[id] == nil {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            observedAlbumFetches[id] = PHAsset.fetchAssets(in: album, options: options())
        }
    }

    func applyMembershipChanges(change: PHChange) async -> [AlbumMembershipDelta] {
        var result: [AlbumMembershipDelta] = []
        for (albumID, fetch) in observedAlbumFetches {
            guard let details = change.changeDetails(for: fetch) else { continue }
            membershipRevision &+= 1
            let inserted = Set(details.insertedObjects.map(\.localIdentifier))
            let removed = Set(details.removedObjects.map(\.localIdentifier))
            let changed = Set(details.changedObjects.map(\.localIdentifier))
            observedAlbumFetches[albumID] = details.fetchResultAfterChanges
            result.append(AlbumMembershipDelta(albumID: albumID,
                                               insertedAssetIDs: inserted,
                                               removedAssetIDs: removed,
                                               changedAssetIDs: changed,
                                               revision: membershipRevision,
                                               requiresFullRefresh: !details.hasIncrementalChanges))
        }
        return result
    }

    func currentCount() async -> Int { fetched?.count ?? 0 }

    func apply(change: PHChange) async -> GalleryChangeResult {
        guard let old = fetched, let details = change.changeDetails(for: old) else {
            return GalleryChangeResult(requiresFullRefresh: true, changedAssetIDs: [], removedAssetIDs: [])
        }
        let removed = Set(details.removedObjects.map(\.localIdentifier))
        let changed = Set(details.changedObjects.map(\.localIdentifier))
        let nonIncremental = !details.hasIncrementalChanges
        fetched = details.fetchResultAfterChanges
        for id in removed { cache.removeValue(forKey: id) }
        for id in changed { cache.removeValue(forKey: id) }
        return GalleryChangeResult(requiresFullRefresh: nonIncremental,
                                   changedAssetIDs: changed,
                                   removedAssetIDs: removed)
    }

    func cell(at index: Int) async throws -> GalleryAsset {
        try await gate.checkpoint()
        guard let fetched, index >= 0, index < fetched.count else { throw CancellationError() }
        return resolve([fetched.object(at: index)])[0]
    }

    func asset(local: String) async throws -> GalleryAsset? {
        try await gate.checkpoint()
        if let value = cache[local] { return value }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: options())
        guard let asset = result.firstObject else { return nil }
        return resolve([asset])[0]
    }

    private func resolve(_ assets: [PHAsset]) -> [GalleryAsset] {
        var batchValues = cache
        let missing = assets.filter { batchValues[$0.localIdentifier] == nil }
        if !missing.isEmpty {
            GalleryDebug.log("gallery.identifier.batch.start count=\(missing.count)")
            let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: missing.map(\.localIdentifier))
            // Bounded cache of cell metadata/identities, never the whole library.
            if cache.count + missing.count > 512 { cache.removeAll(keepingCapacity: true) }
            for asset in missing {
                let local = asset.localIdentifier
                let identity: String
                if case .success(let cloud) = mappings[local], let encoded = CloudIdentifierCodec.encode(cloud) {
                    identity = "cloud:\(encoded)"
                } else { identity = "local:\(local)" }
                let value = GalleryAsset(localIdentifier: local, isVideo: asset.mediaType == .video, duration: asset.duration, identity: identity)
                cache[local] = value
                batchValues[local] = value
            }
            GalleryDebug.log("gallery.identifier.batch.complete count=\(missing.count)")
        }
        return assets.map { asset in
            // Keep values needed by this batch even when the cache was trimmed.
            batchValues[asset.localIdentifier]!
        }
    }

    private func records(_ result: PHFetchResult<PHAsset>) async throws -> GallerySelection {
        var values = GallerySelection()
        for start in stride(from: 0, to: result.count, by: batchSize) {
            try await gate.checkpoint()
            let batch = autoreleasepool {
                resolve((start..<min(start + batchSize, result.count)).map { result.object(at: $0) })
            }
            for asset in batch where values.identities.insert(asset.identity).inserted {
                if asset.isVideo { values.videos += 1 } else { values.photos += 1 }
            }
            await Task.yield()
        }
        return values
    }

    func resolveAll() async throws -> GallerySelection {
        guard let fetched else { return GallerySelection() }
        return try await records(fetched)
    }

    func resolveSelection(_ identities: Set<String>) async throws -> GallerySelection {
        let values = Array(identities)
        var result = GallerySelection(identities: identities)
        var counted: Set<String> = []
        for start in stride(from: 0, to: values.count, by: batchSize) {
            try await gate.checkpoint()
            let batch = values[start..<min(start + batchSize, values.count)]
            let clouds = batch.filter { $0.hasPrefix("cloud:") }.compactMap { CloudIdentifierCodec.decode(String($0.dropFirst(6))) }
            var locals = batch.filter { $0.hasPrefix("local:") }.map { String($0.dropFirst(6)) }
            let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: clouds)
            for cloud in clouds {
                if case .success(let local) = mappings[cloud] { locals.append(local) }
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: locals, options: options())
            let resolved = resolve((0..<assets.count).map { assets.object(at: $0) })
            for asset in resolved {
                if result.identities.remove("local:\(asset.localIdentifier)") != nil {
                    result.identities.insert(asset.identity)
                }
                if counted.insert(asset.identity).inserted {
                    if asset.isVideo { result.videos += 1 } else { result.photos += 1 }
                }
            }
            await Task.yield()
        }
        return result
    }

    func albumCatalog() async throws -> [GalleryAlbum] {
        try await gate.checkpoint()
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var result: [GalleryAlbum] = []
        for index in 0..<collections.count {
            try await gate.checkpoint()
            let album = collections.object(at: index)
            let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [album.localIdentifier])[album.localIdentifier]
            let cloud: String?
            if case .success(let value) = mapping { cloud = CloudIdentifierCodec.encode(value) } else { cloud = nil }
            let photos = PHFetchOptions()
            photos.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let videos = PHFetchOptions()
            videos.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            let members = PHAsset.fetchAssets(in: album, options: options())
            result.append(GalleryAlbum(inventory: AlbumInventory(localIdentifier: album.localIdentifier, cloudIdentifier: cloud, name: album.localizedTitle ?? ""),
                photos: PHAsset.fetchAssets(in: album, options: photos).count,
                videos: PHAsset.fetchAssets(in: album, options: videos).count,
                cover: members.firstObject?.localIdentifier))
            await Task.yield()
        }
        return result
    }

    func albumAssets(_ local: String) async throws -> GallerySelection {
        try await gate.checkpoint()
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [local], options: nil).firstObject else { return GallerySelection() }
        return try await records(PHAsset.fetchAssets(in: album, options: options()))
    }

    func albumIDs(containing identities: Set<String>) async throws -> Set<String> {
        guard !identities.isEmpty else { return [] }
        let clouds = identities.filter { $0.hasPrefix("cloud:") }.compactMap { CloudIdentifierCodec.decode(String($0.dropFirst(6))) }
        var locals = identities.compactMap { identity -> String? in
            guard identity.hasPrefix("local:") else { return nil }
            return String(identity.dropFirst(6))
        }
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: clouds)
        for cloud in clouds { if case .success(let local) = mappings[cloud] { locals.append(local) } }
        var result = Set<String>()
        for local in locals {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: options()).firstObject else { continue }
            let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            for index in 0..<collections.count { result.insert(collections.object(at: index).localIdentifier) }
        }
        return result
    }
}
