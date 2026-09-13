import XCTest
@testable import InventoryCore
@testable import MacAgent

final class UploadProgressTests: XCTestCase {
    func testZeroUploadsIsDisplayedAsComplete() {
        let progress = UploadProgressDisplay(completed: 0, total: 0)
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertTrue(progress.isComplete)
    }
    func testRunningUploadShowsPerFileAndOverallFraction() {
        let progress = UploadProgressDisplay(completed: 1, total: 4, filename: "foto.jpg")
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.filename, "foto.jpg")
    }
    func testFailedFileRetainsFilename() {
        let progress = UploadProgressDisplay(completed: 2, total: 3, filename: "fehler.jpg", failed: true)
        XCTAssertTrue(progress.failed)
        XCTAssertEqual(progress.filename, "fehler.jpg")
    }
    func testModalLifecycle() {
        XCTAssertEqual(UploadModalState.hidden, .hidden)
        XCTAssertEqual(UploadModalState.active, .active)
        XCTAssertEqual(UploadModalState.cancelled, .cancelled)
        XCTAssertEqual(UploadModalState.completed, .completed)
    }
    func testUploadDisplayStatusUsesUserFacingLabels() {
        XCTAssertEqual(UploadCoordinator.DisplayStatus.alreadyInCloud.label, "Bereits in der Cloud")
        XCTAssertEqual(UploadCoordinator.DisplayStatus.uploaded.label, "Hochgeladen")
        XCTAssertEqual(UploadCoordinator.DisplayStatus.failed.label, "Fehlgeschlagen")
    }
}
