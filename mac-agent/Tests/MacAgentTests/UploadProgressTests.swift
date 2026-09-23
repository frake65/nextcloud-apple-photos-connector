import XCTest
@testable import InventoryCore
@testable import MacAgent
@testable import MacAgentSupport

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
    func testImportProgressActivityLabelReflectsPreparingAndTerminalStates() {
        func progress(completed: Int, total: Int, failed: Bool = false) -> UploadCoordinator.Progress {
            UploadCoordinator.Progress(completed: completed, total: total, filename: nil, failed: failed, cancelled: false, items: [])
        }
        XCTAssertEqual(progress(completed: 0, total: 2).activityLabelKey, "preparingUploads")
        XCTAssertEqual(progress(completed: 0, total: 0).activityLabelKey, "noNewUploads")
        XCTAssertEqual(progress(completed: 2, total: 2).activityLabelKey, "uploadComplete")
        XCTAssertEqual(progress(completed: 2, total: 2, failed: true).activityLabelKey, "uploadFailureUnknown")
    }
    func testCancellationSummaryCountsKnownAssetsOutsideUploadProgressTotal() {
        let items = [
            UploadCoordinator.DisplayItem(id: "uploaded", filename: "a.jpg", source: "a.jpg", target: nil, status: .uploaded, error: nil),
            UploadCoordinator.DisplayItem(id: "known", filename: "b.jpg", source: "b.jpg", target: nil, status: .alreadyInCloud, error: nil),
            UploadCoordinator.DisplayItem(id: "pending", filename: "c.jpg", source: "c.jpg", target: nil, status: .uploading, error: nil)
        ]
        let cancelled = UploadCoordinator.Progress(completed: 1, total: 2, filename: nil, failed: false, cancelled: false, items: items).markingCancelled()
        XCTAssertEqual(cancelled.summaryText, "1 von 3 Medien übertragen. 1 davon waren bereits vor diesem Lauf in der Cloud. 0 fehlgeschlagen. 1 nicht verarbeitet")
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
    func testImportCancellationLifecycleStatesAreDistinct() {
        XCTAssertNotEqual(ImportRunState.running, .cancelling)
        XCTAssertNotEqual(ImportRunState.cancelling, .cancelled)
        XCTAssertNotEqual(ImportRunState.cancelled, .completed)
        XCTAssertNotEqual(ImportRunState.cancelled, .failed)
    }
    func testUploadDisplayStatusUsesUserFacingLabels() {
        XCTAssertEqual(UploadCoordinator.DisplayStatus.alreadyInCloud.label, "Bereits in der Cloud")
        XCTAssertEqual(UploadCoordinator.DisplayStatus.uploaded.label, "Hochgeladen")
        XCTAssertEqual(UploadCoordinator.DisplayStatus.failed.label, "Fehlgeschlagen")
    }
    func testSummaryClarifiesKnownMediaWerePresentBeforeThisRun() {
        let uploaded = (0..<34).map { UploadCoordinator.DisplayItem(id: "u\($0)", filename: "u\($0).jpg", source: "u\($0).jpg", target: nil, status: .uploaded, error: nil) }
        let known = (0..<23).map { UploadCoordinator.DisplayItem(id: "k\($0)", filename: "k\($0).jpg", source: "k\($0).jpg", target: nil, status: .alreadyInCloud, error: nil) }
        let progress = UploadCoordinator.Progress(completed: 57, total: 57, filename: nil, failed: false, cancelled: false, items: uploaded + known)
        XCTAssertEqual(progress.summaryText, "34 von 57 Medien übertragen. 23 davon waren bereits vor diesem Lauf in der Cloud. 0 fehlgeschlagen.")
    }
    func testSummaryClarifiesAllMediaWereKnownBeforeThisRun() {
        let items = (0..<57).map { UploadCoordinator.DisplayItem(id: "k\($0)", filename: "k\($0).jpg", source: "k\($0).jpg", target: nil, status: .alreadyInCloud, error: nil) }
        let progress = UploadCoordinator.Progress(completed: 57, total: 57, filename: nil, failed: false, cancelled: false, items: items)
        XCTAssertEqual(progress.summaryText, "0 von 57 Medien übertragen. 57 davon waren bereits vor diesem Lauf in der Cloud. 0 fehlgeschlagen.")
    }
}
