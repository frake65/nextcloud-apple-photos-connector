import SwiftUI

@main
struct ApplePhotosConnectorApp: App {
    @UIApplicationDelegateAdaptor(ApplePhotosConnectorAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    init() { IOSImportDiagnostics.log("[Startup] process/app init") }
}

final class ApplePhotosConnectorAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        IOSImportDiagnostics.log("[Startup] AppDelegate didFinishLaunching begin")
        Task.detached(priority: .utility) {
            IOSImportDiagnostics.log("[Startup] background reconciliation begin")
            let store = ImportQueueStore()
            let coordinator = BackgroundTransferCoordinator.shared
            let result = await coordinator.reconcileTasks(queueStore: store)
            let runs = await store.allRuns()
            let bindings = await coordinator.activeBindings()
            let queueFile = await store.fileExists() ? "yes" : "no"
            IOSImportDiagnostics.log("RECOVERY app launch queueFile=\(queueFile) persistedRuns=\(runs.count) bindings=\(bindings.count) tasksReconciliation=\(result.count)")
            for run in runs where run.state != .completed && run.state != .cancelled {
                let states = run.assets.map { $0.state.rawValue }.joined(separator: ",")
                let serverRun = run.serverRunID == nil ? "no" : "yes"
                IOSImportDiagnostics.log("RECOVERY run=\(run.localRunID.uuidString.prefix(8)) state=\(run.state.rawValue) assets=\(run.assets.count) assetStates=\(states) serverRunID=\(serverRun)")
            }
            let activeRunIDs = Set(bindings.map(\.localRunID))
            let recoverableRunIDs = await store.recoverableRuns().filter { !activeRunIDs.contains($0.localRunID) }.map { String($0.localRunID.uuidString.prefix(8)) }
            IOSImportDiagnostics.log("RECOVERY activeRunIDs=\(activeRunIDs.map { String($0.uuidString.prefix(8)) }.sorted()) recoverableRunIDs=\(recoverableRunIDs)")
            IOSImportDiagnostics.log("[Startup] background reconciliation end")
        }
        IOSImportDiagnostics.log("[Startup] AppDelegate didFinishLaunching end")
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransferCoordinator.sessionIdentifier else { return }
        IOSImportDiagnostics.log("app/background-session relaunch identifier=\(identifier)")
        BackgroundTransferCoordinator.shared.setBackgroundEventsCompletionHandler(completionHandler)
    }
}
