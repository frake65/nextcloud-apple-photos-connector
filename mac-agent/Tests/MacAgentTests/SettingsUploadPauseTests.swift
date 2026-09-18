import Foundation
import XCTest
@testable import InventoryCore
@testable import MacAgent
@testable import MacAgentSupport

@MainActor
final class SettingsUploadPauseTests: XCTestCase {
    actor Exporter: PhotoOriginalExporting {
        private var pending: [String: CheckedContinuation<Void, Never>] = [:]
        private(set) var starts: [String] = []
        private(set) var maximumActive = 0
        let writesFiles: Bool
        init(writesFiles: Bool = false) { self.writesFiles = writesFiles }
        func export(localIdentifier: String) async throws -> PhotoOriginalExporter.Export {
            starts.append(localIdentifier)
            await withCheckedContinuation {
                pending[localIdentifier] = $0
                maximumActive = max(maximumActive, pending.count)
            }
            guard writesFiles else { throw UploadError.invalidResponse }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let url = directory.appendingPathComponent("original")
            try Data("test".utf8).write(to: url)
            return .init(url: url, filename: "test.jpg")
        }
        func releaseAll() {
            let values = Array(pending.values)
            pending.removeAll()
            values.forEach { $0.resume() }
        }
        func count() -> Int { starts.count }
    }

