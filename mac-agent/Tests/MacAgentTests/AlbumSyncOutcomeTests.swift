import XCTest
@testable import MacAgent
import InventoryCore

final class AlbumSyncOutcomeTests: XCTestCase {
    private func summary(errors: [AlbumInventoryCoordinator.SyncError]) -> AlbumInventoryCoordinator.Summary {
        .init(albumsCreated: 0, albumsReused: 3, foldersSkipped: 0,
              membershipsCreated: 17, membershipsReused: 3,
              membershipsSkippedNotImported: 0, errors: errors)
    }

    func testCompletedHTTP200WithNoErrorsIsOverallSuccess() throws {
        let reply = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: summary(errors: []))
        let result = try AlbumInventoryCoordinator.interpret(status: 200, reply: reply)
        XCTAssertEqual(result.albumsReused, 3)
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
        let reply = AlbumInventoryCoordinator.SyncReply(status: "partial", summary: summary(errors: errors))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 200, reply: reply)) {
            let failure = $0 as? AlbumOperationFailure
            XCTAssertEqual(failure?.stage, .sync)
            XCTAssertTrue(failure?.technicalDetail.contains("errors=2") == true)
        }
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: 0, albumFailed: true), .albumFailed)
    }

    func testErrorsArrayCannotBeIgnoredWhenStatusSaysCompleted() {
        let errors = [AlbumInventoryCoordinator.SyncError(type: "membership", message: "one")]
        let reply = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: summary(errors: errors))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 200, reply: reply))
    }
}
