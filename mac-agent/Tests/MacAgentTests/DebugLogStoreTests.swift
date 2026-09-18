import XCTest
@testable import MacAgentSupport

@MainActor
final class DebugLogStoreTests: XCTestCase {
    func testStoreCollectsCategorizedEventsInOrderAndClears() {
        let store = DebugLogStore.shared
        store.clear()
        store.append("POST /inventory HTTP 200")
        store.append("MKCOL /Photos", category: "webdav")
        XCTAssertEqual(store.entries.map(\.category), ["inventory", "webdav"])
        XCTAssertTrue(store.entries[0].date <= store.entries[1].date)
        XCTAssertTrue(store.text.contains("INVENTORY")); XCTAssertTrue(store.text.contains("WEBDAV"))
        store.clear(); XCTAssertTrue(store.entries.isEmpty)
    }

    func testStoreBoundsMemoryAndRedactsSecrets() {
        let store = DebugLogStore.shared; store.clear()
        for i in 0..<(DebugLogStore.maxEntries + 25) { store.append("event \(i) token=secret password=hunter2") }
        XCTAssertEqual(store.entries.count, DebugLogStore.maxEntries)
        XCTAssertFalse(store.text.contains("secret")); XCTAssertFalse(store.text.contains("hunter2"))
        XCTAssertTrue(store.text.contains("event 25"))
        store.clear()
    }

    func testSuccessfulCompletionAndAlbumSummariesAreNotErrors() {
        let store = DebugLogStore.shared; store.clear()
        store.append("Import completed uploaded=0 failed=0")
        store.append("album.sync.summary albumsCreated=0 albumsReused=3 membershipsCreated=0 membershipsReused=20 errors=0")
        store.append("album.sync.summary albumsCreated=0 albumsReused=3 membershipsCreated=17 membershipsReused=3 errors=2")
        store.append("Import failed stage=inventory domain=InventoryCore.UploadError code=1")
        XCTAssertEqual(store.entries.map(\.category), ["upload", "album", "warning", "error"])
        XCTAssertTrue(store.text.contains("UPLOAD  Import completed uploaded=0 failed=0"))
        store.clear()
    }
}
