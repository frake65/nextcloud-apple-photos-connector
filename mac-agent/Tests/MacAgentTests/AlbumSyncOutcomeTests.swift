import XCTest
@testable import MacAgent
import InventoryCore

final class AlbumSyncOutcomeTests: XCTestCase {
    private func summary(errors: [AlbumInventoryCoordinator.SyncError], foldersSkipped: Int = 0, membershipsSkipped: Int = 0) -> AlbumInventoryCoordinator.Summary {
        .init(albumsCreated: 0, albumsReused: 3, foldersSkipped: foldersSkipped,
              membershipsCreated: 17, membershipsReused: 3,
              membershipsSkippedNotImported: membershipsSkipped, errors: errors)
    }

    func testCompletedHTTP200WithNoErrorsIsOverallSuccess() throws {
        let reply = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: summary(errors: [], foldersSkipped: 2, membershipsSkipped: 4))
        let result = try AlbumInventoryCoordinator.interpret(status: 200, reply: reply)
        XCTAssertEqual(result.albumsReused, 3)
        XCTAssertEqual(result.foldersSkipped, 2)
        XCTAssertEqual(result.membershipsSkippedNotImported, 4)
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: 0, albumFailed: false), .completed)
    }

    func testAlbumHTTPFailureIsNotClassifiedAsUploadFailure() {
        let reply = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: summary(errors: []))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 503, reply: reply)) {
            XCTAssertEqual(($0 as? AlbumOperationFailure)?.stage, .sync)
        }
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: 0, albumFailed: true), .albumFailed)
    }

    func testHTTP200WithPartialErrorsIsAnAlbumFailure() {
        let errors = [
            AlbumInventoryCoordinator.SyncError(type: "membership", message: "one"),
            AlbumInventoryCoordinator.SyncError(type: "album", message: "two")
        ]
        let reply = AlbumInventoryCoordinator.SyncReply(status: "partial", summary: summary(errors: errors, foldersSkipped: 1, membershipsSkipped: 5))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 200, reply: reply)) {
            let failure = $0 as? AlbumOperationFailure
            XCTAssertEqual(failure?.stage, .sync)
            XCTAssertTrue(failure?.technicalDetail.contains("errors=2") == true)
            XCTAssertTrue(failure?.technicalDetail.contains("errorTypes=album,membership") == true)
            XCTAssertTrue(failure?.technicalDetail.contains("foldersSkipped=1") == true)
            XCTAssertTrue(failure?.technicalDetail.contains("membershipsSkippedNotImported=5") == true)
        }
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: 0, albumFailed: true), .albumFailed)
    }

    func testErrorsArrayCannotBeIgnoredWhenStatusSaysCompleted() {
        let errors = [AlbumInventoryCoordinator.SyncError(type: "membership", message: "one")]
        let reply = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: summary(errors: errors))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 200, reply: reply))
    }
}
