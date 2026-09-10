import Foundation

/// Stable identity used only for the user's current PhotoKit selection.
public enum PhotoSelectionIdentity {
    public static func album(_ album: AlbumInventory) -> String {
        album.cloudIdentifier.map { "cloud:\($0)" } ?? "local:\(album.localIdentifier)"
    }
}

public struct PhotoSelectionState: Codable, Equatable, Sendable {
    public var assetIdentities: Set<String>
    public var albumIdentities: Set<String>
    public init(assetIdentities: Set<String> = [], albumIdentities: Set<String> = []) {
        self.assetIdentities = assetIdentities
        self.albumIdentities = albumIdentities
    }
}

public enum PhotoSelectionPreferences {
    private static let prefix = "nextcloud.photoSelection."
    public static func load(sourceId: String, defaults: UserDefaults) -> PhotoSelectionState {
        guard let data = defaults.data(forKey: prefix + sourceId.lowercased()), let state = try? JSONDecoder().decode(PhotoSelectionState.self, from: data) else { return PhotoSelectionState(assetIdentities: [], albumIdentities: []) }
        return state
    }
    public static func save(_ state: PhotoSelectionState, sourceId: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: prefix + sourceId.lowercased())
    }
}

public enum PhotoSelectionRestorer {
    public static func reconcile(_ persisted: PhotoSelectionState, assetIdentitiesByLocal: [String: String], albums: [AlbumInventory]) -> PhotoSelectionState {
        let selectable = albums.filter { $0.kind == "album" }
        let validAlbums = selectable.filter { persisted.albumIdentities.contains(PhotoSelectionIdentity.album($0)) }
        let albumAssets = Set(validAlbums.flatMap(\.assetIdentities))
        let assetIdentities = Set(assetIdentitiesByLocal.values)
        let validAssetIds = assetIdentities.intersection(persisted.assetIdentities)
        let albumAssetIds = assetIdentitiesByLocal.filter { albumAssets.contains($0.key) }.map(\.value)
        return PhotoSelectionState(assetIdentities: validAssetIds.union(albumAssetIds), albumIdentities: Set(validAlbums.map(PhotoSelectionIdentity.album)))
    }
}
