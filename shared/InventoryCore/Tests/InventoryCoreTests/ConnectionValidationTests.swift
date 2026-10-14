import Foundation
import XCTest
@testable import InventoryCore

final class ConnectionValidationTests: XCTestCase {
    func testInstalledConnectorAppReturnsSuccess() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let validation = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([200, 200])
        ).validate()

        XCTAssertEqual(validation.result, .success)
        XCTAssertEqual(validation.statusCode, 200)
        XCTAssertEqual(validation.appStatusCode, 200)
    }

    func testMissingConnectorAppKeepsSeparateNextcloudAndAppStatus() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let validation = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([200, 404])
        ).validate()

        XCTAssertEqual(validation.result, .appMissing)
        XCTAssertEqual(validation.statusCode, 200)
        XCTAssertEqual(validation.appStatusCode, 404)
    }

    func testPreviouslyMissingConnectorRouteSucceedsWhenAppIsInstalled() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")

        let missing = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([200, 404])
        ).validate()
        XCTAssertEqual(missing.result, .appMissing)
        XCTAssertEqual(missing.appStatusCode, 404)

        let installed = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([200, 200])
        ).validate()
        XCTAssertEqual(installed.result, .success)
        XCTAssertEqual(installed.statusCode, 200)
        XCTAssertEqual(installed.appStatusCode, 200)
    }

    func testUnexpectedConnectorAppResponseIsNotAppMissing() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let validation = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([200, 200], appData: #"{"app":"other_app"}"#)
        ).validate()

        XCTAssertEqual(validation.result, .unexpectedResponse)
        XCTAssertEqual(validation.statusCode, 200)
        XCTAssertEqual(validation.appStatusCode, 200)
    }

    func testMissingNextcloudStatusEndpointIsUnexpectedResponse() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let validation = await NextcloudConnectionClient(
            connection: connection,
            transport: HTTPStatusTransport([404])
        ).validate()

        XCTAssertEqual(validation.result, .unexpectedResponse)
        XCTAssertEqual(validation.statusCode, 404)
        XCTAssertNil(validation.appStatusCode)
    }
}

private actor HTTPStatusTransport: DAVTransport {
    private var statuses: [Int]
    private let appData: Data

    init(_ statuses: [Int], appData: String = #"{"app":"apple_photos_connector"}"#) {
        self.statuses = statuses
        self.appData = Data(appData.utf8)
    }

    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        let status = statuses.removeFirst()
        if status >= 400 { throw UploadError.http(status) }
        let data = request.url?.path == "/status.php"
            ? Data(#"{"installed":true}"#.utf8)
            : appData
        return DAVResponse(status: status, data: data)
    }
}
