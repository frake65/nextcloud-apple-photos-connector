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

    func testInsecureReturnedURLsAreRejected() async throws {
        let transport = LoginFlowTransport([DAVResponse(status: 200, data: Data(#"{"poll":{"token":"temporary","endpoint":"http://cloud.example/poll"},"login":"https://cloud.example/login"}"#.utf8))])
        do {
            _ = try await NextcloudLoginFlowService(transport: transport).initiate(server: "https://cloud.example")
            XCTFail("expected insecure poll URL rejection")
        } catch LoginFlowError.invalidReturnedURL { }
    }

    func testConnectorSeparatesLoginNameFromDAVUserID() throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", authUser: "login-name", davUser: "canonical-id", password: "app-password")
        XCTAssertEqual(connection.user, "canonical-id")
        XCTAssertEqual(connection.request(path: ["status.php"], method: "GET").value(forHTTPHeaderField: "Authorization"), "Basic " + Data("login-name:app-password".utf8).base64EncodedString())
    }
}

private actor PendingLoginTransport: DAVTransport {
    var pending = true
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        if pending { pending = false; throw UploadError.http(404) }
        return DAVResponse(status: 200, data: Data(#"{"server":"https://b.example","loginName":"new","appPassword":"new-password"}"#.utf8))
    }
}

extension LoginFlowTests {
    func testRealTransportStyle404ContinuesPolling() async throws {
        let service = NextcloudLoginFlowService(transport: PendingLoginTransport(), pollInterval: .milliseconds(1), timeout: .seconds(1))
        let start = LoginFlowStartResponse(poll: .init(token: "test", endpoint: URL(string: "https://b.example/poll")!), login: URL(string: "https://b.example/login")!)
        let credentials = try await service.poll(start)
        XCTAssertEqual(credentials.server.host, "b.example")
        XCTAssertEqual(credentials.loginName, "new")
    }

    func testSwitchBuildsFreshClientUsingOnlyReturnedCredentials() async throws {
        let old = NextcloudConnectionClient(connection: try ConnectorConnection(server: "https://a.example", user: "old", password: "old"))
        let transport = LoginFlowTransport([
            DAVResponse(status: 200, data: Data(#"{"poll":{"token":"test","endpoint":"https://b.example/custom/poll"},"login":"https://b.example/login"}"#.utf8)),
            DAVResponse(status: 200, data: Data(#"{"server":"https://confirmed.example","loginName":"new","appPassword":"new-password"}"#.utf8))
        ])
        let service = NextcloudLoginFlowService(transport: transport)
        let start = try await service.initiate(server: "https://b.example")
        let credentials = try await service.poll(start)
        let client = NextcloudConnectionClient(connection: try ConnectorConnection(server: credentials.server.absoluteString, user: credentials.loginName, password: credentials.appPassword))
        XCTAssertEqual(transport.requests.map { $0.url!.absoluteString }, ["https://b.example/index.php/login/v2", "https://b.example/custom/poll"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(client.statusRequest().url?.host, "confirmed.example")
        XCTAssertEqual(client.statusRequest().value(forHTTPHeaderField: "Authorization"), "Basic " + Data("new:new-password".utf8).base64EncodedString())
        XCTAssertFalse((old.transport as AnyObject) === (client.transport as AnyObject))
    }
}
