import Foundation
import Observation

/// Main-actor connection drafts and async-result ownership shared by login,
/// validation and reset. Programmatic changes have no persistence observers.
@MainActor @Observable
public final class ConnectionSession {
    public var server = ""
    public var user = ""
    public var password = ""
    public var validationSucceeded = false
    public var loginFlowRunning = false
    public private(set) var attemptID = UUID()
    public var loginFlowTask: Task<Void, Never>?
    public var validationTask: Task<Void, Never>?

    public init() {}

    public func cancelAttempt() {
        attemptID = UUID()
        loginFlowTask?.cancel(); loginFlowTask = nil
        validationTask?.cancel(); validationTask = nil
        loginFlowRunning = false
    }

    public func hasResettableState(defaults: UserDefaults) -> Bool {
        loginFlowRunning || validationTask != nil || validationSucceeded
            || !(defaults.string(forKey: "nextcloud.server") ?? "").isEmpty
            || !(defaults.string(forKey: "nextcloud.user") ?? "").isEmpty
            || defaults.bool(forKey: ImportGuard.validatedKey)
    }

    @discardableResult
    public func accept(_ credentials: LoginFlowCredentials, attempt: UUID,
                       defaults: UserDefaults, store: any PasswordStore = KeychainPasswordStore()) throws -> Bool {
        guard attempt == attemptID, !Task.isCancelled else { return false }
        try ValidatedConnectionPersistence.commit(credentials, defaults: defaults, store: store)
        server = credentials.server.absoluteString; user = credentials.loginName; password = credentials.appPassword
        validationSucceeded = true
        return true
    }

    public func resetConnection(defaults: UserDefaults, store: any PasswordStore = KeychainPasswordStore()) throws {
        // Even a failed deletion must retire work that was already in flight.
        cancelAttempt()
        try ValidatedConnectionPersistence.resetConnection(defaults: defaults, store: store)
        server = ""; user = ""; password = ""; validationSucceeded = false
    }
}
