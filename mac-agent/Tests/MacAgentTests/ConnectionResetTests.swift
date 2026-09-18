import XCTest
@testable import InventoryCore
@testable import MacAgentSupport

private final class ResetPasswordStore: PasswordStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var failDeletion = false
    var deleted: [String] = []
    func load(account: String) throws -> String? { values[account] }
    func save(password: String, account: String) throws { values[account] = password }
    func update(password: String, account: String) throws { values[account] = password }
    func delete(account: String) throws {
        if failDeletion { throw KeychainError(-1) }
        deleted.append(account); values.removeValue(forKey: account)
    }
}

@MainActor
final class ConnectionResetTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "reset-tests-" + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
    private let credentials = LoginFlowCredentials(server: URL(string: "https://a.example")!, loginName: "same", appPassword: "a-secret")

    func testResetClearsActiveAndDraftStateAndDisablesReset() throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore(); let session = ConnectionSession()
        XCTAssertFalse(session.hasResettableState(defaults: defaults))
        session.server = "https://draft.example"
        XCTAssertFalse(session.hasResettableState(defaults: defaults))
        try session.accept(credentials, attempt: session.attemptID, defaults: defaults, store: store)
        XCTAssertTrue(session.hasResettableState(defaults: defaults))
        session.server = "https://draft.example"; session.password = "draft"
        try session.resetConnection(defaults: defaults, store: store)
        XCTAssertEqual(session.server, ""); XCTAssertEqual(session.user, ""); XCTAssertEqual(session.password, "")
        XCTAssertFalse(session.validationSucceeded)
        XCTAssertNil(defaults.string(forKey: "nextcloud.server")); XCTAssertNil(defaults.string(forKey: "nextcloud.user"))
        XCTAssertFalse(defaults.bool(forKey: ImportGuard.validatedKey))
        XCTAssertFalse(defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey))
        XCTAssertFalse(session.hasResettableState(defaults: defaults))
    }

    func testDeletesOnlyPersistedIdentityAndPreservesOtherCredentials() throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore(); let session = ConnectionSession()
        try session.accept(credentials, attempt: session.attemptID, defaults: defaults, store: store)
        let otherServer = ConnectionPreferences(server: "https://b.example", user: "same", store: store)
        let otherUser = ConnectionPreferences(server: "https://a.example", user: "other", store: store)
        try otherServer.savePassword("b"); try otherUser.savePassword("other")
        store.values["unowned-legacy"] = "legacy"
        session.server = "https://b.example"
        try session.resetConnection(defaults: defaults, store: store)
        XCTAssertNil(try ConnectionPreferences(server: credentials.server.absoluteString, user: credentials.loginName, store: store).loadPassword())
        XCTAssertEqual(try otherServer.loadPassword(), "b"); XCTAssertEqual(try otherUser.loadPassword(), "other")
        XCTAssertEqual(store.values["unowned-legacy"], "legacy"); XCTAssertEqual(store.deleted.count, 1)
    }

    func testLateBrowserAndValidationSuccessCannotRestoreResetConnection() async throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore(); let session = ConnectionSession()
        let attempt = session.attemptID
        session.server = credentials.server.absoluteString; session.loginFlowRunning = true
        // Simulate an uncooperative transport completing after reset, regardless of cancellation.
        var reply: CheckedContinuation<Void, Never>!
        let task = Task { @MainActor in
            await withCheckedContinuation { reply = $0 }
            return try session.accept(credentials, attempt: attempt, defaults: defaults, store: store)
        }
        while reply == nil { await Task.yield() }
        try session.resetConnection(defaults: defaults, store: store)
        reply.resume()
        let accepted = try await task.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(try session.accept(credentials, attempt: attempt, defaults: defaults, store: store))
        XCTAssertTrue(store.values.isEmpty); XCTAssertEqual(session.server, "")
        XCTAssertFalse(session.loginFlowRunning); XCTAssertFalse(session.validationSucceeded)
    }

    func testResetCancelsBothTasksAndRetiresGeneration() async throws {
        let session = ConnectionSession(); let old = session.attemptID
        let login = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let validation = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        session.loginFlowTask = login; session.validationTask = validation
        try session.resetConnection(defaults: isolatedDefaults(), store: ResetPasswordStore())
        XCTAssertTrue(login.isCancelled); XCTAssertTrue(validation.isCancelled)
        XCTAssertNil(session.loginFlowTask); XCTAssertNil(session.validationTask)
        XCTAssertNotEqual(session.attemptID, old)
        await login.value; await validation.value
    }

    func testFailedDeletionPreservesSavedConnectionButRetiresAttempt() throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore(); let session = ConnectionSession()
        try session.accept(credentials, attempt: session.attemptID, defaults: defaults, store: store)
        let attempt = session.attemptID; store.failDeletion = true
        XCTAssertThrowsError(try session.resetConnection(defaults: defaults, store: store))
        XCTAssertEqual(session.server, credentials.server.absoluteString); XCTAssertTrue(session.validationSucceeded)
        XCTAssertEqual(defaults.string(forKey: "nextcloud.server"), credentials.server.absoluteString)
        XCTAssertTrue(defaults.bool(forKey: ImportGuard.validatedKey)); XCTAssertNotEqual(session.attemptID, attempt)
    }

    func testResetPreventsClientReconstructionAndProgrammaticClearingDoesNotSave() async throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore(); let session = ConnectionSession()
        try session.accept(credentials, attempt: session.attemptID, defaults: defaults, store: store)
        try session.resetConnection(defaults: defaults, store: store)
        await Task.yield() // No deferred binding/observer callback in the state model.
        XCTAssertThrowsError(try ConnectorConnection(server: session.server, user: session.user, password: session.password))
        XCTAssertTrue(store.values.isEmpty); XCTAssertNil(defaults.string(forKey: "nextcloud.server"))
        XCTAssertFalse(session.validationSucceeded)
    }

    func testResetIsLocalOnlyAndPreservesNonAuthenticationPreferences() throws {
        let defaults = isolatedDefaults(); let store = ResetPasswordStore()
        defaults.set("Photos/Keep", forKey: TargetDirectoryPreferences.key)
        defaults.set(true, forKey: UploadPreferences.debugModeKey)
        try ValidatedConnectionPersistence.commit(credentials, defaults: defaults, store: store)
        // The reset API has no network dependency and uses only this fake Keychain and defaults.
        try ValidatedConnectionPersistence.resetConnection(defaults: defaults, store: store)
        XCTAssertEqual(defaults.string(forKey: TargetDirectoryPreferences.key), "Photos/Keep")
        XCTAssertTrue(defaults.bool(forKey: UploadPreferences.debugModeKey))
    }
}
