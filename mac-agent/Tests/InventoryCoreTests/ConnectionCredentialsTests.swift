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
