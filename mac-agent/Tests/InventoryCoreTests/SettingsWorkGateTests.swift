import XCTest
@testable import InventoryCore

@MainActor
final class SettingsWorkGateTests: XCTestCase {
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testClosedSettingsAllowRun() async {
        let request = CoalescingWorkRequest(gate: SettingsWorkGate())
        var count = 0
        request.request { count += 1 }
        await eventually { !request.isRunning }
        XCTAssertEqual(count, 1)
    }

    func testOpenSettingsHoldAndCoalesceRepeatedRequests() async {
        let gate = SettingsWorkGate()
        let request = CoalescingWorkRequest(gate: gate)
        gate.setPaused(true)
        var count = 0
        for _ in 0..<20 { request.request { count += 1 } }
        await eventually { gate.waitingCount == 1 }
        XCTAssertEqual(count, 0)
        gate.setPaused(false)
        await eventually { !request.isRunning }
        XCTAssertEqual(count, 1)
        // Closing again without pending work must not manufacture a refresh.
        gate.setPaused(true)
        gate.setPaused(false)
        await Task.yield()
        XCTAssertEqual(count, 1)
    }

    func testCloseThenReopenBeforeWaiterRunsKeepsWorkPaused() async {
        let gate = SettingsWorkGate()
        let request = CoalescingWorkRequest(gate: gate)
        gate.setPaused(true)
        var count = 0
        request.request { count += 1 }
        await eventually { gate.waitingCount == 1 }
        gate.setPaused(false)
        gate.setPaused(true)
        await eventually { gate.waitingCount == 1 }
        XCTAssertEqual(count, 0)
        gate.setPaused(false)
        await eventually { !request.isRunning }
        XCTAssertEqual(count, 1)
    }

    func testActiveRunFinishesAndOnlyOneFollowupWaitsForResume() async {
        let gate = SettingsWorkGate()
        let request = CoalescingWorkRequest(gate: gate)
        var count = 0
        var finish: CheckedContinuation<Void, Never>?
        let operation: @MainActor () async -> Void = {
            count += 1
            if count == 1 { await withCheckedContinuation { finish = $0 } }
        }
        request.request(operation)
        await eventually { finish != nil }
        gate.setPaused(true)
        for _ in 0..<20 { request.request(operation) }
        XCTAssertEqual(count, 1)
        finish?.resume()
        await eventually { gate.waitingCount == 1 }
        XCTAssertEqual(count, 1)
        gate.setPaused(false)
        await eventually { !request.isRunning }
        XCTAssertEqual(count, 2)
    }

    func testCancellingPausedWaiterDoesNotRequireClosingSettings() async {
        let gate = SettingsWorkGate()
        gate.setPaused(true)
        let task = Task { try await gate.checkpoint() }
        await eventually { gate.waitingCount == 1 }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.waitingCount, 0)
        XCTAssertTrue(gate.isPaused)
    }
}
