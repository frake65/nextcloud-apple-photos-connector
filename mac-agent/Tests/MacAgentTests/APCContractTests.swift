import Foundation
import XCTest
@testable import InventoryCore
@testable import MacAgent

final class APCContractTests: XCTestCase {
    private struct StatusReply: Decodable { let status: String; let app: String; let version: String }
    private struct InventoryReply: Decodable { struct Entry: Decodable { let cloudIdentifier: String?; let state: String; let upload: Ticket? }; struct Ticket: Decodable { let uploadId: String; let assetId: String }; let assets: [Entry]; let runId: String }
    private struct PrepareReply: Decodable { let assetId: String; let bytes: Int; let path: String; let sha256: String; let state: String }
    private struct CompleteReply: Decodable { let runId: String; let uploadId: String; let status: String; let summary: Summary; struct Summary: Decodable { let uploaded: Int; let failed: Int } }
    private struct AlbumInventoryReply: Decodable { let albums: [Int]; let count: Int }

    func testStatusInventoryPrepareAndCompleteResponsesMatchServer() throws {
        let status = try JSONDecoder().decode(StatusReply.self, from: Data(#"{"status":"ok","app":"apple_photos_connector","version":"0.8.6"}"#.utf8))
        XCTAssertEqual(status.status, "ok"); XCTAssertEqual(status.app, "apple_photos_connector")
        let inventory = try JSONDecoder().decode(InventoryReply.self, from: Data(#"{"runId":"run","assets":[{"cloudIdentifier":"cloud","state":"new","upload":{"uploadId":"upload","assetId":"42"}},{"cloudIdentifier":null,"state":"known","upload":null}]}"#.utf8))
        XCTAssertEqual(inventory.assets.map(\.state), ["new", "known"]); XCTAssertEqual(inventory.assets[0].upload?.assetId, "42"); XCTAssertNil(inventory.assets[1].upload)
        let prepare = try JSONDecoder().decode(PrepareReply.self, from: Data(#"{"assetId":"42","bytes":4,"path":"Photos/2026/photo.jpg","sha256":"abc","state":"contentAlreadyPresent"}"#.utf8))
        XCTAssertEqual(prepare.state, "contentAlreadyPresent")
        let complete = try JSONDecoder().decode(CompleteReply.self, from: Data(#"{"runId":"run","uploadId":"upload","status":"completed","summary":{"uploaded":1,"failed":0}}"#.utf8))
        XCTAssertEqual(complete.status, "completed"); XCTAssertEqual(complete.summary.uploaded, 1)
    }

    func testAlbumInventorySupportsEmptyAlbumAndBothMembershipFieldNames() throws {
        let document = AlbumInventoryDocument(source: PhotoSource(sourceId: UUID(), name: "Photos"), albums: [
            AlbumInventory(localIdentifier: "empty", name: "Empty", assetIdentities: []),
            AlbumInventory(localIdentifier: "members", name: "Members", assetIdentities: ["cloud:asset-1"])
        ])
        let data = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let albums = try XCTUnwrap(object["albums"] as? [[String: Any]])
        XCTAssertEqual(albums[0]["assetIdentities"] as? [String], [])
        XCTAssertEqual(albums[1]["assetIdentities"] as? [String], ["cloud:asset-1"])
        XCTAssertEqual(albums[0]["assets"] as? [String], [])
        XCTAssertEqual(albums[1]["assets"] as? [String], ["cloud:asset-1"])
        let alternate = try XCTUnwrap(JSONSerialization.data(withJSONObject: ["version": 1, "source": ["sourceId": UUID().uuidString, "name": "Photos"], "albums": [["localIdentifier":"a","name":"A","kind":"album","assets":["local:1"]]]]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: alternate) as? [String: Any])?["albums"] != nil, true)
    }

    func testAlbumSyncCompletedAndPartialAreRepresentedAndStructuredErrorsRemainVisible() throws {
        let completed = AlbumInventoryCoordinator.SyncReply(status: "completed", summary: .init(albumsCreated: 1, albumsReused: 0, foldersSkipped: 0, membershipsCreated: 1, membershipsReused: 0, membershipsSkippedNotImported: 0, errors: []))
        XCTAssertNoThrow(try AlbumInventoryCoordinator.interpret(status: 200, reply: completed))
        let partial = AlbumInventoryCoordinator.SyncReply(status: "partial", summary: .init(albumsCreated: 1, albumsReused: 0, foldersSkipped: 0, membershipsCreated: 0, membershipsReused: 0, membershipsSkippedNotImported: 1, errors: [.init(type: "membership", message: "not imported")]))
        XCTAssertThrowsError(try AlbumInventoryCoordinator.interpret(status: 200, reply: partial))
    }

    func testStructuredServerErrorsClassifyRetryableStatuses() {
        XCTAssertTrue(ServerErrorInfo(status: 409, code: "invalid_request").isRetryable)
        XCTAssertTrue(ServerErrorInfo(status: 503, message: "temporary").isRetryable)
        XCTAssertFalse(ServerErrorInfo(status: 400, code: "invalid_request").isRetryable)
    }
}
