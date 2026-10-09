import XCTest
@testable import InventoryCore

final class WebDAVTargetRootTests: XCTestCase {
    final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func cancel() { lock.lock(); calls += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    func testUploadCancellationCancelsRegisteredTaskInBothRaceOrders() {
        let registeredFirst = URLSessionUploadCancellation()
        let firstProbe = CancellationProbe()
        registeredFirst.register { firstProbe.cancel() }
        registeredFirst.cancel()
        XCTAssertEqual(firstProbe.count(), 1)

        let cancelledFirst = URLSessionUploadCancellation()
        let secondProbe = CancellationProbe()
        cancelledFirst.cancel()
        cancelledFirst.register { secondProbe.cancel() }
        XCTAssertEqual(secondProbe.count(), 1)
    }
    func testNetworkTimeoutClassesKeepNormalAndLongRunningSemantics() {
        XCTAssertEqual(NetworkTransport.timeout(for: .api).request, 20)
        XCTAssertEqual(NetworkTransport.timeout(for: .api).resource, 30)
        XCTAssertEqual(NetworkTransport.timeout(for: .longRunningVerification).request, 1800)
        XCTAssertEqual(NetworkTransport.timeout(for: .longRunningVerification).resource, 1800)
        XCTAssertEqual(NetworkTransport.timeout(for: .fileTransfer).request, 1800)
        XCTAssertEqual(NetworkTransport.timeout(for: .fileTransfer).resource, 1800)
    }

    func testConfiguredRootsAndBoundaryAreComponentSafe() {
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Photos/Apple Photos Connector/2026/09/a.jpg", under: "Photos/Apple Photos Connector"))
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Archive/Camera A/2026/09/a.jpg", under: "Archive/Camera A"))
        XCTAssertTrue(WebDAVUploader.isValidTargetPath("Root/Nested/2026/09/a.jpg", under: "Root/Nested"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("Root2/2026/09/a.jpg", under: "Root"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("Root/../other/a.jpg", under: "Root"))
        XCTAssertFalse(WebDAVUploader.isValidTargetPath("/Root/2026/09/a.jpg", under: "Root"))
    }

    func testUploadWithTargetUsesProvidedIdentityForPrepare() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file contents".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let supplied = ContentIdentity(bytes: 987, sha256: String(repeating: "a", count: 64))
        let targets = CapturingUploadTargets(identity: supplied)
        let uploader = WebDAVUploader(connection: try ConnectorConnection(server: "https://example.com", user: "user", password: "password"), transport: SuccessfulDAVTransport())

        _ = try await uploader.uploadWithTarget(file: file, filename: "video.mov", assetId: "7", captureDate: Date(timeIntervalSince1970: 1), targets: targets, contentIdentity: supplied)

        let received = await targets.received
        XCTAssertEqual(received, supplied)
    }

    func testRunLocalFolderCoordinatorEnsuresSuccessfulPathsOnceAndRetriesFailures() async throws {
        let coordinator = WebDAVFolderCoordinator()
        let counter = TestCallCounter()
        try await coordinator.ensure(path: "Photos", operation: { await counter.increment() })
        try await coordinator.ensure(path: "Photos", operation: { await counter.increment() })
        let firstCalls = await counter.value
        XCTAssertEqual(firstCalls, 1)
        let ensured = await coordinator.isEnsured(path: "Photos")
        XCTAssertTrue(ensured)

        let failedCounter = TestCallCounter()
        do {
            try await coordinator.ensure(path: "Photos/2026", operation: { await failedCounter.increment(); throw UploadError.http(500) })
        } catch { }
        try await coordinator.ensure(path: "Photos/2026", operation: { await failedCounter.increment() })
        let failedCalls = await failedCounter.value
        XCTAssertEqual(failedCalls, 2)
        let retriedPathEnsured = await coordinator.isEnsured(path: "Photos/2026")
        XCTAssertTrue(retriedPathEnsured)
    }

    func testRunLocalFolderCoordinatorAcceptsAlreadyExistingFolderResult() async throws {
        let coordinator = WebDAVFolderCoordinator()
        let counter = TestCallCounter()
        try await coordinator.ensure(path: "Photos/Apple Photos Connector", operation: { await counter.increment() /* HTTP 405 is accepted by the caller */ })
        try await coordinator.ensure(path: "Photos/Apple Photos Connector", operation: { await counter.increment() })
        let existingCalls = await counter.value
        XCTAssertEqual(existingCalls, 1)
    }

    func testRunLocalFolderCoordinatorSeparatesYearFoldersAndSharesParents() async throws {
        let coordinator = WebDAVFolderCoordinator()
        let counter = TestCallCounter()
        for path in ["Photos", "Photos/Apple Photos Connector", "Photos/Apple Photos Connector/2026"] {
            try await coordinator.ensure(path: path, operation: { await counter.increment() })
            try await coordinator.ensure(path: path, operation: { await counter.increment() })
        }
        try await coordinator.ensure(path: "Photos/Apple Photos Connector/2027", operation: { await counter.increment() })
        let calls = await counter.value
        XCTAssertEqual(calls, 4)
    }

    func testUploadAcceptsSuccessfulWebDAVPutStatuses() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file contents".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let supplied = ContentIdentity(bytes: 12, sha256: String(repeating: "b", count: 64))

        for status in [200, 201, 204] {
            let uploader = WebDAVUploader(
                connection: try ConnectorConnection(server: "https://example.com", user: "user", password: "password"),
                transport: StatusDAVTransport(putStatus: status)
            )
            _ = try await uploader.uploadWithTarget(
                file: file,
                filename: "video.mov",
                assetId: "7",
                captureDate: Date(timeIntervalSince1970: 1),
                targets: CapturingUploadTargets(identity: supplied),
                contentIdentity: supplied
            )
        }

        let rejected = WebDAVUploader(
            connection: try ConnectorConnection(server: "https://example.com", user: "user", password: "password"),
            transport: StatusDAVTransport(putStatus: 202)
        )
        do {
            _ = try await rejected.uploadWithTarget(
                file: file,
                filename: "video.mov",
                assetId: "7",
                captureDate: Date(timeIntervalSince1970: 1),
                targets: CapturingUploadTargets(identity: supplied),
                contentIdentity: supplied
            )
            XCTFail("expected unsupported PUT status")
        } catch UploadError.http(let status) {
            XCTAssertEqual(status, 202)
        }
    }

    func testUploadPropagatesHTTP413FromPut() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("large file placeholder".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = ContentIdentity(bytes: 22, sha256: String(repeating: "c", count: 64))
        let uploader = WebDAVUploader(
            connection: try ConnectorConnection(server: "https://example.com", user: "user", password: "password"),
            transport: StatusDAVTransport(putStatus: 413)
        )

        do {
            _ = try await uploader.uploadWithTarget(
                file: file,
                filename: "video.mov",
                assetId: "7",
                captureDate: Date(timeIntervalSince1970: 1),
                targets: CapturingUploadTargets(identity: identity),
                contentIdentity: identity
            )
            XCTFail("expected HTTP 413")
        } catch UploadError.http(let status) {
            XCTAssertEqual(status, 413)
        }
    }

    func testWebDAVDiagnosticsRedactUsernamesAndSecrets() {
        let url = URL(string: "https://example.com/remote.php/dav/files/alice/Photos/photo.jpg?token=secret")!
        XCTAssertEqual(
            DAVDiagnostics.sanitizedPath(url, user: "alice"),
            "/remote.php/dav/files/<user>/Photos/photo.jpg"
        )

        let headers = DAVDiagnostics.safeHeaders([
            "Location": "https://alice:password@example.com/next?token=secret",
            "Server": "Nextcloud",
            "Content-Type": "text/plain"
        ])
        XCTAssertFalse(headers.contains("alice"))
        XCTAssertFalse(headers.contains("password"))

        let body = DAVDiagnostics.safeBody(Data("Authorization: Bearer secret password=top-secret token=abc".utf8))
        XCTAssertFalse(body.contains("Bearer secret"))
        XCTAssertFalse(body.contains("top-secret"))
        XCTAssertFalse(body.contains("token=abc"))
        XCTAssertTrue(body.contains("<redacted>"))
    }
}

private actor CapturingUploadTargets: UploadTargetProvider {
    let identity: ContentIdentity
    private(set) var received: ContentIdentity?

    init(identity: ContentIdentity) { self.identity = identity }

    func prepare(identity: ContentIdentity) async throws -> UploadTarget {
        received = identity
        return UploadTarget(assetId: "7", path: "Photos/Apple Photos Connector/2026/09/video.mov", identity: self.identity, state: "missing")
    }
}

private struct SuccessfulDAVTransport: DAVTransport {
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        DAVResponse(status: request.httpMethod == "PUT" ? 201 : 405)
    }

    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        DAVResponse(status: request.httpMethod == "PUT" ? 201 : 405)
    }
}

private struct StatusDAVTransport: DAVTransport {
    let putStatus: Int

    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        DAVResponse(status: request.httpMethod == "PUT" ? putStatus : 405)
    }

    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        DAVResponse(status: request.httpMethod == "PUT" ? putStatus : 405)
    }
}

private actor TestCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
