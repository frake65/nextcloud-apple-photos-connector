import Foundation
import InventoryCore

/// Called only after validation, on the main actor, without suspension between
/// Keychain and settings writes. A failed Keychain write leaves settings intact.
public enum ValidatedConnectionPersistence {
    @MainActor
    public static func commit(_ credentials: LoginFlowCredentials,
                              defaults: UserDefaults = ConnectionPreferences.defaults(),
                              store: any PasswordStore = KeychainPasswordStore()) throws {
        _ = try ConnectorConnection(server: credentials.server.absoluteString, user: credentials.loginName, password: credentials.appPassword)
        try ConnectionPreferences(server: credentials.server.absoluteString, user: credentials.loginName, store: store).savePassword(credentials.appPassword)
        defaults.set(false, forKey: ImportGuard.validatedKey)
        defaults.set(credentials.server.absoluteString, forKey: "nextcloud.server")
        defaults.set(credentials.loginName, forKey: "nextcloud.user")
        defaults.set(false, forKey: TargetDirectoryPreferences.confirmedKey)
        defaults.set(true, forKey: ImportGuard.validatedKey)
    }
    /// Local-only: no transport is accepted or constructed by this operation.
    @MainActor
    public static func resetConnection(defaults: UserDefaults = ConnectionPreferences.defaults(),
                                       store: any PasswordStore = KeychainPasswordStore()) throws {
        let server = defaults.string(forKey: "nextcloud.server") ?? ""
        let user = defaults.string(forKey: "nextcloud.user") ?? ""
        if !server.isEmpty && !user.isEmpty {
            try ConnectionPreferences(server: server, user: user, store: store).deletePassword()
        }
        // Legacy entries are migrated and removed before Settings is loaded.
        // An unscoped leftover has no provable ownership; do not delete it here.
        defaults.set(false, forKey: ImportGuard.validatedKey)
        defaults.set(false, forKey: TargetDirectoryPreferences.confirmedKey)
        defaults.removeObject(forKey: "nextcloud.server")
        defaults.removeObject(forKey: "nextcloud.user")
    }
}
