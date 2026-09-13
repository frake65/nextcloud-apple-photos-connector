import Foundation

/// Stable identity used only for the user's current PhotoKit selection.
public enum PhotoSelectionIdentity {
    public static func album(_ album: AlbumInventory) -> String {
        album.cloudIdentifier.map { "cloud:\($0)" } ?? "local:\(album.localIdentifier)"
    }
}

public struct PhotoSelectionState: Codable, Equatable, Sendable {
    public var manuallySelectedAssetIDs: Set<String>
    public var selectedAlbumIDs: Set<String>

    public init(manuallySelectedAssetIDs: Set<String> = [], selectedAlbumIDs: Set<String> = []) {
        self.manuallySelectedAssetIDs = manuallySelectedAssetIDs
        self.selectedAlbumIDs = selectedAlbumIDs
    }

    public var assetIdentities: Set<String> {
        get { manuallySelectedAssetIDs }
        set { manuallySelectedAssetIDs = newValue }
    }

    public var albumIdentities: Set<String> {
        get { selectedAlbumIDs }
        set { selectedAlbumIDs = newValue }
    }

    private enum CodingKeys: String, CodingKey { case manuallySelectedAssetIDs, selectedAlbumIDs, assetIdentities, albumIdentities }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manuallySelectedAssetIDs = try c.decodeIfPresent(Set<String>.self, forKey: .manuallySelectedAssetIDs)
            ?? c.decodeIfPresent(Set<String>.self, forKey: .assetIdentities) ?? []
        selectedAlbumIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedAlbumIDs)
            ?? c.decodeIfPresent(Set<String>.self, forKey: .albumIdentities) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(manuallySelectedAssetIDs, forKey: .manuallySelectedAssetIDs)
        try c.encode(selectedAlbumIDs, forKey: .selectedAlbumIDs)
    }
}

public enum PhotoSelectionPreferences {
    private static let prefix = "nextcloud.photoSelection."
    public static func load(sourceId: String, defaults: UserDefaults) -> PhotoSelectionState {
        guard let data = defaults.data(forKey: prefix + sourceId.lowercased()), let state = try? JSONDecoder().decode(PhotoSelectionState.self, from: data) else { return PhotoSelectionState() }
        return state
    }
    public static func save(_ state: PhotoSelectionState, sourceId: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: prefix + sourceId.lowercased())
    }
}

public enum PhotoSelectionRestorer {
    public static func reconcile(_ persisted: PhotoSelectionState, assetIdentitiesByLocal: [String: String], albums: [AlbumInventory]) -> PhotoSelectionState {
        // Lazy gallery data is intentionally incomplete. Never discard persisted
        // reasons merely because cells or the album catalog are not materialized.
        return persisted
    }
}
