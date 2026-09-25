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
    var targetDirectory: String

    init(server: String, username: String, sourceId: UUID, userId: String?, targetDirectory: String = IOSTargetDirectoryPreferences.defaultPath) {
        self.server = server; self.username = username; self.sourceId = sourceId; self.userId = userId
        self.targetDirectory = IOSTargetDirectoryPreferences.normalize(targetDirectory)
    }

    private enum CodingKeys: String, CodingKey { case server, username, sourceId, userId, targetDirectory }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(server: try container.decode(String.self, forKey: .server), username: try container.decode(String.self, forKey: .username), sourceId: try container.decode(UUID.self, forKey: .sourceId), userId: try container.decodeIfPresent(String.self, forKey: .userId), targetDirectory: try container.decodeIfPresent(String.self, forKey: .targetDirectory) ?? IOSTargetDirectoryPreferences.defaultPath)
    }
}

enum IOSTargetDirectoryPreferences {
    static let defaultPath = "Photos/Photos Connector"

    static func normalize(_ value: String) -> String {
        value.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }.map(String.init).joined(separator: "/")
    }

    static func display(_ value: String) -> String { value.isEmpty ? "" : "/\(value)" }
}

enum IOSTransferNetworkPreferences {
    static let useCellularKey = "ios.transfers.useCellular"
    static let didChangeNotification = Notification.Name("apc.transferNetworkPreferenceDidChange")

