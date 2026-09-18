import Foundation

/// Admission barrier for library work. Already admitted steps finish normally.
/// A resumed waiter rechecks the state, so close/open cannot release stale work.
/// All mutable state is protected by the lock; no lock is held across an await.
public final class SettingsWorkGate: @unchecked Sendable {
    public static let shared = SettingsWorkGate()
    private let lock = NSLock()
    private var paused = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }
    var waitingCount: Int { lock.withLock { waiters.count } }

    public func setPaused(_ value: Bool) {
        let ready = lock.withLock {
            paused = value
            guard !value else { return [CheckedContinuation<Void, Never>]() }
            let ready = Array(waiters.values)
            waiters.removeAll()
            return ready
        }
        ready.forEach { $0.resume() }
    }

    /// Returning admits one step; it does not reserve permission for later steps.
    /// Keep the caller's actor so admission does not itself add an executor hop.
    public func checkpoint(isolation: isolated (any Actor)? = #isolation) async throws {
        while true {
            try Task.checkCancellation()
            if lock.withLock({ !paused }) { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let registered = lock.withLock {
                        guard paused, !Task.isCancelled else { return false }
                        waiters[id] = continuation
                        return true
                    }
                    if !registered { continuation.resume() }
                }
            } onCancel: {
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiter?.resume()
            }
        }
    }
}

/// One active operation and at most one pending refresh, including while paused.
@MainActor
public final class CoalescingWorkRequest {
    private let gate: SettingsWorkGate
    private var worker: Task<Void, Never>?
    private var pending = false
    public var isRunning: Bool { worker != nil }

    public init(gate: SettingsWorkGate = .shared) { self.gate = gate }

    public func request(_ operation: @escaping @MainActor () async -> Void) {
        enqueue(preflight: nil, operation: operation)
    }

    /// Runs a lightweight prerequisite before waiting for Settings to close,
    /// then performs the operation under the same admission gate.
    public func request(preflight: @escaping @MainActor () async -> Bool,
                        operation: @escaping @MainActor () async -> Void) {
        enqueue(preflight: preflight, operation: operation)
    }

    private func enqueue(preflight: (@MainActor () async -> Bool)?,
                         operation: @escaping @MainActor () async -> Void) {
        pending = true
        guard worker == nil else { return }
        worker = Task { [self] in
            defer { worker = nil }
            while pending {
                if let preflight, !(await preflight()) {
                    pending = false
                    return
                }
                do { try await gate.checkpoint() } catch { pending = false; return }
                pending = false
                await operation()
            }
        }
    }
}
