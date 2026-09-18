import SwiftUI
import InventoryCore
import AppKit
import MacAgentSupport

struct ConnectorSettingsView: View {
    @AppStorage(L10n.languageKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var language = "system"
    private var server: String {
        get { session.server }
        nonmutating set { session.server = newValue }
    }
    private var user: String {
        get { session.user }
        nonmutating set { session.user = newValue }
    }
    @AppStorage(ImportGuard.validatedKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var connectionValidated = false
    @AppStorage(TargetDirectoryPreferences.confirmedKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var targetValidated = false
    private var password: String {
        get { session.password }
        nonmutating set { session.password = newValue }
    }
    @State private var state = L10n.text("notChecked")
    private var validationSucceeded: Bool {
        get { session.validationSucceeded }
        nonmutating set { session.validationSucceeded = newValue }
    }
    @State private var targetPath = TargetDirectoryPreferences().path
    @State private var browserSelectedPath = ""
    @State private var showingDirectories = false
    @State private var showingTargetChangeConfirmation = false
    @State private var pendingTargetPath: String?
    @State private var session = ConnectionSession()
    private var loginFlowTask: Task<Void, Never>? {
        get { session.loginFlowTask }
        nonmutating set { session.loginFlowTask = newValue }
    }
    private var connectionDefaults: UserDefaults { UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard }
    private var loginFlowRunning: Bool {
        get { session.loginFlowRunning }
        nonmutating set { session.loginFlowRunning = newValue }
    }
    private var attemptID: UUID {
        get { session.attemptID }
    }
    @State private var showingResetConfirmation = false
    @State private var persistentDebugLogger: DebugFileLogger?
    @AppStorage(UploadPreferences.debugModeKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var debugMode = false

    var body: some View {
        Form {
            Section(L10n.text("languageSection")) {
                Picker(L10n.text("language"), selection: $language) {
                    ForEach(L10n.supportedLanguages, id: \.self) { code in
                        Text(code == "system" ? L10n.text("systemLanguage") : (L10n.languageNames[code] ?? code)).tag(code)
                    }
                }
                .onChange(of: language) { _, _ in
                    state = validationSucceeded ? L10n.text("connectionSuccess") : L10n.text("notChecked")
                }
            }
            Section(L10n.text("connection")) {
                TextField(L10n.text("server"), text: draftBinding($session.server, clearPassword: true)).accessibilityIdentifier("settings-server-field")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        loginButton
                        connectionStatus.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        loginButton
                        connectionStatus
                    }
                }
                HStack(spacing: 12) {
                    if validationSucceeded {
                        Button { startLoginFlow() } label: {
                            Text(L10n.text("connectAnotherAccount")).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button { showingResetConfirmation = true } label: {
                        Text(L10n.text("resetConnection")).fixedSize(horizontal: false, vertical: true)
                    }
                        .disabled(!session.hasResettableState(defaults: connectionDefaults))
                        .accessibilityIdentifier("reset-connection-button")
                }
                TextField(L10n.text("username"), text: draftBinding($session.user, clearPassword: true)).accessibilityIdentifier("settings-user-field")
                SecureField(L10n.text("password"), text: draftBinding($session.password, clearPassword: false)).accessibilityIdentifier("settings-password-field")
                Button(L10n.text("checkConnection")) { cancelAttempt(); _ = startValidation() }.accessibilityIdentifier("connection-test-button")
            }
            Section {
                UploadTargetSummaryView(server: server, user: user, targetPath: targetPath)
                Button(L10n.text("changeTarget")) { browserSelectedPath = targetPath; showingDirectories = true }.accessibilityIdentifier("target-directory-button").disabled(!validationSucceeded)
            }
            Section(L10n.text("debug")) {
                Toggle(L10n.text("debugMode"), isOn: $debugMode)
                    .accessibilityIdentifier("debug-mode-toggle")
            }
        }
        .padding(20).frame(width: 520).tint(.nextcloudBlue)
        .formStyle(.grouped)
        .onExitCommand { NSApp.keyWindow?.close() }
        .task {
            persistentDebugLogger = DebugFileLogger(enabled: debugMode)
            let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
            try? ConnectionPreferences.migrateLegacyPassword(defaults: defaults)
            server = defaults.string(forKey: "nextcloud.server") ?? ""
            user = defaults.string(forKey: "nextcloud.user") ?? ""
            password = (try? ConnectionPreferences(server: server, user: user).loadPassword()) ?? ""
            validationSucceeded = connectionValidated
            if !server.isEmpty && !user.isEmpty && !password.isEmpty {
                let id = attemptID
                let task = startValidation()
                await task.value
                guard attemptID == id else { return }
                await verifyTargetPath()
            }
        }
        .onChange(of: debugMode) { _, enabled in
            persistentDebugLogger = DebugFileLogger(enabled: enabled)
        }
        .onChange(of: targetPath) { _, value in var prefs = TargetDirectoryPreferences(); prefs.path = value; targetValidated = connectionValidated && !value.isEmpty; prefs.markConfirmed(targetValidated) }
        .sheet(isPresented: $showingDirectories) { DirectoryBrowserView(server: server, user: user, password: password, selectedPath: $browserSelectedPath) { path in
            showingDirectories = false
            if !targetPath.isEmpty && targetPath != path {
                pendingTargetPath = path
                showingTargetChangeConfirmation = true
            } else {
                applyTargetPath(path)
            }
        } }
        .alert(L10n.text("changeTargetConfirmationTitle"), isPresented: $showingTargetChangeConfirmation) {
            Button(L10n.text("cancel"), role: .cancel) { pendingTargetPath = nil }
            Button(L10n.text("changeTargetConfirm"), role: .destructive) {
                if let path = pendingTargetPath { applyTargetPath(path) }
                pendingTargetPath = nil
            }
        } message: {
            Text(L10n.text("changeTargetConfirmationMessage"))
        }
        .alert(L10n.text("resetConnectionTitle"), isPresented: $showingResetConfirmation) {
            Button(L10n.text("cancel"), role: .cancel) { }
            Button(L10n.text("resetConnection"), role: .destructive) { resetConnection() }
        } message: {
            Text(L10n.text("resetConnectionMessage"))
        }
        .background(SettingsWindowObserver())
        .onAppear { SettingsWindowLifecycle.shared.prepareToOpen() }
    }
    private var loginButton: some View {
        Button(loginFlowRunning ? L10n.text("loginFlowCancel") : L10n.text("loginFlowConnect")) {
            if loginFlowRunning { cancelAttempt(); state = L10n.text("loginFlowCancelled") }
            else { startLoginFlow() }
        }.disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var connectionStatus: some View {
        Text(state).accessibilityIdentifier("connection-status")
            .foregroundStyle(validationSucceeded ? .green : (state == L10n.text("notChecked") ? .secondary : .red))
            .fontWeight(!validationSucceeded && state != L10n.text("notChecked") ? .bold : .regular)
    }
    private func logDebug(_ event: String) { DebugLogStore.shared.append(event); persistentDebugLogger?.log(event) }
    private func applyTargetPath(_ path: String) {
        targetPath = path
        targetValidated = connectionValidated && !path.isEmpty
        TargetDirectoryPreferences().markConfirmed(targetValidated)
        NotificationCenter.default.post(name: .targetDirectoryChanged, object: nil)
    }
    private func cancelAttempt() {
        session.cancelAttempt()
    }
    private func draftBinding(_ value: Binding<String>, clearPassword: Bool) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: { newValue in
            guard newValue != value.wrappedValue else { return }
            cancelAttempt()
            value.wrappedValue = newValue
            if clearPassword { password = "" }
            validationSucceeded = false; showingDirectories = false; state = L10n.text("notChecked")
        })
    }
    private func commit(_ credentials: LoginFlowCredentials) throws {
        guard try session.accept(credentials, attempt: attemptID, defaults: connectionDefaults) else { return }
        connectionValidated = true; validationSucceeded = true; targetValidated = false
        NotificationCenter.default.post(name: .connectionStateChanged, object: nil)
    }
    private func startLoginFlow() {
        cancelAttempt()
        let id = attemptID
        loginFlowRunning = true; state = L10n.text("loginFlowBrowserOpened")
        logDebug("login.start host=\(URL(string: server)?.host ?? "unknown")")
        let requestedServer = server
        loginFlowTask = Task {
            do {
                let service = NextcloudLoginFlowService()
                let start = try await service.initiate(server: requestedServer)
                try Task.checkCancellation()
                guard attemptID == id else { return }
                logDebug("login.poll host=\(start.poll.endpoint.host ?? "unknown")")
                guard NSWorkspace.shared.open(start.login) else { throw LoginFlowError.invalidResponse }
                await MainActor.run { guard attemptID == id else { return }; state = L10n.text("loginFlowWaiting") }
                let credentials = try await service.poll(start)
                try Task.checkCancellation()
                guard attemptID == id else { return }
                let connection = try ConnectorConnection(server: credentials.server.absoluteString, user: credentials.loginName, password: credentials.appPassword)
                let result = await NextcloudConnectionClient(connection: connection).validate()
                let statusCode = result.statusCode.map(String.init) ?? "none"
                logDebug("login.validation status=\(statusCode)")
                guard result.result == .success else { throw LoginFlowError.invalidResponse }
                try Task.checkCancellation()
                guard attemptID == id else { return }
                try commit(credentials)
                loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowConnected")
                logDebug("login.success host=\(credentials.server.host ?? "unknown")")
            } catch is CancellationError {
                guard attemptID == id else { return }
                logDebug("login.cancelled")
                await MainActor.run { guard attemptID == id else { return }; loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowCancelled") }
            } catch {
                guard attemptID == id else { return }
                logDebug("login.failed")
                await MainActor.run { guard attemptID == id else { return }; loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowFailed") }
            }
        }
    }
    private func startValidation() -> Task<Void, Never> {
        let id = attemptID
        let task = Task {
            guard attemptID == id, !Task.isCancelled else { return }
            await validateConnection()
            if attemptID == id { session.validationTask = nil }
        }
        session.validationTask = task
        return task
    }
    private func validateConnection() async {
        let id = attemptID
        let credentials = LoginFlowCredentials(server: URL(string: server) ?? URL(fileURLWithPath: "/"), loginName: user, appPassword: password)
        logDebug("connection.validation.start")
        do {
            let result = await NextcloudConnectionClient(connection: try ConnectorConnection(server: server, user: user, password: password)).validate()
            guard attemptID == id, !Task.isCancelled else { return }
            let statusCode = result.statusCode.map(String.init) ?? "none"
            logDebug("connection.validation.status=\(statusCode)")
            let apcStatusCode = result.appStatusCode.map(String.init) ?? "none"
            logDebug("connection.apc_status.status=\(apcStatusCode)")
            if result.result == .success {
                logDebug("connection.keychain.save.start")
                do {
                    try commit(credentials)
                    logDebug("connection.keychain.save.success")
                } catch {
                    let nsError = error as NSError
                    logDebug("connection.validation.error stage=keychain_save type=\(String(describing: type(of: error))) osStatus=\(nsError.code)")
                    throw error
                }
            }
            await MainActor.run { guard attemptID == id else { return }; validationSucceeded = result.result == .success;  state = switch result.result { case .success: L10n.text("connectionSuccess"); case .authenticationFailed: L10n.text("authError"); case .appMissing: L10n.text("appMissing"); case .unavailable: L10n.text("serverUnavailable"); case .tlsOrNetworkError, .unreachable: L10n.text("serverUnavailable"); case .unexpectedResponse: L10n.text("unexpectedResponse") }; logDebug(validationSucceeded ? "connection.validation.success" : "connection.validation.failed"); if validationSucceeded { NotificationCenter.default.post(name: .connectionStateChanged, object: nil) } }
        } catch { logDebug("connection.validation.error stage=outer type=\(String(describing: type(of: error)))"); await MainActor.run { guard attemptID == id else { return }; validationSucceeded = false; state = L10n.text("serverUnavailable") } }
    }
    private func resetConnection() {
        do {
            try session.resetConnection(defaults: connectionDefaults)
            showingDirectories = false; showingTargetChangeConfirmation = false
            pendingTargetPath = nil; browserSelectedPath = ""
            state = L10n.text("notChecked")
            logDebug("connection.reset.success")
            NotificationCenter.default.post(name: .connectionStateChanged, object: nil)
        } catch {
            state = L10n.text("resetConnectionFailed")
            logDebug("connection.reset.failed")
        }
    }
    private func verifyTargetPath() async {
        guard validationSucceeded, !targetPath.isEmpty else { return }
        let id = attemptID
        do {
            let parts = targetPath.split(separator: "/").map(String.init)
            let parent = Array(parts.dropLast())
            let entries = try await NextcloudConnectionClient(connection: ConnectorConnection(server: server, user: user, password: password)).listDirectories(path: parent)
            guard attemptID == id else { return }
            let exists = entries.contains { $0.path == targetPath }
            await MainActor.run { guard attemptID == id else { return }; targetValidated = exists; TargetDirectoryPreferences().markConfirmed(exists) }
            if !exists { await MainActor.run { guard attemptID == id else { return }; state = L10n.text("targetNotFound") } }
        } catch {
            guard attemptID == id else { return }
            await MainActor.run { guard attemptID == id else { return }; targetValidated = false; TargetDirectoryPreferences().markConfirmed(false); state = L10n.text("targetCheckFailed") }
        }
    }
}

private struct DirectoryBrowserView: View {
    let server: String; let user: String; let password: String
    @Binding var selectedPath: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DAVDirectory] = []
    @State private var children: [String: [DAVDirectory]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleEntries) { entry in
                      HStack {
                    Button { toggle(entry) } label: {
                        Image(systemName: expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format(expanded.contains(entry.path) ? "collapseFolder" : "expandFolder", entry.name))
                    .accessibilityIdentifier("dav-expand-\(identifier(for: entry.path))")
                    .accessibilityValue(expanded.contains(entry.path) ? "expanded" : "collapsed")
                    Button { selectedPath = entry.path } label: { Text(entry.name) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("selectFolder", entry.name))
                        .accessibilityIdentifier("dav-node-\(identifier(for: entry.path))")
                    if loading.contains(entry.path) { ProgressView().controlSize(.small) }
                    if let message = errors[entry.path] { Text(message).foregroundStyle(.red).font(.caption) }
                      }.padding(.leading, CGFloat(depth(of: entry.path) * 16)).padding(4)
                        .background(selectedPath == entry.path ? Color.red : Color.clear)
                        .foregroundStyle(selectedPath == entry.path ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }.frame(minHeight: 260)
            if !selectedPath.isEmpty { Text(L10n.text("selectedPrefix") + ": \(selectedPath)").font(.caption) }
            HStack { Button(L10n.text("cancel")) { dismiss() }; Spacer()
                Button(L10n.text("newFolder")) { newFolderName = ""; showingNewFolder = true }.disabled(selectedPath.isEmpty)
                Button(L10n.text("choose")) { onConfirm(selectedPath); dismiss() }.disabled(selectedPath.isEmpty)
            }
        }.padding().task { await loadRoot() }
        .alert(L10n.text("newFolder"), isPresented: $showingNewFolder) {
            TextField(L10n.text("folderName"), text: $newFolderName)
            Button(L10n.text("cancel"), role: .cancel) {}
            Button(L10n.text("create")) { createFolder() }
        } message: { Text(L10n.format("folderWillBeCreatedUnder", selectedPath)) }
    }
    private var visibleEntries: [DAVDirectory] {
        func append(_ values: [DAVDirectory], into output: inout [DAVDirectory]) { for value in values { output.append(value); if expanded.contains(value.path), let nested = children[value.path] { append(nested, into: &output) } } }
        var result: [DAVDirectory] = []; append(entries, into: &result); return result
    }
    private func depth(of path: String) -> Int { max(0, path.split(separator: "/").count - 1) }
    private func identifier(for path: String) -> String { DAVNodeIdentifier.make(for: path) }
    private func client() throws -> NextcloudConnectionClient { try NextcloudConnectionClient(connection: ConnectorConnection(server: server, user: user, password: password)) }
    private func loadRoot() async { do { entries = try await client().listDirectories() } catch { errors["/"] = L10n.text("rootLoadFailed") } }
    private func toggle(_ entry: DAVDirectory) {
        if expanded.contains(entry.path) { expanded.remove(entry.path); return }
        expanded.insert(entry.path)
        guard children[entry.path] == nil, !loading.contains(entry.path) else { return }
        loading.insert(entry.path)
        Task { do { let value = try await client().listDirectories(path: entry.path.split(separator: "/").map(String.init)); await MainActor.run { children[entry.path] = value; loading.remove(entry.path) } } catch { await MainActor.run { errors[entry.path] = L10n.text("subfolderLoadFailed"); loading.remove(entry.path) } } }
    }
    private func localizedFolderError(_ error: any LocalizedError) -> String {
        switch error {
        case UploadError.http(let status): return L10n.format("folderRequestFailed", status)
        default:
            let description = error.errorDescription ?? ""
            switch description {
            case "Keine Berechtigung zum Anlegen des Ordners.": return L10n.text("folderPermissionDenied")
            case "Der Ordner existiert möglicherweise bereits.": return L10n.text("folderAlreadyExists")
            case "Der übergeordnete Ordner fehlt oder ist in Konflikt.": return L10n.text("folderParentConflict")
            default:
                if description.hasPrefix("Der DAV-Server meldet einen Serverfehler (HTTP "),
                   let status = description.split(separator: " ").last?.filter({ $0.isNumber }) {
                    return L10n.format("folderServerError", status)
                }
                return L10n.text("folderCreateFailed")
            }
        }
    }
    private func createFolder() {
        guard let name = DAVPathValidator.component(newFolderName) else { errors[selectedPath] = L10n.text("invalidFolderName"); return }
        let parent = selectedPath.split(separator: "/").map(String.init)
        Task { do {
            let created = try await client().createDirectory(parent: parent, name: name)
            await MainActor.run { children[parent.joined(separator: "/"), default: []].append(created); expanded.insert(selectedPath); selectedPath = created.path }
        } catch let error as LocalizedError { await MainActor.run { errors[selectedPath] = localizedFolderError(error) } }
        catch { Task { @MainActor in errors[selectedPath] = L10n.text("folderCreateFailed") } }
        }
    }
}
