import Foundation
import InventoryCore
#if canImport(Darwin)
import Darwin
#endif

let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
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
    defaults.set(server, forKey: "nextcloud.server"); defaults.set(user, forKey: "nextcloud.user")
    do { try store.update(password: password, account: user); print("URL gespeichert: ja\nBenutzer gespeichert: ja\nPasswort gespeichert: ja") }
    catch { print("Passwort konnte nicht gespeichert werden."); exit(1) }
case "status":
    let server = defaults.string(forKey: "nextcloud.server")?.isEmpty == false
    let user = defaults.string(forKey: "nextcloud.user") ?? ""
    let password = (try? store.load(account: user)) ?? nil
    print("URL vorhanden: \(server ? "ja" : "nein")\nBenutzer vorhanden: \(user.isEmpty ? "nein" : "ja")\nPasswort vorhanden: \(password?.isEmpty == false ? "ja" : "nein")")
default:
    print("Verwendung: APCConfigureConnection configure-connection | status"); exit(2)
}
