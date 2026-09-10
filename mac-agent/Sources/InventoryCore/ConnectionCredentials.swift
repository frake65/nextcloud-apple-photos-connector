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
    public var server: String; public var user: String
    private let store: any PasswordStore
    public init(server: String = "", user: String = "", store: any PasswordStore = KeychainPasswordStore()) { self.server=server; self.user=user; self.store=store }
    public func loadPassword() throws -> String? { try store.load(account: user) }
    public func savePassword(_ password: String) throws { try store.update(password: password, account: user) }
    public func deletePassword() throws { try store.delete(account: user) }
}
