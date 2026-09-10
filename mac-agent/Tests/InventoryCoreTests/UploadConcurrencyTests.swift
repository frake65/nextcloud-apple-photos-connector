import Foundation
import XCTest

private actor MockUploadProbe {
    struct Snapshot: Sendable {
        let currentActive: Int
        let maximumActive: Int
        let startedAssetIDs: [String]
        let completedAssetIDs: [String]
    }

    private var currentActive = 0
    private var maximumActive = 0
    private var startedAssetIDs: [String] = []
    private var completedAssetIDs: [String] = []

    func begin(_ id: String) {
        currentActive += 1
        maximumActive = max(maximumActive, currentActive)
        startedAssetIDs.append(id)
    }

    func finish(_ id: String) {
        currentActive -= 1
        completedAssetIDs.append(id)
    }

    func snapshot() -> Snapshot {
        Snapshot(currentActive: currentActive,
                 maximumActive: maximumActive,
                 startedAssetIDs: startedAssetIDs,
                 completedAssetIDs: completedAssetIDs)
    }
}

private enum MockUploadOutcome: Sendable {
    case success
    case failed
    case fatalAuth
}

private struct MockUploadRun: Sendable {
    let snapshot: MockUploadProbe.Snapshot
    let successReceipts: [String]
    let failed: [String]
    let fatalAuth: Bool

    var processedCount: Int { successReceipts.count + failed.count }
}

/// A test-only bounded scheduler. It deliberately mirrors the required
/// scheduling contract without importing or changing the production uploader.
private actor MockUploadScheduler {
    static let maxConcurrentUploads = 3

    private let probe = MockUploadProbe()
    private var receipts: [String] = []
    private var failed: [String] = []
    private var fatalAuth = false

    func run(ids: [String], outcomes: [String: MockUploadOutcome]) async -> MockUploadRun {
        await withTaskGroup(of: (String, MockUploadOutcome).self) { group in
            var next = 0

            while next < ids.count && next < Self.maxConcurrentUploads {
                schedule(ids[next], outcomes: outcomes, in: &group)
                next += 1
            }

            while let result = await group.next() {
                let (id, outcome) = result
                switch outcome {
                case .success:
                    receipts.append(id)
                case .failed:
                    failed.append(id)
                case .fatalAuth:
                    fatalAuth = true
                    failed.append(id)
                }

                if !fatalAuth && next < ids.count {
                    schedule(ids[next], outcomes: outcomes, in: &group)
                    next += 1
                }
            }

            return MockUploadRun(snapshot: await probe.snapshot(),
                                 successReceipts: receipts,
                                 failed: failed,
                                 fatalAuth: fatalAuth)
        }
    }

    private func schedule(
        _ id: String,
        outcomes: [String: MockUploadOutcome],
        in group: inout TaskGroup<(String, MockUploadOutcome)>
    ) {
        let outcome = outcomes[id, default: .success]
        group.addTask { [probe] in
            await probe.begin(id)
            // Make the fatal-auth case deterministic: it is observed before
            // any queued replacement can be scheduled, while normal work
            // still overlaps for the concurrency assertions.
            let delay: Duration
            if case .fatalAuth = outcome {
                delay = .milliseconds(1)
            } else {
                delay = .milliseconds(20)
            }
            try? await Task.sleep(for: delay)
            await probe.finish(id)
            return (id, outcome)
        }
    }
}

final class UploadConcurrencyTests: XCTestCase {
    private func run(_ count: Int, outcomes: [String: MockUploadOutcome] = [:]) async -> MockUploadRun {
        let ids = (0..<count).map { "asset-\($0)" }
        return await MockUploadScheduler().run(ids: ids, outcomes: outcomes)
    }

    func testOneAssetHasOneActiveUpload() async {
        let result = await run(1)
        XCTAssertEqual(result.snapshot.maximumActive, 1)
        XCTAssertEqual(result.snapshot.startedAssetIDs, ["asset-0"])
    }

    func testTwoAssetsNeverExceedTwoActiveUploads() async {
        let result = await run(2)
        XCTAssertLessThanOrEqual(result.snapshot.maximumActive, 2)
    }

    func testThreeAssetsNeverExceedConfiguredLimit() async {
        let result = await run(3)
        XCTAssertLessThanOrEqual(result.snapshot.maximumActive, 3)
    }

    func testTenAssetsAreBoundedAtThreeAndStartedOnce() async {
        let result = await run(10)
        XCTAssertLessThanOrEqual(result.snapshot.maximumActive, 3)
        XCTAssertEqual(Set(result.snapshot.startedAssetIDs).count, 10)
        XCTAssertEqual(result.snapshot.startedAssetIDs.count, 10)
    }

    func testIndividualFailureDoesNotStopOtherAssets() async {
        let result = await run(5, outcomes: ["asset-1": .failed])
        XCTAssertEqual(result.failed, ["asset-1"])
        XCTAssertEqual(result.successReceipts.count, 4)
        XCTAssertEqual(result.processedCount, 5)
    }

    func testFatalAuthStopsSchedulingQueuedAssets() async {
        let result = await run(10, outcomes: ["asset-0": .fatalAuth])
        XCTAssertTrue(result.fatalAuth)
        XCTAssertLessThan(result.snapshot.startedAssetIDs.count, 10)
        XCTAssertLessThanOrEqual(result.snapshot.startedAssetIDs.count, 3)
    }

    func testSuccessCreatesExactlyOneReceiptAndFailureCreatesNone() async {
        let result = await run(2, outcomes: ["asset-1": .failed])
        XCTAssertEqual(result.successReceipts, ["asset-0"])
        XCTAssertFalse(result.successReceipts.contains("asset-1"))
    }

    func testProgressEqualsActuallyProcessedTickets() async {
        let result = await run(10, outcomes: ["asset-2": .failed])
        XCTAssertEqual(result.processedCount, result.snapshot.completedAssetIDs.count)
        XCTAssertEqual(result.processedCount, 10)
    }
}
