import Foundation
#if canImport(Security)
import Security
#endif

public protocol PasswordStore: Sendable {
    func save(password: String, account: String) throws
    func load(account: String) throws -> String?
    func update(password: String, account: String) throws
    func delete(account: String) throws
}

public final class KeychainPasswordStore: PasswordStore, @unchecked Sendable {
    public static let service = "ApplePhotosConnector.Nextcloud"
    public init() {}
    public func save(password: String, account: String) throws { try update(password: password, account: account) }
    public func load(account: String) throws -> String? {
        #if canImport(Security)
        var q = base(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw KeychainError(status) }
        return String(data: item as! Data, encoding: .utf8)
        #else
        return nil
        #endif
    }
    public func update(password: String, account: String) throws {
        #if canImport(Security)
        let data = Data(password.utf8); let q = base(account); let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound { var add=q; add[kSecValueData as String]=data; let addStatus=SecItemAdd(add as CFDictionary,nil); if addStatus != errSecSuccess { throw KeychainError(addStatus) } }
        else if status != errSecSuccess { throw KeychainError(status) }
        #endif
    }
    public func delete(account: String) throws {
        #if canImport(Security)
        let status=SecItemDelete(base(account) as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status) }
        #endif
    }
    #if canImport(Security)
    private func base(_ account:String)->[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:account]}
    #endif
}
public struct KeychainError: Error, Sendable { public let status: Int32; public init(_ status: Int32){self.status=status} }

public struct ConnectionPreferences: Sendable {
    public static let preferencesSuite = "de.applephotosconnector.macagent"
    private static let migratedKeys = [
        "nextcloud.server", "nextcloud.user", "nextcloud.targetDirectory",
        "nextcloud.targetValidated", "nextcloud.connectionValidated",
        "nextcloud.debugMode", "photos.language"
    ]
    /// The bundle identifier is not an app-group suite. Use the standard
    /// defaults domain and import values written by older builds once.
    public static func defaults() -> UserDefaults {
        let standard = UserDefaults.standard
        let legacy = standard.persistentDomain(forName: preferencesSuite) ?? [:]
        for key in migratedKeys where standard.object(forKey: key) == nil {
            if let value = legacy[key] { standard.set(value, forKey: key) }
        }
        return standard
    }
    public var server: String; public var user: String
    private let store: any PasswordStore
    public init(server: String = "", user: String = "", store: any PasswordStore = KeychainPasswordStore()) { self.server=server; self.user=user; self.store=store }
    // Include the installation path: two Nextcloud installations may share a host.
    private var account: String {
        let normalized = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "v2:" + Data(normalized.utf8).base64EncodedString() + ":" + Data(user.utf8).base64EncodedString()
    }
    public func loadPassword() throws -> String? { try store.load(account: account) }
    /// Migrate only the persisted installation, before presenting editable drafts.
    public static func migrateLegacyPassword(defaults: UserDefaults, store: any PasswordStore = KeychainPasswordStore()) throws {
        guard let server = defaults.string(forKey: "nextcloud.server"), !server.isEmpty,
              let user = defaults.string(forKey: "nextcloud.user"), !user.isEmpty else { return }
        let preferences = Self(server: server, user: user, store: store)
        if try preferences.loadPassword() == nil, let legacy = try store.load(account: user) {
            try preferences.savePassword(legacy)
        }
        try store.delete(account: user)
    }
    public func savePassword(_ password: String) throws { try store.update(password: password, account: account) }
    public func deletePassword() throws { try store.delete(account: account) }
}
