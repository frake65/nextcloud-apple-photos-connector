import Foundation
import InventoryCore
import MacAgentSupport
#if canImport(Darwin)
import Darwin
#endif

let defaults = ConnectionPreferences.defaults()
let store = KeychainPasswordStore()

func hiddenLine() -> String {
    #if canImport(Darwin)
    var term = termios(); tcgetattr(STDIN_FILENO, &term); var hidden = term; hidden.c_lflag &= ~tcflag_t(ECHO); tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &term); print() }
    #endif
    return readLine() ?? ""
}

let command = CommandLine.arguments.dropFirst().first ?? ""
switch command {
case "configure-connection":
    print("Nextcloud-URL:", terminator: " "); let server = readLine() ?? ""
    print("Benutzer:", terminator: " "); let user = readLine() ?? ""
    print("App-Passwort:", terminator: " "); let password = hiddenLine()
    do { try ConnectionPreferences(server: server, user: user, store: store).savePassword(password); defaults.set(server, forKey: "nextcloud.server"); defaults.set(user, forKey: "nextcloud.user"); defaults.set(false, forKey: ImportGuard.validatedKey); defaults.set(false, forKey: TargetDirectoryPreferences.confirmedKey); print("URL gespeichert: ja\nBenutzer gespeichert: ja\nPasswort gespeichert: ja") }
    catch { print("Passwort konnte nicht gespeichert werden."); exit(1) }
case "status":
    try? ConnectionPreferences.migrateLegacyPassword(defaults: defaults, store: store)
    let server = defaults.string(forKey: "nextcloud.server")?.isEmpty == false
    let user = defaults.string(forKey: "nextcloud.user") ?? ""
    let password = (try? ConnectionPreferences(server: defaults.string(forKey: "nextcloud.server") ?? "", user: user, store: store).loadPassword()) ?? nil
    print("URL vorhanden: \(server ? "ja" : "nein")\nBenutzer vorhanden: \(user.isEmpty ? "nein" : "ja")\nPasswort vorhanden: \(password?.isEmpty == false ? "ja" : "nein")")
default:
    print("Verwendung: APCConfigureConnection configure-connection | status"); exit(2)
}
