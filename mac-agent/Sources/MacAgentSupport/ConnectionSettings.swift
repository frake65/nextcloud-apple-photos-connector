import Foundation

public struct TargetDirectoryPreferences: @unchecked Sendable {
    public static let key = "nextcloud.targetDirectory"
    // WebDAV paths are stored and sent as relative components. The leading
    // slash is presentation-only and must not become part of the DAV path.
    public static let defaultPath = "Photos/Photos Connector"
    public static let confirmedKey = "nextcloud.targetValidated"
    let defaults: UserDefaults
    public init(defaults: UserDefaults = ConnectionPreferences.defaults()) { self.defaults = defaults }
    public var path: String { get { defaults.string(forKey: Self.key) ?? Self.defaultPath } set { defaults.set(Self.normalize(newValue), forKey: Self.key) } }
    public func markConfirmed(_ confirmed: Bool) { defaults.set(confirmed, forKey: Self.confirmedKey) }
    public static func normalize(_ value: String) -> String { value.split(separator: "/").filter { $0 != "" && $0 != "." && $0 != ".." }.map(String.init).joined(separator: "/") }
}

public enum UploadPreferences {
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