    actor Transport: DAVTransport {
        let count: Int
        let known: Bool
        private(set) var inventories = 0
        private(set) var completions = 0
        private(set) var folders: [String] = []
        private(set) var hosts: [String] = []
        private(set) var legacyFieldPresent: [Bool] = []
        init(count: Int, known: Bool = false) { self.count = count; self.known = known }
        func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
            hosts.append(request.url!.host!)
            let path = request.url!.path
            if path.hasSuffix("/inventory") {
                inventories += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                legacyFieldPresent.append(body["retransferMissing"] != nil)
                let entries: [[String: Any]] = (0..<count).map {
                    known ? ["state": "known"] : ["state": "new", "upload": ["uploadId": "u\($0)", "assetId": "\($0 + 1)"]]
                }
                return DAVResponse(status: 200, data: try JSONSerialization.data(withJSONObject: ["runId": "run", "assets": entries]))
            }
            if path.hasSuffix("/uploads/prepare") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                folders.append(body["folder"] as! String)
                // Fail before PUT/receipts: this test only verifies configuration.
                return DAVResponse(status: 500)
            }
            if path.hasSuffix("/uploads/complete") { completions += 1; return DAVResponse(status: 200) }
            return DAVResponse(status: 201)
        }
        func completed() -> Int { completions }
        func inventoryCount() -> Int { inventories }
        func folderCount() -> Int { folders.count }
    }

    private func json(_ count: Int) throws -> String {
        let source = PhotoSource(sourceId: UUID(), name: "Pause test")
        return try InventoryJSON.encode((0..<count).map {
            AssetInventory(localIdentifier: "local\($0)", mediaType: "image", creationDate: Date(timeIntervalSince1970: 0), filename: "test.jpg")
        }, source: source)
    }
    private func connection(_ host: String = "old.invalid") throws -> ConnectorConnection {
        try ConnectorConnection(server: "https://\(host)", user: "test", password: "test")
    }
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testProductionQueueDrainsWithoutRefillingThenResumesAtThree() async throws {
        let gate = SettingsWorkGate()
        let exporter = Exporter()
        let transport = Transport(count: 7)
        let coordinator = UploadCoordinator(exporter: exporter, transport: transport, gate: gate)
        let payload = try json(7), connection = try connection()
        let task = Task { try await coordinator.run(json: payload, connection: connection) }
        await eventually { await exporter.count() == 3 }
        gate.setPaused(true)
        await exporter.releaseAll()
        await eventually { await transport.completed() == 3 }
        await eventually { gate.waitingCount == 1 }
        let pausedCount = await exporter.count()
        XCTAssertEqual(pausedCount, 3)
        gate.setPaused(false)
        await eventually { await exporter.count() == 6 }
        await exporter.releaseAll()
        await eventually { await exporter.count() == 7 }
        await exporter.releaseAll()
        _ = try await task.value
        let starts = await exporter.starts
        let maximum = await exporter.maximumActive
        let completed = await transport.completed()
        XCTAssertEqual(Set(starts).count, 7)
        XCTAssertEqual(starts.count, 7)
        XCTAssertEqual(maximum, 3)
        XCTAssertEqual(completed, 7)
    }

    func testPausedUploadDoesNotStartAndRejectsDuplicateRun() async throws {
        let gate = SettingsWorkGate()
        gate.setPaused(true)
        let transport = Transport(count: 1, known: true)
        let coordinator = UploadCoordinator(exporter: Exporter(), transport: transport, gate: gate)
        let payload = try json(1), connection = try connection()
        let task = Task { try await coordinator.run(json: payload, connection: connection) }
        await eventually { gate.waitingCount == 1 }
        let count = await transport.inventoryCount()
        XCTAssertEqual(count, 0)
        do {
            _ = try await coordinator.run(json: payload, connection: connection)
            XCTFail("Duplicate run must be rejected")
        } catch UploadCoordinator.RunError.alreadyRunning { }
        gate.setPaused(false)
        _ = try await task.value
        // Completion releases the run-in-progress guard.
        _ = try await coordinator.run(json: payload, connection: connection)
        let finalCount = await transport.inventoryCount()
        XCTAssertEqual(finalCount, 2)
    }

    func testCancelledPendingUploadReleasesRunGuardWithoutStartingWork() async throws {
        let gate = SettingsWorkGate()
        gate.setPaused(true)
        let transport = Transport(count: 1, known: true)
        let coordinator = UploadCoordinator(exporter: Exporter(), transport: transport, gate: gate)
        let payload = try json(1), connection = try connection()
        let task = Task { try await coordinator.run(json: payload, connection: connection) }
        await eventually { gate.waitingCount == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.inventoryCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(gate.waitingCount, 0)
        gate.setPaused(false)
        _ = try await coordinator.run(json: payload, connection: connection)
        let resumedCount = await transport.inventoryCount()
        XCTAssertEqual(resumedCount, 1)
    }

    func testUploadSnapshotSurvivesSettingsChangesAndPauseBetweenExportAndUpload() async throws {
        let gate = SettingsWorkGate()
        let exporter = Exporter(writesFiles: true)
        let transport = Transport(count: 4)
        let coordinator = UploadCoordinator(exporter: exporter, transport: transport, gate: gate)
        let payload = try json(4)
        var currentConnection = try connection()
        var currentRoot = "Original"
        let task = Task { [currentConnection, currentRoot] in
            try await coordinator.run(json: payload, connection: currentConnection, targetRoot: currentRoot)
        }
        await eventually { await exporter.count() == 3 }
        gate.setPaused(true)
        currentConnection = try connection("new.invalid")
        currentRoot = "Changed"
        await exporter.releaseAll()
        await eventually { gate.waitingCount == 3 }
        let beforeResume = await transport.folderCount()
        XCTAssertEqual(beforeResume, 0)
        gate.setPaused(false)
        await eventually { await exporter.count() == 4 }
        await exporter.releaseAll()
        _ = try await task.value
        let folders = await transport.folders
        let hosts = await transport.hosts
        let flags = await transport.legacyFieldPresent
        XCTAssertEqual(folders.count, 4)
        XCTAssertTrue(folders.allSatisfy { $0.hasPrefix("Original/") })
        XCTAssertEqual(Set(hosts), ["old.invalid"])
        XCTAssertEqual(flags, [false])
        // Changed settings are inputs only to the next run.
        let next = Task { [currentConnection, currentRoot] in
            try await coordinator.run(json: payload, connection: currentConnection, targetRoot: currentRoot)
        }
        await eventually { await exporter.count() == 7 }
        await exporter.releaseAll()
        await eventually { await exporter.count() == 8 }
        await exporter.releaseAll()
        _ = try await next.value
        let updatedFolders = await transport.folders
        let updatedFlags = await transport.legacyFieldPresent
        XCTAssertTrue(updatedFolders.suffix(4).allSatisfy { $0.hasPrefix("Changed/") })
        XCTAssertEqual(updatedFlags, [false, false])
    }
}
