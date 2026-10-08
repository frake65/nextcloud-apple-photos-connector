import SwiftUI

@main
struct ApplePhotosConnectorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    init() {
        IOSImportDiagnostics.announceIfEnabled()
        IOSImportDiagnostics.log("[Startup] process/app init")
    }
}
