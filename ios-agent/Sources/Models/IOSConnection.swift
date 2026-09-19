import Foundation
import Security
import Combine
import InventoryCore

struct IOSConnectionDetails: Codable, Equatable {
    var server: String
    var username: String
    var sourceId: UUID
}

protocol IOSPasswordStore: Sendable {
    func save(_ password: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

final class IOSKeychainPasswordStore: IOSPasswordStore, @unchecked Sendable {
    private let service = "de.applephotosconnector.iosagent.nextcloud"

    func save(_ password: String, account: String) throws {
        let query = base(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw IOSKeychainError(status: status) }
        } else if update != errSecSuccess {
            throw IOSKeychainError(status: update)
        }
    }

    func load(account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw IOSKeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IOSKeychainError(status: status) }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

struct IOSKeychainError: Error, Sendable { let status: OSStatus }

@MainActor
final class IOSConnectionPreferences {
    private let defaults: UserDefaults
    private let passwordStore: any IOSPasswordStore
    private let key = "ios.connection.details.v1"

    init(defaults: UserDefaults = .standard, passwordStore: any IOSPasswordStore = IOSKeychainPasswordStore()) {
        self.defaults = defaults
        self.passwordStore = passwordStore
    }

    func load() -> (details: IOSConnectionDetails, password: String) {
        let details = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(IOSConnectionDetails.self, from: $0) }
            ?? IOSConnectionDetails(server: "", username: "", sourceId: UUID())
        let password: String
        do { password = try passwordStore.load(account: account(server: details.server, username: details.username)) ?? "" }
        catch { password = "" }
        return (details, password)
    }

    func save(server: String, username: String, password: String, sourceId: UUID) throws {
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        _ = try ConnectorConnection(server: normalizedServer, user: username, password: password)
        try passwordStore.save(password, account: account(server: normalizedServer, username: username))
        let details = IOSConnectionDetails(server: normalizedServer, username: username, sourceId: sourceId)
        defaults.set(try JSONEncoder().encode(details), forKey: key)
    }

    func deletePassword(server: String, username: String) throws {
        try passwordStore.delete(account: account(server: server, username: username))
    }

    private func account(server: String, username: String) -> String {
        "\(server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())|\(username)"
    }
}

enum IOSConnectionState: Equatable {
    case notConfigured, notTested, checking, connected, authenticationFailed, appMissing, networkError, serverUnavailable, invalidResponse

    var title: String {
        switch self {
        case .notConfigured: "Nicht konfiguriert"
        case .notTested: "Konfiguriert – noch nicht geprüft"
        case .checking: "Verbindung wird geprüft …"
        case .connected: "Verbunden mit APC"
        case .authenticationFailed: "Anmeldung fehlgeschlagen"
        case .appMissing: "APC-App oder Endpoint nicht verfügbar"
        case .networkError: "Server nicht erreichbar"
        case .serverUnavailable: "Nextcloud ist vorübergehend nicht verfügbar"
        case .invalidResponse: "Unerwartete Serverantwort"
        }
    }

    init(validation: ConnectionValidation.Result) {
        switch validation {
        case .success: self = .connected
        case .authenticationFailed: self = .authenticationFailed
        case .appMissing: self = .appMissing
        case .unavailable: self = .serverUnavailable
        case .unreachable, .tlsOrNetworkError: self = .networkError
        case .unexpectedResponse: self = .invalidResponse
        }
    }
}

@MainActor
final class IOSConnectionModel: ObservableObject {
    @Published var server: String
    @Published var username: String
    @Published var password: String
    @Published var sourceId: String
    @Published private(set) var state: IOSConnectionState = .notConfigured
    @Published var isShowingSaveError = false
    private let preferences: IOSConnectionPreferences

    init(preferences: IOSConnectionPreferences = IOSConnectionPreferences()) {
        self.preferences = preferences
        let saved = preferences.load()
        server = saved.details.server
        username = saved.details.username
        password = saved.password
        sourceId = saved.details.sourceId.uuidString.lowercased()
        state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested
    }

    var parsedSourceId: UUID? { UUID(uuidString: sourceId.trimmingCharacters(in: .whitespacesAndNewlines)) }

    func save() throws {
        guard let parsedSourceId else { throw UploadError.invalidConfiguration }
        try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId)
    }

    func saved() { state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested }
    func markEdited() { state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested }
    func showSaveError() { isShowingSaveError = true }

    func testConnection() async {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty, let parsedSourceId else { state = .notConfigured; return }
        state = .checking
        do {
            try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId)
            let connection = try ConnectorConnection(server: server, user: username, password: password)
            let validation = await NextcloudConnectionClient(connection: connection).validate()
            state = IOSConnectionState(validation: validation.result)
        } catch {
            state = .notConfigured
        }
    }

    func makeConnection() throws -> ConnectorConnection {
        try ConnectorConnection(server: server, user: username, password: password)
    }
}
