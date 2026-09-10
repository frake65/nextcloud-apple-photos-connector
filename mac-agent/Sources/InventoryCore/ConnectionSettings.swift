import Foundation

public struct ConnectionValidation: Sendable, Equatable {
    public enum Result: Sendable, Equatable { case success, unreachable, authenticationFailed, appMissing, unavailable, tlsOrNetworkError, unexpectedResponse }
    public let result: Result
    public let statusCode: Int?
    public let appStatusCode: Int?
    public init(result: Result, statusCode: Int? = nil, appStatusCode: Int? = nil) { self.result = result; self.statusCode = statusCode; self.appStatusCode = appStatusCode }
}

public struct NextcloudConnectionClient: Sendable {
    public let connection: ConnectorConnection
    public let transport: any DAVTransport
    public init(connection: ConnectorConnection, transport: any DAVTransport = NetworkTransport()) { self.connection = connection; self.transport = transport }
    public func statusRequest() -> URLRequest { connection.request(path: ["status.php"], method: "GET") }
    public func validate() async -> ConnectionValidation {
        do {
            let response = try await transport.send(statusRequest(), file: nil)
            guard (200..<300).contains(response.status) else {
                if response.status == 401 || response.status == 403 { return ConnectionValidation(result: .authenticationFailed, statusCode: response.status) }
                if response.status >= 500 { return ConnectionValidation(result: .unavailable, statusCode: response.status) }
                return ConnectionValidation(result: .unexpectedResponse, statusCode: response.status)
            }
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], object["installed"] != nil else { return ConnectionValidation(result: .unexpectedResponse, statusCode: response.status) }
            let appResponse = try await transport.send(connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "status"], method: "GET"), file: nil)
            if appResponse.status == 401 || appResponse.status == 403 { return ConnectionValidation(result: .authenticationFailed, statusCode: appResponse.status, appStatusCode: appResponse.status) }
            if appResponse.status == 404 { return ConnectionValidation(result: .appMissing, statusCode: appResponse.status, appStatusCode: appResponse.status) }
            if appResponse.status >= 500 { return ConnectionValidation(result: .unavailable, statusCode: appResponse.status, appStatusCode: appResponse.status) }
            guard (200..<300).contains(appResponse.status), let app = try? JSONSerialization.jsonObject(with: appResponse.data) as? [String: Any], app["app"] as? String == "apple_photos_connector" else { return ConnectionValidation(result: .unexpectedResponse, statusCode: appResponse.status, appStatusCode: appResponse.status) }
            return ConnectionValidation(result: .success, statusCode: response.status, appStatusCode: appResponse.status)
        } catch let error as URLError where error.code == .secureConnectionFailed || error.code == .serverCertificateUntrusted { return ConnectionValidation(result: .tlsOrNetworkError) }
        catch { return ConnectionValidation(result: .unreachable) }
    }
    public func listDirectories(path: [String] = []) async throws -> [DAVDirectory] {
        var request = connection.request(path: ["remote.php", "dav", "files", connection.user] + path, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth"); request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request, file: nil)
        guard response.status == 207 else { throw UploadError.http(response.status) }
        return try DAVDirectoryParser.parse(response.data, relativeTo: path)
    }
    public func createDirectory(parent: [String], name: String) async throws -> DAVDirectory {
        guard let safe = DAVPathValidator.component(name) else { throw UploadError.invalidFilename }
        let path = parent + [safe]
        let response = try await transport.send(connection.request(path: ["remote.php", "dav", "files", connection.user] + path, method: "MKCOL"), file: nil)
        switch response.status {
        case 200...299: return DAVDirectory(path: path.joined(separator: "/"), name: safe, childrenMayExist: true)
        case 401, 403: throw UploadError.diagnostic("Keine Berechtigung zum Anlegen des Ordners.")
        case 405: throw UploadError.diagnostic("Der Ordner existiert möglicherweise bereits.")
        case 409: throw UploadError.diagnostic("Der übergeordnete Ordner fehlt oder ist in Konflikt.")
        case 500...599: throw UploadError.diagnostic("Der DAV-Server meldet einen Serverfehler (HTTP \(response.status)).")
        default: throw UploadError.http(response.status)
        }
    }
}

public struct DAVDirectory: Sendable, Equatable, Identifiable { public let path: String; public var id: String { path }; public let name: String; public let childrenMayExist: Bool }

