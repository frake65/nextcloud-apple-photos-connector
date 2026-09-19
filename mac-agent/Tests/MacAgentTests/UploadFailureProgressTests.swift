import XCTest
@testable import InventoryCore
@testable import MacAgent
@testable import MacAgentSupport

actor MKCOLCounter {
    var calls = 0; var active = 0; var maximum = 0
    func run() async { calls += 1; active += 1; maximum = max(maximum, active); try? await Task.sleep(for: .milliseconds(5)); active -= 1 }
}

final class UploadFailureProgressTests: XCTestCase {
    enum Mode: Sendable { case success, put413, timeout, export, complete, known, inventory, prepare, folder, receipt }
    struct Exporter: PhotoOriginalExporting {
        let mode: Mode
        func export(localIdentifier: String) async throws -> PhotoOriginalExporter.Export {
            if mode == .export && localIdentifier == "local1" { throw PhotoOriginalExporter.ExportError.unavailable }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("original")
            try Data("test".utf8).write(to: url)
            return .init(url: url, filename: "same.jpg")
        }
    }
    actor Transport: DAVTransport {
        let mode: Mode
        private(set) var mkcolCalls = 0
        private(set) var activeMKCOL = 0
        private(set) var maxActiveMKCOL = 0
        private(set) var putCalls = 0
        init(_ mode: Mode) { self.mode = mode }
        func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
            let path = request.url!.path
            func json(_ value: Any) throws -> DAVResponse { DAVResponse(status: 200, data: try JSONSerialization.data(withJSONObject: value)) }
            if path.hasSuffix("/inventory") {
                if mode == .inventory { throw URLError(.timedOut) }
                return try json(["runId": "run", "assets": (0..<3).map { i -> [String: Any] in
                    mode == .known ? ["state": "known"] : ["state": "new", "upload": ["uploadId": "u\(i)", "assetId": "\(i+1)"]]
                }])
            }
            if request.httpMethod == "MKCOL" {
                mkcolCalls += 1; activeMKCOL += 1; maxActiveMKCOL = max(maxActiveMKCOL, activeMKCOL)
                try? await Task.sleep(for: .milliseconds(5))
                activeMKCOL -= 1
                return DAVResponse(status: mode == .folder ? 403 : 405)
            }
            if path.hasSuffix("/uploads/prepare") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let id = Int(String((body["uploadId"] as! String).dropFirst()))! + 1
                if mode == .prepare && id == 2 { return DAVResponse(status: 404) }
                return try json(["assetId": "\(id)", "path": "Root/2024/01/same.jpg", "bytes": 4,
                                 "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "state": "missing"])
            }
            if request.httpMethod == "PUT" {
                putCalls += 1
                if putCalls == 2 {
                    if mode == .put413 { throw UploadError.http(413) }
                    if mode == .timeout { throw URLError(.timedOut) }
                }
                return DAVResponse(status: 201)
            }
            if path.hasSuffix("/uploads/complete") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if mode == .complete && body["uploadId"] as? String == "u1" { return DAVResponse(status: 507) }
                return DAVResponse(status: 200)
            }
            XCTFail("Unexpected request"); return DAVResponse(status: 500)
        }
    }
    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var progress: [UploadCoordinator.Progress] = []
        var uploaded: [String] = []
        func receive(_ value: UploadCoordinator.Progress) { lock.lock(); defer { lock.unlock() }; progress.append(value) }
        func success(_ value: String) { lock.lock(); defer { lock.unlock() }; uploaded.append(value) }
    }
    private func run(_ mode: Mode) async throws -> (UploadCoordinator.RunSummary, Events) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var receiptURL = dir.appendingPathComponent("receipts.json")
        if mode == .receipt {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let blocked = dir.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocked)
            receiptURL = blocked.appendingPathComponent("receipts.json")
        }
        let coordinator = UploadCoordinator(exporter: Exporter(mode: mode), transport: Transport(mode), receiptURL: receiptURL)
        let events = Events()
        let summary = try await coordinator.run(json: payload(), connection: connection(), targetRoot: "Root", progress: { events.receive($0) }, onUploaded: { events.success($0) })
        return (summary, events)
    }
    private func payload() throws -> String {
        try InventoryJSON.encode((0..<3).map {
            AssetInventory(localIdentifier: "local\($0)", mediaType: "image", creationDate: Date(timeIntervalSince1970: 0), filename: "same.jpg")
        }, source: PhotoSource(sourceId: UUID(), name: "Test"))
    }
    private func connection() throws -> ConnectorConnection { try ConnectorConnection(server: "https://example.invalid", user: "test", password: "test") }

    func testMixedRunKeepsFailureWithCauseAndDoesNotCloseOrDeselectFailedAsset() async throws {
        let (summary, events) = try await run(.put413)
        XCTAssertEqual(summary.uploadedImages, 2); XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: summary.failed, albumFailed: false), .failed)
        XCTAssertFalse(summary.shouldCloseProgressSheet)
        let final = summary.finalProgress
        XCTAssertTrue(final.finished); XCTAssertEqual(final.completed, 3)
        XCTAssertEqual(final.items.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(final.items.filter { $0.status == .uploaded }.count, 2)
        XCTAssertEqual(Set(final.items.map(\.id)).count, 3) // identical filenames must not collide
        let failure = try XCTUnwrap(final.items.first(where: { $0.status == .failed })?.error)
        XCTAssertEqual(failure.httpStatus, 413); XCTAssertEqual(failure.stage, .put)
        XCTAssertEqual(failure.category, .tooLarge); XCTAssertFalse(failure.userMessage.isEmpty)
        XCTAssertEqual(events.progress.last?.items.filter { $0.status == .failed }.count, 1)
        let remainingSelection = Set(["local:local0", "local:local1", "local:local2"]).subtracting(events.uploaded)
        XCTAssertEqual(remainingSelection.count, 1)
        XCTAssertEqual(final.items.filter { $0.status == .failed }.count, 1)
    }
    func testKnownAssetsNeedNoUploadAndCompleteSuccessfully() async throws {
        let (summary, _) = try await run(.known)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.uploadedImages, 0)
        XCTAssertEqual(summary.alreadyInCloudImages, 3)
        XCTAssertEqual(ImportRunState.finalState(uploadFailures: summary.failed, albumFailed: false), .completed)
    }
    func testUnknownInventoryFailureDoesNotClaimFileTransferFailed() {
        let failure = UploadFailure.capture(UploadError.diagnostic("inventory unavailable"), stage: .inventory)
        XCTAssertEqual(failure.stage, .inventory)
        XCTAssertEqual(failure.category, .unknown)
        XCTAssertEqual(failure.userMessage, L10n.text("inventoryFailureUnknown"))
        XCTAssertNotEqual(failure.userMessage, L10n.text("uploadFailureUnknown"))
    }
    func testExportAndTimeoutFailuresReachFinalRows() async throws {
        for (mode, category, stage) in [(Mode.export, UploadFailure.Category.source, UploadFailure.Stage.export), (.timeout, .timeout, .put), (.prepare, .notFound, .target)] {
            let (summary, _) = try await run(mode)
            XCTAssertEqual(summary.failed, 1)
            let failed = try XCTUnwrap(summary.finalProgress.items.first(where: { $0.status == .failed }))
            XCTAssertEqual(failed.error?.category, category)
            XCTAssertEqual(failed.error?.stage, stage)
        }
    }
    func testCompletionFailureFinishesRowAndRetainsHTTPAndTarget() async throws {
        let (summary, events) = try await run(.complete)
        XCTAssertEqual(summary.failed, 1); XCTAssertEqual(summary.finalProgress.completed, 3)
        let item = summary.finalProgress.items[1]
        XCTAssertEqual(item.status, .failed); XCTAssertNotNil(item.target)
        XCTAssertEqual(item.error?.httpStatus, 507); XCTAssertEqual(item.error?.stage, .completion)
        XCTAssertFalse(events.uploaded.contains("local:local1"))
    }
    func testConcurrentUploadsCoordinateSharedMKCOLPaths() async throws {
        let coordinator = WebDAVFolderCoordinator()
        let counter = MKCOLCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try? await coordinator.ensure(path: "shared", operation: { await counter.run() }) } }
        }
        let calls = await counter.calls
        let maximum = await counter.maximum
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(maximum, 1)
    }

    func testSuccessfulAndKnownRunsStillCloseAndMKCOL405IsNotFailure() async throws {
        for mode in [Mode.success, .known] {
            let (summary, _) = try await run(mode)
            XCTAssertTrue(summary.shouldCloseProgressSheet); XCTAssertTrue(summary.finalProgress.finished)
            XCTAssertEqual(summary.failed, 0)
            XCTAssertTrue(summary.finalProgress.items.allSatisfy { $0.error == nil })
            XCTAssertEqual(summary.finalProgress.items.map(\.status), Array(repeating: mode == .known ? .alreadyInCloud : .uploaded, count: 3))
        }
    }
    func testFolderFailureAndInventoryTimeoutRemainVisible() async throws {
        let (summary, _) = try await run(.folder)
        XCTAssertEqual(summary.failed, 3)
        XCTAssertTrue(summary.finalProgress.items.allSatisfy { $0.error?.stage == .folder && $0.error?.httpStatus == 403 })
        let events = Events()
        let receipt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("receipts.json")
        let coordinator = UploadCoordinator(exporter: Exporter(mode: .success), transport: Transport(.inventory), receiptURL: receipt)
        do { _ = try await coordinator.run(json: payload(), connection: connection(), progress: { events.receive($0) }); XCTFail("Expected timeout") } catch { }
        XCTAssertEqual(events.progress.last?.items.count, 3)
        XCTAssertTrue(events.progress.last!.items.allSatisfy { $0.status == .failed && $0.error?.category == .timeout })
    }
    func testLocalReceiptFailureDoesNotLeaveRowsUploading() async throws {
        let (summary, events) = try await run(.receipt)
        XCTAssertEqual(summary.failed, 3); XCTAssertTrue(summary.finalProgress.finished)
        XCTAssertFalse(summary.shouldCloseProgressSheet); XCTAssertTrue(events.uploaded.isEmpty)
        XCTAssertTrue(summary.finalProgress.items.allSatisfy { $0.status == .failed && $0.error?.stage == .receipt && $0.error?.category == .filesystem })
    }
    func testFailureCategoriesAndLocalizedMessages() {
        for (code, category) in [(401, UploadFailure.Category.authorization), (403, .authorization), (404, .notFound), (413, .tooLarge), (507, .storageFull), (503, .server), (409, .http)] {
            XCTAssertEqual(UploadFailure.capture(UploadError.http(code), stage: .put).category, category)
        }
        XCTAssertEqual(UploadFailure.capture(URLError(.notConnectedToInternet), stage: .put).category, .network)
        XCTAssertEqual(UploadFailure.capture(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), stage: .receipt).category, .filesystem)
        XCTAssertEqual(UploadFailure.capture(UploadError.invalidResponse, stage: .target).category, .response)
        for (key, translations) in L10n.values where key.hasPrefix("uploadFailure") || key.hasPrefix("importRun") || key.hasPrefix("asset") {
            for language in L10n.supportedLanguages where language != "system" {
                XCTAssertFalse(translations[language, default: ""].isEmpty, "\(key)/\(language)")
            }
        }
    }
}

extension UploadFailureProgressTests {
    func testNormalImportStartCreatesProgressBeforeInventory() async throws {
        let events = Events()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = UploadCoordinator(exporter: Exporter(mode: .success), transport: Transport(.known), receiptURL: directory.appendingPathComponent("receipts.json"))
        let summary = try await coordinator.run(json: payload(), connection: connection(), progress: { events.receive($0) })
        XCTAssertFalse(events.progress.isEmpty)
        XCTAssertEqual(events.progress.first?.items.count, 3)
        XCTAssertEqual(summary.finalProgress.items.count, 3)
        XCTAssertEqual(summary.failed, 0)
    }
}
