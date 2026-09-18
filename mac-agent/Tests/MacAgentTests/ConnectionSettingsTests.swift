import XCTest
@testable import InventoryCore
@testable import MacAgentSupport

private struct FakeDAVTransport: DAVTransport {
    let result: Result<DAVResponse, Error>
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { try result.get() }
}
private final class SequenceDAVTransport: DAVTransport, @unchecked Sendable {
    private var responses: [Result<DAVResponse, Error>]
    init(_ responses: [Result<DAVResponse, Error>]) { self.responses = responses }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { try responses.removeFirst().get() }
}
private final class RecordingDAVTransport: DAVTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 201) { self.status = status }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { requests.append(request); return DAVResponse(status: status) }
}

final class ConnectionSettingsTests: XCTestCase {
    func testTargetDirectoryIsNormalizedAndRelative() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var prefs = TargetDirectoryPreferences(defaults: defaults)
        prefs.path = "/Photos//Meine Fotos/./Connector"
        XCTAssertEqual(prefs.path, "Photos/Meine Fotos/Connector")
    }

    func testDAVDirectoryParserHandlesNamespacesAndUnicode() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/remote.php/dav/files/u/Photos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response><d:response><d:href>/remote.php/dav/files/u/Photos/Meine%20Fotos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>
        """
        let result = try DAVDirectoryParser.parse(Data(xml.utf8), relativeTo: ["Photos"])
        XCTAssertEqual(result.map(\.name), ["Meine Fotos"])
        XCTAssertEqual(result.first?.path, "Photos/Meine Fotos")
    }

    func testConnectionValidationClassifiesResponses() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "u", password: "p")
        let success = await NextcloudConnectionClient(connection: connection, transport: FakeDAVTransport(result: .success(DAVResponse(status: 200, data: Data(#"{"installed":true,"app":"apple_photos_connector"}"#.utf8))))).validate()
        XCTAssertEqual(success.result, .success)
        XCTAssertEqual(success.appStatusCode, 200)
        let unauthorized = await NextcloudConnectionClient(connection: connection, transport: FakeDAVTransport(result: .success(DAVResponse(status: 401)))).validate()
        XCTAssertEqual(unauthorized.result, .authenticationFailed)
        let unavailable = await NextcloudConnectionClient(connection: connection, transport: FakeDAVTransport(result: .success(DAVResponse(status: 503)))).validate()
        XCTAssertEqual(unavailable.result, .unavailable)
        let network = await NextcloudConnectionClient(connection: connection, transport: FakeDAVTransport(result: .failure(URLError(.timedOut)))).validate()
        XCTAssertEqual(network.result, .unreachable)
        let appMissing = await NextcloudConnectionClient(connection: connection, transport: SequenceDAVTransport([.success(DAVResponse(status: 200, data: Data(#"{"installed":true}"#.utf8))), .success(DAVResponse(status: 404))])).validate()
        XCTAssertEqual(appMissing.result, .appMissing)
        let appServerError = await NextcloudConnectionClient(connection: connection, transport: SequenceDAVTransport([.success(DAVResponse(status: 200, data: Data(#"{"installed":true}"#.utf8))), .success(DAVResponse(status: 503))])).validate()
        XCTAssertEqual(appServerError.result, .unavailable)
    }

    func testSettingsChangeBuildsRequestFromCurrentServerAndUser() throws {
        let old = try ConnectorConnection(server: "https://old.example", user: "olduser", password: "dummy")
        let current = try ConnectorConnection(server: "https://cloud.example.com", user: "test-user", password: "dummy")
        XCTAssertEqual(old.request(path: ["status.php"], method: "GET").url?.absoluteString, "https://old.example/status.php")
        let request = NextcloudConnectionClient(connection: current).statusRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://cloud.example.com/status.php")
        XCTAssertEqual(current.user, "test-user")
    }

    func testFolderNameValidationAndMKCOLPath() async throws {
        XCTAssertEqual(DAVPathValidator.component("  Meine Fotos  "), "Meine Fotos")
        XCTAssertNil(DAVPathValidator.component("")); XCTAssertNil(DAVPathValidator.component(".")); XCTAssertNil(DAVPathValidator.component(".."))
        XCTAssertNil(DAVPathValidator.component("a/b")); XCTAssertNil(DAVPathValidator.component("a\\b"))
        let transport = RecordingDAVTransport()
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "test-user", password: "dummy")
        let result = try await NextcloudConnectionClient(connection: connection, transport: transport).createDirectory(parent: ["Photos"], name: "Meine Fotos")
        XCTAssertEqual(result.path, "Photos/Meine Fotos")
        XCTAssertEqual(transport.requests.first?.httpMethod, "MKCOL")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://cloud.example/remote.php/dav/files/test-user/Photos/Meine%20Fotos")
    }

    func testMKCOLErrorsAreSpecific() async throws {
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "test-user", password: "dummy")
        for (status, text) in [(401, "Keine Berechtigung"), (405, "existiert möglicherweise"), (409, "übergeordnete"), (503, "Serverfehler")] {
            do { _ = try await NextcloudConnectionClient(connection: connection, transport: RecordingDAVTransport(status: status)).createDirectory(parent: ["Photos"], name: "Neu") ; XCTFail("expected error") }
            catch let error as LocalizedError { XCTAssertTrue((error.errorDescription ?? "").contains(text)) }
        }
    }

    func testDAVNodeAccessibilityIdentifiersAreDeterministicAndSafe() {
        XCTAssertEqual(DAVNodeIdentifier.make(for: "Photos/Meine Fotos"), "Photos-Meine-Fotos")
        XCTAssertEqual(DAVNodeIdentifier.make(for: "Photos/Ä/日本"), "Photos-----")
        XCTAssertEqual(DAVNodeIdentifier.make(for: "Photos/Meine Fotos"), DAVNodeIdentifier.make(for: "Photos/Meine Fotos"))
    }

    func testImportGuardRequiresCompleteCurrentConfiguration() {
        let valid = ImportConfigurationState(serverSet: true, userSet: true, passwordAvailable: true, connectionValidated: true, targetSet: true, targetConfirmed: true)
        XCTAssertNil(ImportGuard.failure(for: valid))
        XCTAssertNotNil(ImportGuard.failure(for: ImportConfigurationState(serverSet: true, userSet: true, passwordAvailable: true, connectionValidated: false, targetSet: true, targetConfirmed: true)))
        XCTAssertNotNil(ImportGuard.failure(for: ImportConfigurationState(serverSet: true, userSet: true, passwordAvailable: true, connectionValidated: true, targetSet: false, targetConfirmed: false)))
        XCTAssertNotNil(ImportGuard.failure(for: ImportConfigurationState(serverSet: true, userSet: true, passwordAvailable: true, connectionValidated: true, targetSet: true, targetConfirmed: false)))
    }

    func testLocalPhotoBrowsingDoesNotRequireUploadValidation() {
        XCTAssertTrue(PhotoKitBrowsingEligibility.allows(authorized: true))
        XCTAssertFalse(PhotoKitBrowsingEligibility.allows(authorized: false))
        let uploadBlocked = ImportConfigurationState(serverSet: true, userSet: true, passwordAvailable: true, connectionValidated: true, targetSet: true, targetConfirmed: false)
        XCTAssertNotNil(ImportGuard.failure(for: uploadBlocked))
    }

    func testValidationKeysArePersistentAndCanonical() {
        XCTAssertEqual(ImportGuard.validatedKey, "nextcloud.connectionValidated")
        XCTAssertEqual(TargetDirectoryPreferences.confirmedKey, "nextcloud.targetValidated")
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ImportGuard.validatedKey)
        defaults.set(true, forKey: TargetDirectoryPreferences.confirmedKey)
        let fresh = UserDefaults(suiteName: suite)!
        XCTAssertTrue(fresh.bool(forKey: ImportGuard.validatedKey))
        XCTAssertTrue(fresh.bool(forKey: TargetDirectoryPreferences.confirmedKey))
    }

    func testTargetSelectionPersistsPathAndConfirmationAcrossInstances() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var first = TargetDirectoryPreferences(defaults: defaults)
        first.path = "Photos/Apple Photos Connector"
        first.markConfirmed(true)
        var second = TargetDirectoryPreferences(defaults: defaults)
        XCTAssertEqual(second.path, "Photos/Apple Photos Connector")
        XCTAssertTrue(defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey))
        second.markConfirmed(false)
        XCTAssertEqual(second.path, "Photos/Apple Photos Connector")
        XCTAssertFalse(defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey))
    }
}