    static func useCellularAccess(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: useCellularKey) as? Bool ?? false
    }

    static func setUseCellularAccess(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: useCellularKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
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

    func save(server: String, username: String, password: String, sourceId: UUID, userId: String? = nil, targetDirectory: String = IOSTargetDirectoryPreferences.defaultPath) throws {
        let normalizedServer = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        _ = try ConnectorConnection(server: normalizedServer, user: username, password: password)
        try passwordStore.save(password, account: account(server: normalizedServer, username: username))
        let details = IOSConnectionDetails(server: normalizedServer, username: username, sourceId: sourceId, userId: userId, targetDirectory: targetDirectory)
        defaults.set(try JSONEncoder().encode(details), forKey: key)
    }

    func deletePassword(server: String, username: String) throws {
        try passwordStore.delete(account: account(server: server, username: username))
    }

    func hasStoredCredentials() -> Bool {
        !load().password.isEmpty
    }

    func reset() throws {
        let details = load().details
        try deletePassword(server: details.server, username: details.username)
        let resetDetails = IOSConnectionDetails(server: "", username: "", sourceId: details.sourceId, userId: nil, targetDirectory: details.targetDirectory)
        defaults.set(try JSONEncoder().encode(resetDetails), forKey: key)
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
    @Published var targetDirectory: String
    @Published private(set) var userId: String?
    @Published var useCellularForTransfers: Bool
    @Published private(set) var loginFlowState: IOSLoginFlowState = .idle
    @Published private(set) var loginFailureMessage: String?
    @Published private(set) var state: IOSConnectionState = .notConfigured
    @Published var isShowingSaveError = false
    private let preferences: IOSConnectionPreferences
    private var loginTask: Task<Void, Never>?
    private var connectionCheckTask: Task<Void, Never>?
    private var validatedConnection: (server: String, username: String, password: String)?

    init(preferences: IOSConnectionPreferences = IOSConnectionPreferences()) {
        IOSImportDiagnostics.log("[Startup] IOSConnectionModel init begin")
        self.preferences = preferences
        let saved = preferences.load()
        server = saved.details.server
        username = saved.details.username
        password = saved.password
        userId = saved.details.userId
        targetDirectory = saved.details.targetDirectory
        sourceId = saved.details.sourceId.uuidString.lowercased()
        useCellularForTransfers = IOSTransferNetworkPreferences.useCellularAccess()
        state = server.isEmpty || username.isEmpty || password.isEmpty ? .notConfigured : .notTested
        IOSImportDiagnostics.log("[Startup] IOSConnectionModel init end")
    }

    deinit { loginTask?.cancel(); connectionCheckTask?.cancel() }

    var parsedSourceId: UUID? { UUID(uuidString: sourceId.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var hasConfiguredConnection: Bool { !server.isEmpty && !username.isEmpty && !password.isEmpty }
    var hasStoredCredentials: Bool { preferences.hasStoredCredentials() }

    func save() throws {
        guard let parsedSourceId else { throw UploadError.invalidConfiguration }
        try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId, userId: nil, targetDirectory: targetDirectory)
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
    func setUseCellularForTransfers(_ value: Bool) {
        useCellularForTransfers = value
        IOSTransferNetworkPreferences.setUseCellularAccess(value)
        guard hasConfiguredConnection else { return }
        loginFlowState = .idle
        state = .notTested
        connectionCheckTask?.cancel()
        connectionCheckTask = Task { @MainActor [weak self] in
            await self?.testConnection()
        }
    }
    func showSaveError() { isShowingSaveError = true }

    func testConnection() async {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty, let parsedSourceId else { state = .notConfigured; return }
        state = .checking
        do {
            try preferences.save(server: server, username: username, password: password, sourceId: parsedSourceId, userId: nil, targetDirectory: targetDirectory)
            let connection = try ConnectorConnection(server: server, user: username, password: password)
            let validation = await NextcloudConnectionClient(connection: connection).validate()
            state = IOSConnectionState(validation: validation.result)
            if validation.result == .success { markConnectionValidated() }
        } catch {
            state = .notConfigured
        }
    }

    func startBrowserLogin() {
        let flowID = String(UUID().uuidString.prefix(8)).lowercased()
        IOSImportDiagnostics.log("login[\(flowID)] startBrowserLogin ENTER")
        IOSImportDiagnostics.log("login[\(flowID)] existing loginTask will be cancelled=\(loginTask != nil)")
        IOSImportDiagnostics.log("login[\(flowID)] loginFlowState beforeStart=\(loginFlowState)")
        loginTask?.cancel()
        loginFailureMessage = nil
        loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            loginFlowState = .starting
            IOSImportDiagnostics.log("login[\(flowID)] loginFlowState -> starting")
            var phase = "initiate"
            do {
                let service = NextcloudLoginFlowService(diagnostic: { status in
                    IOSImportDiagnostics.log("login[\(flowID)] polling HTTP status=\(status)")
                })
                IOSImportDiagnostics.log("login[\(flowID)] POST /index.php/login/v2 START")
                let start = try await service.initiate(server: server)
                IOSImportDiagnostics.log("login[\(flowID)] POST /index.php/login/v2 SUCCESS loginHost=\(start.login.host ?? "<missing>") pollHost=\(start.poll.endpoint.host ?? "<missing>")")
                phase = "browser"
                IOSImportDiagnostics.log("login[\(flowID)] Browser open START endpoint=login")
                let browserOpened = await UIApplication.shared.open(start.login)
                IOSImportDiagnostics.log("login[\(flowID)] Browser open RESULT success=\(browserOpened)")
                guard browserOpened else { throw LoginFlowError.network }
                loginFlowState = .waiting
                phase = "polling"
                IOSImportDiagnostics.log("login[\(flowID)] loginFlowState -> waiting")
                IOSImportDiagnostics.log("login[\(flowID)] polling START")
                let credentials: LoginFlowCredentials
                do {
                    credentials = try await service.poll(start)
                    IOSImportDiagnostics.log("login[\(flowID)] polling SUCCESS")
                } catch is CancellationError {
                    IOSImportDiagnostics.log("login[\(flowID)] polling CANCELLED")
                    throw CancellationError()
                } catch LoginFlowError.cancelled {
                    IOSImportDiagnostics.log("login[\(flowID)] polling CANCELLED")
                    throw LoginFlowError.cancelled
                } catch {
                    IOSImportDiagnostics.log("login[\(flowID)] polling FAILED error=\(String(describing: type(of: error)))")
                    throw error
                }
                phase = "fetchUserID"
                IOSImportDiagnostics.log("login[\(flowID)] credentials received phase=fetchUserID")
                let userID: String
                do { userID = try await Self.fetchUserID(server: credentials.server, loginName: credentials.loginName, appPassword: credentials.appPassword) }
                catch { throw LoginFlowPhaseError(category: "userIDRequestFailed", phase: phase, message: Self.loginFailureMessage(phase: phase, category: "userIDRequestFailed"), underlying: error) }
                let connection = try ConnectorConnection(server: credentials.server.absoluteString, authUser: credentials.loginName, davUser: userID, password: credentials.appPassword)
                phase = "status.php"
                let validation = await NextcloudConnectionClient(connection: connection).validate()
                guard validation.result == .success else {
                    let category = validation.result == .authenticationFailed ? "authenticationFailed" : "serverValidationFailed"
                    throw LoginFlowPhaseError(category: category, phase: phase, message: Self.loginFailureMessage(phase: phase, category: category), underlying: LoginFlowError.http(validation.statusCode ?? 0))
                }
                phase = "storage"
                guard let sourceID = parsedSourceId else { throw UploadError.invalidConfiguration }
                try preferences.save(server: credentials.server.absoluteString, username: credentials.loginName, password: credentials.appPassword, sourceId: sourceID, userId: userID, targetDirectory: targetDirectory)
                server = credentials.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                username = credentials.loginName
                password = credentials.appPassword
                userId = userID
                markConnectionValidated(userID: userID)
                loginFlowState = .connected(userID: userID)
                IOSImportDiagnostics.log("login[\(flowID)] loginFlowState -> connected")
            } catch is CancellationError { loginFailureMessage = "Anmeldung abgebrochen (cancelled)."; loginFlowState = .idle; IOSImportDiagnostics.log("login[\(flowID)] phase=\(phase) category=cancelled") }
            catch let error as LoginFlowPhaseError { loginFailureMessage = error.message; loginFlowState = .failed; IOSImportDiagnostics.log("login[\(flowID)] phase=\(error.phase) category=\(error.category) underlying=\(String(describing: type(of: error.underlying)))") }
            catch let error as LoginFlowError {
                let category = phase == "polling" && error == .timeout ? "pollingTimeout" : phase == "polling" && error == .network ? "pollingFailed" : error.diagnosticCategory
                loginFailureMessage = Self.loginFailureMessage(phase: phase, category: category); loginFlowState = .failed; IOSImportDiagnostics.log("login[\(flowID)] phase=\(phase) category=\(category)")
            }
            catch { loginFailureMessage = Self.loginFailureMessage(phase: phase, category: "pollingFailed"); loginFlowState = .failed; IOSImportDiagnostics.log("login[\(flowID)] phase=\(phase) category=pollingFailed error=\(String(describing: type(of: error)))") }
        }
    }

    func cancelBrowserLogin() { loginTask?.cancel(); loginTask = nil; loginFlowState = .idle }

    func disconnect() throws {
        loginTask?.cancel()
        loginTask = nil
        try preferences.reset()
        server = ""
        username = ""
        password = ""
        userId = nil
        validatedConnection = nil
        loginFlowState = .idle
        state = .notConfigured
    }

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

    static func loginFailureMessage(phase: String, category: String) -> String {
        switch category {
        case "networkUnavailable": return "Anmeldung nicht möglich: kein Netzwerk verfügbar (Phase: \(phase))."
        case "timeout", "pollingTimeout": return "Anmeldung abgebrochen: Zeitüberschreitung beim Warten auf Nextcloud (Phase: \(phase))."
        case "authenticationFailed": return "Nextcloud hat die Anmeldung abgelehnt (Phase: \(phase))."
        case "userIDRequestFailed": return "Die Benutzer-ID konnte nach der Anmeldung nicht geladen werden."
        case "serverValidationFailed": return "Die Verbindung konnte nach der Anmeldung nicht bestätigt werden."
        case "invalidLoginFlowResponse": return "Nextcloud lieferte eine ungültige Login-Flow-Antwort (Phase: \(phase))."
        case "httpError": return "Nextcloud meldete einen HTTP-Fehler (Phase: \(phase))."
        default: return "Anmeldung fehlgeschlagen (Phase: \(phase), Ursache: \(category))."
        }
    }

    func makeConnection() throws -> ConnectorConnection {
        try ConnectorConnection(server: server, authUser: username, davUser: userId ?? username, password: password)
    }
}

private struct LoginFlowPhaseError: Error {
    let category: String
    let phase: String
    let message: String
    let underlying: Error
}

enum IOSLoginFlowState: Equatable {
    case idle, starting, waiting, failed
    case connected(userID: String)
}
