import XCTest
@testable import InventoryCore

final class WebDAVTargetRootTests: XCTestCase {
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
}

private actor TestCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
