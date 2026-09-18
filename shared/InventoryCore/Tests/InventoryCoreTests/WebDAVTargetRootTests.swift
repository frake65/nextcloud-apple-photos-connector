import XCTest
@testable import InventoryCore

final class WebDAVTargetRootTests: XCTestCase {
    func testConfiguredRootsAndBoundaryAreComponentSafe() {
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Photos/Apple Photos Connector/2026/09/a.jpg", under: "Photos/Apple Photos Connector"))
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Archive/Camera A/2026/09/a.jpg", under: "Archive/Camera A"))
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Root/Nested/2026/09/a.jpg", under: "Root/Nested"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("Root2/2026/09/a.jpg", under: "Root"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("Root/../other/a.jpg", under: "Root"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("/Root/2026/09/a.jpg", under: "Root"))
    }
}
