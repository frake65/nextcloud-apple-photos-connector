import XCTest
@testable import InventoryCore

private final class FakePasswordStore: PasswordStore, @unchecked Sendable {
    var values: [String:String] = [:]
    func save(password: String, account: String) throws { values[account]=password }
    func load(account: String) throws -> String? { values[account] }
    func update(password: String, account: String) throws { values[account]=password }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

private final class CountingPasswordStore: PasswordStore, @unchecked Sendable {
    var reads = 0; var writes = 0; var deletes = 0
    func save(password: String, account: String) throws { writes += 1 }
    func load(account: String) throws -> String? { reads += 1; return nil }
    func update(password: String, account: String) throws { writes += 1 }
    func delete(account: String) throws { deletes += 1 }
}

final class ConnectionCredentialsTests: XCTestCase {
    func testURLAndUserRoundTripAndPasswordOperations() throws {
        let store=FakePasswordStore(); let prefs=ConnectionPreferences(server:"https://cloud.example",user:"admin",store:store)
        XCTAssertEqual(prefs.server,"https://cloud.example"); XCTAssertEqual(prefs.user,"admin")
        try prefs.savePassword("dummy-secret"); XCTAssertEqual(try prefs.loadPassword(),"dummy-secret")
        try prefs.savePassword("updated-dummy"); XCTAssertEqual(try prefs.loadPassword(),"updated-dummy")
        try prefs.deletePassword(); XCTAssertNil(try prefs.loadPassword())
    }
    func testMissingKeychainEntryIsNil() throws { XCTAssertNil(try ConnectionPreferences(user:"missing",store:FakePasswordStore()).loadPassword()) }
    func testCreatingAndEditingConnectionPreferencesDoesNotAccessKeychain() {
        let store = CountingPasswordStore()
        _ = ConnectionPreferences(server: "https://cloud.example", user: "f", store: store)
        _ = ConnectionPreferences(server: "https://cloud.example", user: "fr", store: store)
        _ = ConnectionPreferences(server: "https://cloud.example", user: "fra", store: store)
        XCTAssertEqual(store.reads, 0); XCTAssertEqual(store.writes, 0); XCTAssertEqual(store.deletes, 0)
    }
}

extension ConnectionCredentialsTests {
    func testSameUsernameOnDifferentServersNeverSharesPassword() throws {
        let store = FakePasswordStore()
        let a = ConnectionPreferences(server: "https://a.example", user: "same", store: store)
        let b = ConnectionPreferences(server: "https://b.example", user: "same", store: store)
        try a.savePassword("old")
        XCTAssertNil(try b.loadPassword())
        try b.savePassword("new")
        XCTAssertEqual(try a.loadPassword(), "old")
        XCTAssertEqual(try b.loadPassword(), "new")
    }

    @MainActor
    func testBrowserCredentialsReplaceEntireConnectionAndPublishValidation() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = FakePasswordStore()
        for host in ["a.example", "b.example"] {
            let credentials = LoginFlowCredentials(server: URL(string: "https://" + host)!, loginName: host, appPassword: host)
            try ValidatedConnectionPersistence.commit(credentials, defaults: defaults, store: store)
            XCTAssertEqual(defaults.string(forKey: "nextcloud.server"), credentials.server.absoluteString)
            XCTAssertEqual(defaults.string(forKey: "nextcloud.user"), credentials.loginName)
            XCTAssertTrue(defaults.bool(forKey: ImportGuard.validatedKey))
            XCTAssertFalse(defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey))
            XCTAssertEqual(try ConnectionPreferences(server: credentials.server.absoluteString, user: host, store: store).loadPassword(), host)
        }
    }

    @MainActor
    func testFailedKeychainCommitPreservesWorkingConnection() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = FakePasswordStore()
        let a = LoginFlowCredentials(server: URL(string: "https://a.example")!, loginName: "old", appPassword: "old")
        try ValidatedConnectionPersistence.commit(a, defaults: defaults, store: store)
        XCTAssertThrowsError(try ValidatedConnectionPersistence.commit(.init(server: URL(string: "https://b.example")!, loginName: "new", appPassword: "new"), defaults: defaults, store: FailingPasswordStore()))
        XCTAssertEqual(defaults.string(forKey: "nextcloud.server"), a.server.absoluteString)
        XCTAssertEqual(defaults.string(forKey: "nextcloud.user"), "old")
        XCTAssertTrue(defaults.bool(forKey: ImportGuard.validatedKey))
        XCTAssertEqual(try ConnectionPreferences(server: a.server.absoluteString, user: "old", store: store).loadPassword(), "old")
    }

    func testLegacyMigrationIsBoundToPersistedServer() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://a.example", forKey: "nextcloud.server")
        defaults.set("same", forKey: "nextcloud.user")
        let store = FakePasswordStore(); store.values["same"] = "legacy"
        try ConnectionPreferences.migrateLegacyPassword(defaults: defaults, store: store)
        XCTAssertNil(store.values["same"])
        XCTAssertEqual(try ConnectionPreferences(server: "https://a.example", user: "same", store: store).loadPassword(), "legacy")
        XCTAssertNil(try ConnectionPreferences(server: "https://b.example", user: "same", store: store).loadPassword())
    }
}

private struct FailingPasswordStore: PasswordStore {
    func save(password: String, account: String) throws { throw KeychainError(-1) }
    func update(password: String, account: String) throws { throw KeychainError(-1) }
    func load(account: String) throws -> String? { nil }
    func delete(account: String) throws { }
}
