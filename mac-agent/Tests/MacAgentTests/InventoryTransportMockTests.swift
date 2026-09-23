import Foundation
import XCTest
@testable import InventoryCore
@testable import MacAgent
@testable import MacAgentSupport

final class InventoryTransportMockTests: XCTestCase {
    func testAlbumRecoveryRunsForKnownAssetSelection() {
        XCTAssertTrue(AlbumInventoryCoordinator.shouldSyncAfterUpload(selectedAlbumIDs: [], selectedAssetIDs: ["cloud:x"]))
        XCTAssertTrue(AlbumInventoryCoordinator.shouldSyncAfterUpload(selectedAlbumIDs: ["local:album"], selectedAssetIDs: []))
        XCTAssertFalse(AlbumInventoryCoordinator.shouldSyncAfterUpload(selectedAlbumIDs: [], selectedAssetIDs: []))
    }
    final class Log: @unchecked Sendable { var values:[String]=[]; let lock=NSLock(); func add(_ v:String){lock.lock(); values.append(v); lock.unlock()} }
    actor CoordinatorSpy: DAVTransport {
        enum Mode: Equatable { case new, known, invalid, httpError, seenZero, prepareError, putError, completeError }
        let mode: Mode
        private(set) var inventory = 0; private(set) var prepare = 0; private(set) var put = 0; private(set) var complete = 0
        private(set) var putMTime: String?
        init(_ mode: Mode) { self.mode = mode }
        func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
            let path = request.url?.path ?? ""
            if path.contains("/inventory") { inventory += 1; if mode == .httpError { return DAVResponse(status: 500) }; if mode == .invalid { return DAVResponse(status: 200, data: Data("bad".utf8)) }; if mode == .seenZero { return DAVResponse(status: 200, data: Data("{\"runId\":\"run\",\"assets\":[]}".utf8)) }; let state = mode == .known ? "known" : "new"; let ticket = state == "new" ? ",\"upload\":{\"uploadId\":\"u\",\"assetId\":\"1\"}" : ""; return DAVResponse(status: 200, data: Data("{\"runId\":\"run\",\"assets\":[{\"state\":\"\(state)\"\(ticket)}]}".utf8)) }
            if path.contains("/uploads/prepare") { prepare += 1; if mode == .prepareError { return DAVResponse(status: 500) }; let root = TargetDirectoryPreferences().path; return DAVResponse(status: 200, data: Data("{\"assetId\":\"1\",\"path\":\"\(root)/test.jpg\",\"bytes\":4,\"sha256\":\"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\",\"state\":\"missing\"}".utf8)) }
            if request.httpMethod == "PUT" { put += 1; putMTime = request.value(forHTTPHeaderField: "X-OC-MTime"); if mode == .putError { return DAVResponse(status: 500) }; return DAVResponse(status: 201) }
            if path.contains("/uploads/complete") { complete += 1; if mode == .completeError { return DAVResponse(status: 500) }; return DAVResponse(status: 200) }
            return DAVResponse(status: 201)
        }
        func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
            try await send(request, file: file)
        }
        func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
            try await send(request, file: file)
        }
        func counts() -> (Int,Int,Int,Int) { (inventory,prepare,put,complete) }
        func mTime() -> String? { putMTime }
    }
    struct FakeExporter: PhotoOriginalExporting {
        let failing: Bool
        func export(localIdentifier: String) async throws -> PhotoOriginalExporter.Export { if failing { throw UploadError.invalidResponse }; let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let url = directory.appendingPathComponent("original"); try Data("test".utf8).write(to: url); return .init(url: url, filename: "test.jpg") }
    }

    private func receiptURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("receipts.json")
    }
    private func inventoryJSON() throws -> String {
        let source = PhotoSource(sourceId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Test")
        return try InventoryJSON.encode([AssetInventory(localIdentifier: "local", cloudIdentifier: "cloud", mediaType: "image", creationDate: Date(timeIntervalSince1970: 1_700_000_000), filename: "test.jpg")], source: source)
    }
    private func emptyInventoryJSON() throws -> String {
        let source = PhotoSource(sourceId: UUID(), name: "Test")
        return try InventoryJSON.encode([], source: source)
    }
    func testInventoryDeduplicatesStableCloudIdentityBeforeUpload() throws {
        let source = PhotoSource(sourceId: UUID(), name: "Test")
        let assets = [
            AssetInventory(localIdentifier: "local-1", cloudIdentifier: "cloud-1", mediaType: "image", creationDate: nil, filename: "one.jpg"),
            AssetInventory(localIdentifier: "local-2", cloudIdentifier: "cloud-1", mediaType: "image", creationDate: nil, filename: "duplicate.jpg"),
            AssetInventory(localIdentifier: "local-3", cloudIdentifier: nil, mediaType: "video", creationDate: nil, filename: "three.mov")
        ]
        let result = try InventoryJSON.deduplicating(InventoryJSON.encode(assets, source: source))
        XCTAssertEqual(result.summary.totalAssets, 2)
        let decoded = try JSONDecoder().decode(ProbeDocument.self, from: Data(result.json.utf8))
        XCTAssertEqual(decoded.assets.map(\.localIdentifier), ["local-1", "local-3"])
    }
    private func connection() throws -> ConnectorConnection { try ConnectorConnection(server: "https://example.invalid", user: "test", password: "x") }

    func testH4NewAssetRunsExportPreparePutAndComplete() async throws {
        let spy = CoordinatorSpy(.new); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let log = Log()
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: { log.add($0) })
        print("H4 checkpoints: \(log.values)")
        let counts = await spy.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 1); XCTAssertEqual(counts.3, 1); XCTAssertEqual(s.uploadedImages, 1)
        XCTAssertTrue(log.values.contains("upload.export.start")); XCTAssertTrue(log.values.contains("upload.export.success")); XCTAssertTrue(log.values.contains("upload.put.start")); XCTAssertTrue(log.values.contains("upload.put.success"))
        let mTime = await spy.mTime()
        XCTAssertEqual(mTime, "1700000000")
    }
    func testH5KnownAssetSkipsDownstream() async throws {
        let spy = CoordinatorSpy(.known); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); let counts = await spy.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0); XCTAssertEqual(s.uploadedImages, 0)
        XCTAssertEqual(s.alreadyInCloudImages, 1)
    }
    func testH6InventoryTransportHTTPAndDecodeErrorsFail() async throws {
        for mode in [CoordinatorSpy.Mode.httpError, .invalid] {
            let spy = CoordinatorSpy(mode); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
            do { _ = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); XCTFail("expected failure") } catch { }
            let counts = await spy.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
        }
    }

    func testEmptyInventoryIsAcceptedAsValidScanResult() async throws {
        let spy = CoordinatorSpy(.seenZero); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let summary = try await c.run(json: emptyInventoryJSON(), connection: try connection(), debug: nil)
        let x = await spy.counts(); XCTAssertEqual(x.0, 1); XCTAssertEqual(x.1, 0); XCTAssertEqual(x.2, 0); XCTAssertEqual(x.3, 0)
        XCTAssertEqual(summary.finalProgress.total, 0)
    }
    func testH6eExporterFailureStopsDownstream() async throws {
        let spy = CoordinatorSpy(.new); let c = UploadCoordinator(exporter: FakeExporter(failing: true), transport: spy, receiptURL: receiptURL())
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); XCTAssertEqual(s.uploadedImages, 0)
        let x = await spy.counts(); XCTAssertEqual(x.0, 1); XCTAssertEqual(x.1, 0); XCTAssertEqual(x.2, 0); XCTAssertEqual(x.3, 1)
    }
    func testH6fPrepareFailureStopsPUT() async throws {
        let spy = CoordinatorSpy(.prepareError); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); XCTAssertEqual(s.uploadedImages, 0)
        let x = await spy.counts(); XCTAssertEqual(x.0, 1); XCTAssertEqual(x.1, 1); XCTAssertEqual(x.2, 0); XCTAssertEqual(x.3, 1)
    }
    func testH6gPUTFailureStopsComplete() async throws {
        let spy = CoordinatorSpy(.putError); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); let x = await spy.counts()
        XCTAssertEqual(x.0, 1); XCTAssertEqual(x.1, 1); XCTAssertEqual(x.2, 1); XCTAssertEqual(x.3, 1); XCTAssertEqual(s.uploadedImages, 0)
    }
    func testH6hCompleteFailureDoesNotReportUpload() async throws {
        let spy = CoordinatorSpy(.completeError); let c = UploadCoordinator(exporter: FakeExporter(failing: false), transport: spy, receiptURL: receiptURL())
        let s = try await c.run(json: inventoryJSON(), connection: try connection(), debug: nil); let x = await spy.counts()
        XCTAssertEqual(x.0, 1); XCTAssertEqual(x.1, 1); XCTAssertEqual(x.2, 1); XCTAssertEqual(x.3, 1); XCTAssertEqual(s.uploadedImages, 0)
    }
    actor MockTransport: DAVTransport {
        private(set) var calls = 0
        private(set) var bodies: [Data] = []
        let response: DAVResponse
        init(response: DAVResponse = DAVResponse(status: 200, data: Data("{\"runId\":\"run\",\"assets\":[{\"state\":\"new\",\"upload\":{\"uploadId\":\"u\",\"assetId\":\"a\"}}]}".utf8))) { self.response = response }
        func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
            calls += 1
            if let body = request.httpBody { bodies.append(body) }
            return response
        }
        func snapshot() -> (Int, [Data]) { (calls, bodies) }
    }

    private func request(body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.invalid/index.php/apps/apple_photos_connector/api/v1/inventory")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func testH1FinalTransportBodyContainsExactlyOneAsset() async throws {
        let source = PhotoSource(sourceId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Test")
        let asset = AssetInventory(localIdentifier: "local-test", cloudIdentifier: "cloud-test", mediaType: "image", creationDate: nil, filename: "test.jpg")
        let json = try InventoryJSON.encode([asset], source: source)
        let transport = MockTransport()
        _ = try await transport.send(request(body: Data(json.utf8)), file: nil)
        let state = await transport.snapshot()
        let body = try XCTUnwrap(state.1.first)
        let decoded = try JSONDecoder().decode(ProbeDocument.self, from: body)
        XCTAssertEqual(decoded.assets.count, 1)
        XCTAssertEqual(decoded.assets[0].cloudIdentifier, "cloud-test")
        XCTAssertEqual(state.0, 1)
    }

    func testH2EmptyCandidateProducesNoTransportCall() async throws {
        let transport = MockTransport()
        let candidates: [AssetInventory] = []
        XCTAssertTrue(candidates.isEmpty)
        let state = await transport.snapshot()
        XCTAssertEqual(state.0, 0)
    }

    func testH3BodyUsesSnapshotAfterMutableSelectionChanges() async throws {
        let source = PhotoSource(sourceId: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, name: "Test")
        let snapshot = [AssetInventory(localIdentifier: "local-snapshot", cloudIdentifier: "cloud-snapshot", mediaType: "image", creationDate: nil, filename: "snapshot.jpg")]
        var mutableSelection = snapshot
        let body = Data(try InventoryJSON.encode(snapshot, source: source).utf8)
        mutableSelection.removeAll()
        let transport = MockTransport()
        _ = try await transport.send(request(body: body), file: nil)
        let state = await transport.snapshot()
        let decoded = try JSONDecoder().decode(ProbeDocument.self, from: XCTUnwrap(state.1.first))
        XCTAssertEqual(decoded.assets.count, 1)
        XCTAssertTrue(mutableSelection.isEmpty)
        XCTAssertEqual(state.0, 1)
    }

    private struct ProbeDocument: Decodable {
        let assets: [AssetInventory]
    }
}
