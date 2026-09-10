import XCTest
@testable import InventoryCore

private final class LoginFlowTransport: DAVTransport, @unchecked Sendable {
    var responses: [DAVResponse]
    var requests: [URLRequest] = []
    init(_ responses: [DAVResponse]) { self.responses = responses }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

final class LoginFlowTests: XCTestCase {
    func testStartResponseUsesServerProvidedLoginAndPollEndpoint() async throws {
        let transport = LoginFlowTransport([DAVResponse(status: 200, data: Data(#"{"poll":{"token":"temporary","endpoint":"https://cloud.example/login/v2/poll"},"login":"https://cloud.example/login/v2/flow/abc"}"#.utf8))])
        let response = try await NextcloudLoginFlowService(transport: transport).initiate(server: "https://cloud.example/")
        XCTAssertEqual(response.login.absoluteString, "https://cloud.example/login/v2/flow/abc")
        XCTAssertEqual(response.poll.endpoint.absoluteString, "https://cloud.example/login/v2/poll")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://cloud.example/index.php/login/v2")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testPoll404IsPendingThenDecodesCredentials() async throws {
        let transport = LoginFlowTransport([
            DAVResponse(status: 404),
            DAVResponse(status: 200, data: Data(#"{"server":"https://cloud.example","loginName":"frank","appPassword":"secret"}"#.utf8))
        ])
        let start = LoginFlowStartResponse(poll: .init(token: "temporary", endpoint: URL(string: "https://cloud.example/poll")!), login: URL(string: "https://cloud.example/login")!)
        let credentials = try await NextcloudLoginFlowService(transport: transport, pollInterval: .milliseconds(1), timeout: .seconds(1)).poll(start)
        XCTAssertEqual(credentials.loginName, "frank")
        XCTAssertEqual(credentials.server.absoluteString, "https://cloud.example")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidServerIsRejectedBeforeRequest() async {
        do { _ = try await NextcloudLoginFlowService().initiate(server: "http://insecure.example") ; XCTFail("expected invalid server") }
        catch LoginFlowError.invalidServer { }
        catch { XCTFail("unexpected error: \(error)") }
    }
}
