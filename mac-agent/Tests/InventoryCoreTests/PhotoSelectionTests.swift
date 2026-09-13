import XCTest
@testable import InventoryCore

final class PhotoSelectionTests: XCTestCase {
    func testStableAlbumIdentitySurvivesNameChange() {
        let a = AlbumInventory(localIdentifier: "local", cloudIdentifier: "cloud", name: "Old", kind: "album", assetIdentities: [])
        let b = AlbumInventory(localIdentifier: "local", cloudIdentifier: "cloud", name: "New", kind: "album", assetIdentities: [])
        XCTAssertEqual(PhotoSelectionIdentity.album(a), PhotoSelectionIdentity.album(b))
    }

    func testSelectedAssetCandidatesAreDeduplicated() throws {
        let source = PhotoSource(name: "Photos")
        let a = AssetInventory(localIdentifier: "a", cloudIdentifier: "cloud:a", mediaType: "image", creationDate: nil, filename: "a.jpg")
        let duplicate = AssetInventory(localIdentifier: "b", cloudIdentifier: "cloud:a", mediaType: "image", creationDate: nil, filename: "b.jpg")
        let json = try InventoryJSON.encode([a, duplicate], source: source)
        let selected = try InventoryJSON.filteringByStableIdentity(json, allowed: ["cloud:cloud:a"])
        XCTAssertEqual(selected.summary.totalAssets, 1)
    }

    func testEmptySelectionIsEmptyInventoryAndDoesNotMeanLibrary() throws {
        let source = PhotoSource(name: "Photos")
        let a = AssetInventory(localIdentifier: "a", mediaType: "image", creationDate: nil, filename: "a.jpg")
        let json = try InventoryJSON.encode([a], source: source)
        let selected = try InventoryJSON.filteringByStableIdentity(json, allowed: [])
        XCTAssertEqual(selected.summary.totalAssets, 0)
    }

    func testSelectionPersistsIndependentlyOfLegacyScope() {
        let defaults = UserDefaults(suiteName: "APC.PhotoSelectionTests.\(UUID().uuidString)")!
        let state = PhotoSelectionState(manuallySelectedAssetIDs: ["cloud:a"], selectedAlbumIDs: ["cloud:album"])
        PhotoSelectionPreferences.save(state, sourceId: "SOURCE-A", defaults: defaults)
        XCTAssertEqual(PhotoSelectionPreferences.load(sourceId: "source-a", defaults: defaults), state)
        defaults.set(Data("legacy".utf8), forKey: "nextcloud.importScope.source-a")
        XCTAssertEqual(PhotoSelectionPreferences.load(sourceId: "source-a", defaults: defaults), state)
    }

    func testRestorePreservesReasonsUntilLazyResolutionCompletes() {
        let albumA = AlbumInventory(localIdentifier: "album-a", cloudIdentifier: "album-cloud-a", name: "A", kind: "album", assetIdentities: ["local-a", "local-shared"])
        let albumB = AlbumInventory(localIdentifier: "album-b", cloudIdentifier: "album-cloud-b", name: "B", kind: "album", assetIdentities: ["local-b", "local-shared"])
        let visible = ["local-a":"cloud:a", "local-b":"cloud:b", "local-shared":"cloud:shared"]
        let persisted = PhotoSelectionState(manuallySelectedAssetIDs: ["cloud:a", "cloud:stale"], selectedAlbumIDs: ["cloud:album-cloud-a", "cloud:album-stale"])
        let restored = PhotoSelectionRestorer.reconcile(persisted, assetIdentitiesByLocal: visible, albums: [albumA, albumB])
        XCTAssertEqual(restored.manuallySelectedAssetIDs, ["cloud:a", "cloud:stale"])
        XCTAssertEqual(restored.selectedAlbumIDs, ["cloud:album-cloud-a", "cloud:album-stale"])
        let both = PhotoSelectionRestorer.reconcile(PhotoSelectionState(selectedAlbumIDs: ["cloud:album-cloud-a", "cloud:album-cloud-b"]), assetIdentitiesByLocal: visible, albums: [albumA, albumB])
        XCTAssertTrue(both.manuallySelectedAssetIDs.isEmpty)
        XCTAssertEqual(both.selectedAlbumIDs, ["cloud:album-cloud-a", "cloud:album-cloud-b"])
    }

    func testStalePersistenceIsNotDeletedBeforeExplicitResolution() {
        let album = AlbumInventory(localIdentifier: "album", cloudIdentifier: "album-cloud", name: "A", kind: "album", assetIdentities: ["gone"])
        let persisted = PhotoSelectionState(manuallySelectedAssetIDs: ["cloud:gone"], selectedAlbumIDs: ["cloud:gone-album"])
        let restored = PhotoSelectionRestorer.reconcile(persisted, assetIdentitiesByLocal: ["live":"cloud:live"], albums: [album])
        XCTAssertEqual(restored.manuallySelectedAssetIDs, ["cloud:gone"])
        XCTAssertEqual(restored.selectedAlbumIDs, ["cloud:gone-album"])
    }

    func testLegacySelectionKeysMigrateToManualAndAlbumReasons() throws {
        let data = try JSONSerialization.data(withJSONObject: ["assetIdentities": ["cloud:a"], "albumIdentities": ["cloud:album"]])
        let state = try JSONDecoder().decode(PhotoSelectionState.self, from: data)
        XCTAssertEqual(state.manuallySelectedAssetIDs, ["cloud:a"])
        XCTAssertEqual(state.selectedAlbumIDs, ["cloud:album"])
    }
}