public struct DAVDirectoryNode: Sendable, Equatable, Identifiable {
    public let displayName: String
    public let relativePath: String
    public var isExpanded: Bool = false
    public var isLoading: Bool = false
    public var childrenLoaded: Bool = false
    public var children: [DAVDirectoryNode] = []
    public var error: String?
    public var id: String { relativePath }
    public init(displayName: String, relativePath: String) { self.displayName = displayName; self.relativePath = relativePath }
}

public enum DAVPathValidator {
    public static func component(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        return name
    }
}

public enum DAVNodeIdentifier {
    public static func make(for path: String) -> String {
        path.split(separator: "/").map(String.init).joined(separator: "-").unicodeScalars.map { scalar in
            let allowed = scalar.value == 45 || (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
            return allowed ? String(scalar) : "-"
        }.joined()
    }
}

public enum DAVDirectoryParser {
    public static func parse(_ data: Data, relativeTo base: [String]) throws -> [DAVDirectory] {
        let delegate = Delegate(base: base); let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse() else { throw UploadError.invalidResponse }
        return delegate.items
    }
    private final class Delegate: NSObject, XMLParserDelegate {
        let base: [String]; var items: [DAVDirectory] = []; var href = ""; var isCollection = false; var current = ""
        init(base: [String]) { self.base = base }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) { current = name.lowercased(); if current.hasSuffix("href") { href = "" }; if current.hasSuffix("collection") { isCollection = true } }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if current.hasSuffix("href") { href += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) { if name.lowercased().hasSuffix("response") { if isCollection, let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)), let last = url.pathComponents.last, last != "" { let decoded = url.path.removingPercentEncoding ?? url.path; let parts = decoded.split(separator: "/").map(String.init); if let marker = parts.firstIndex(of: "files"), parts.count > marker + 2 { let path = parts.dropFirst(marker + 2).joined(separator: "/"); if !path.isEmpty && path != base.joined(separator: "/") { items.append(DAVDirectory(path: path, name: last.removingPercentEncoding ?? last, childrenMayExist: true)) } } }; isCollection = false; href = "" } }
    }
}

public struct TargetDirectoryPreferences: @unchecked Sendable {
    public static let key = "nextcloud.targetDirectory"
    public static let defaultPath = "Photos/Apple Photos Connector"
    public static let confirmedKey = "nextcloud.targetValidated"
    let defaults: UserDefaults
    public init(defaults: UserDefaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard) { self.defaults = defaults }
    public var path: String { get { defaults.string(forKey: Self.key) ?? Self.defaultPath } set { defaults.set(Self.normalize(newValue), forKey: Self.key) } }
    public func markConfirmed(_ confirmed: Bool) { defaults.set(confirmed, forKey: Self.confirmedKey) }
    public static func normalize(_ value: String) -> String { value.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }.map(String.init).joined(separator: "/") }
}

public enum UploadPreferences {
    public static let retransferMissingKey = "nextcloud.retransferMissingAfterDeletion"
    public static let debugModeKey = "nextcloud.debugMode"
}

public struct ImportConfigurationState: Sendable, Equatable {
    public let serverSet: Bool, userSet: Bool, passwordAvailable: Bool
    public let connectionValidated: Bool, targetSet: Bool, targetConfirmed: Bool
    public init(serverSet: Bool, userSet: Bool, passwordAvailable: Bool, connectionValidated: Bool, targetSet: Bool, targetConfirmed: Bool) {
        self.serverSet = serverSet; self.userSet = userSet; self.passwordAvailable = passwordAvailable; self.connectionValidated = connectionValidated; self.targetSet = targetSet; self.targetConfirmed = targetConfirmed
    }
}

public enum ImportGuard {
    public static let validatedKey = "nextcloud.connectionValidated"
    public static func failure(for state: ImportConfigurationState) -> String? {
        guard state.serverSet && state.userSet && state.passwordAvailable else { return "Bitte prüfe zuerst die Verbindung in den Einstellungen." }
        guard state.connectionValidated else { return "Bitte prüfe zuerst die Verbindung in den Einstellungen." }
        guard state.targetSet else { return "Bitte wähle in den Einstellungen ein Zielverzeichnis." }
        guard state.targetConfirmed else { return "Bitte bestätige das Zielverzeichnis für die aktuelle Serververbindung erneut." }
        return nil
    }
}

/// Local PhotoKit browsing is independent from Nextcloud upload readiness.
public enum PhotoKitBrowsingEligibility {
    public static func allows(authorized: Bool) -> Bool { authorized }
}
