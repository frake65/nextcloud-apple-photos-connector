import Foundation
import XCTest
@testable import InventoryCore

final class ConnectionValidationTests: XCTestCase {
    func testNetworkTransportHTTPFailuresAreClassifiedByEndpoint() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let unauthorized = await NextcloudConnectionClient(connection: connection, transport: HTTPStatusTransport([401])).validate()
        XCTAssertEqual(unauthorized.result, .authenticationFailed)

        let missingApp = await NextcloudConnectionClient(connection: connection, transport: HTTPStatusTransport([404])).validate()
        XCTAssertEqual(missingApp.result, .unexpectedResponse)

        let missingAPC = await NextcloudConnectionClient(connection: connection, transport: HTTPStatusTransport([200, 404])).validate()
        XCTAssertEqual(missingAPC.result, .appMissing)
    }
}

private actor HTTPStatusTransport: DAVTransport {
    private var statuses: [Int]
    init(_ statuses: [Int]) { self.statuses = statuses }

    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        let status = statuses.removeFirst()
        if status >= 400 { throw UploadError.http(status) }
        let data = request.url?.path == "/status.php"
            ? Data(#"{"installed":true}"#.utf8)
            : Data(#"{"app":"apple_photos_connector"}"#.utf8)
        return DAVResponse(status: status, data: data)
    }
}
