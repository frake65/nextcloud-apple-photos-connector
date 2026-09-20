import Foundation
import Security
import Combine
import InventoryCore
import UIKit

struct IOSConnectionDetails: Codable, Equatable {
    var server: String
    var username: String
    var sourceId: UUID
    var userId: String?
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
            ?? IOSConnectionDetails(server: "", username: "", sourceId: UUID(), userId: nil)
        let password: String
        do { password = try passwordStore.load(account: account(server: details.server, username: details.username)) ?? "" }
        catch { password = "" }
        return (details, password)
    }

    func save(server: String, username: String, password: String, sourceId: UUID, userId: String? = nil) throws {
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        _ = try ConnectorConnection(server: normalizedServer, user: username, password: password)
        try passwordStore.save(password, account: account(server: normalizedServer, username: username))
        let details = IOSConnectionDetails(server: normalizedServer, username: username, sourceId: sourceId, userId: userId)
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
    @Published private(set) var userId: String?
    @Published private(set) var loginFlowState: IOSLoginFlowState = .idle
    @Published private(set) var state: IOSConnectionState = .notConfigured
    @Published var isShowingSaveError = false
    private let preferences: IOSConnectionPreferences
    private var loginTask: Task<Void, Never>?
    private var validatedConnection: (server: String, username: String, password: String)?

    init(preferences: IOSConnectionPreferences = IOSConnectionPreferences()) {
        self.preferences = preferences
        let saved = preferences.load()
        server = saved.details.server
        username = saved.details.username
        password = saved.password
        userId = saved.details.userId
        sourceId = saved.details.sourceId.uuidString.lowercased()
        state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested
    }

    deinit { loginTask?.cancel() }

    var parsedSourceId: UUID? { UUID(uuidString: sourceId.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var hasConfiguredConnection: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty }

    func save() throws {
        guard let parsedSourceId else { throw UploadError.invalidConfiguration }
        try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId, userId: nil)
        userId = nil
        validatedConnection = nil
    }

    func saved() { state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested }
    func markEdited() {
        if let validatedConnection,
           validatedConnection.server == server,
           validatedConnection.username == username,
           validatedConnection.password == password {
            return
        }
        self.validatedConnection = nil
        loginFlowState = .idle
        state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested
    }
    func markConnectionValidated(userID: String? = nil) {
        validatedConnection = (server, username, password)
        self.userId = userID
        state = .connected
    }
    func showSaveError() { isShowingSaveError = true }

    func testConnection() async {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty, let parsedSourceId else { state = .notConfigured; return }
        state = .checking
        do {
            try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId, userId: nil)
            let connection = try ConnectorConnection(server: server, user: username, password: password)
            let validation = await NextcloudConnectionClient(connection: connection).validate()
            state = IOSConnectionState(validation: validation.result)
            if validation.result == .success { markConnectionValidated() }
        } catch {
            state = .notConfigured
        }
    }

    func startBrowserLogin() {
        loginTask?.cancel()
        loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            loginFlowState = .starting
            do {
                let service = NextcloudLoginFlowService()
                let start = try await service.initiate(server: server)
                guard await UIApplication.shared.open(start.login) else { throw LoginFlowError.network }
                loginFlowState = .waiting
                let credentials = try await service.poll(start)
                let userID = try await Self.fetchUserID(server: credentials.server, loginName: credentials.loginName, appPassword: credentials.appPassword)
                let connection = try ConnectorConnection(server: credentials.server.absoluteString, authUser: credentials.loginName, davUser: userID, password: credentials.appPassword)
                let validation = await NextcloudConnectionClient(connection: connection).validate()
                guard validation.result == .success else { throw LoginFlowError.http(validation.statusCode ?? 0) }
                guard let sourceID = parsedSourceId else { throw UploadError.invalidConfiguration }
                try preferences.save(server: credentials.server.absoluteString, username: credentials.loginName, password: credentials.appPassword, sourceId: sourceID, userId: userID)
                server = credentials.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                username = credentials.loginName
                password = credentials.appPassword
                userId = userID
                markConnectionValidated(userID: userID)
                loginFlowState = .connected(userID: userID)
            } catch is CancellationError { loginFlowState = .idle }
            catch LoginFlowError.cancelled { loginFlowState = .idle }
            catch { loginFlowState = .failed }
        }
    }

    func cancelBrowserLogin() { loginTask?.cancel(); loginTask = nil; loginFlowState = .idle }

    private static func fetchUserID(server: URL, loginName: String, appPassword: String) async throws -> String {
        let connection = try ConnectorConnection(server: server.absoluteString, user: loginName, password: appPassword)
        var components = URLComponents(url: connection.base.appendingPathComponent("ocs/v1.php/cloud/user"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components?.url else { throw LoginFlowError.invalidResponse }
        var requestWithHeaders = URLRequest(url: url)
        requestWithHeaders.httpMethod = "GET"
        requestWithHeaders.setValue("Basic " + Data("\(loginName):\(appPassword)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        requestWithHeaders.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        requestWithHeaders.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await NetworkTransport().send(requestWithHeaders, file: nil)
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let ocs = object["ocs"] as? [String: Any], let data = ocs["data"] as? [String: Any],
              let id = data["id"] as? String, !id.isEmpty else { throw LoginFlowError.invalidResponse }
        return id
    }

    func makeConnection() throws -> ConnectorConnection {
        try ConnectorConnection(server: server, authUser: username, davUser: userId ?? username, password: password)
    }
}

enum IOSLoginFlowState: Equatable {
    case idle, starting, waiting, failed
    case connected(userID: String)
}
