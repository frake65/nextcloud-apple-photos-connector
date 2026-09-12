import SwiftUI
import InventoryCore
import AppKit

struct ConnectorSettingsView: View {
    @AppStorage(L10n.languageKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var language = "system"
    @AppStorage("nextcloud.server", store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var server = ""
    @AppStorage("nextcloud.user", store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var user = ""
    @AppStorage(ImportGuard.validatedKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var connectionValidated = false
    @AppStorage(TargetDirectoryPreferences.confirmedKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var targetValidated = false
    @State private var password = ""
    @State private var state = L10n.text("notChecked")
    @State private var validationSucceeded = false
    @State private var targetPath = TargetDirectoryPreferences().path
    @State private var browserSelectedPath = ""
    @State private var showingDirectories = false
    @State private var showingTargetChangeConfirmation = false
    @State private var pendingTargetPath: String?
    @State private var preferencesLoaded = false
    @State private var loginFlowTask: Task<Void, Never>?
    @State private var loginFlowRunning = false
    @State private var applyingLoginFlow = false
    @State private var showingDisconnectConfirmation = false
    @State private var persistentDebugLogger: DebugFileLogger?
    @AppStorage(UploadPreferences.retransferMissingKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var retransferMissing = false
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
                TextField(L10n.text("server"), text: $server).accessibilityIdentifier("settings-server-field").onChange(of: server) { _, _ in if preferencesLoaded && !applyingLoginFlow { invalidate() } }
                Button(loginFlowRunning ? L10n.text("loginFlowCancel") : L10n.text("loginFlowConnect")) {
                    if loginFlowRunning { loginFlowTask?.cancel(); loginFlowTask = nil; loginFlowRunning = false; state = L10n.text("loginFlowCancelled") }
                    else { startLoginFlow() }
                }.disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                TextField(L10n.text("username"), text: $user).accessibilityIdentifier("settings-user-field").onChange(of: user) { _, _ in if preferencesLoaded && !applyingLoginFlow { invalidate() } }
                SecureField(L10n.text("password"), text: $password).accessibilityIdentifier("settings-password-field").onChange(of: password) { _, _ in if preferencesLoaded && !applyingLoginFlow { invalidate() } }
                Button(L10n.text("checkConnection")) { Task { await validateConnection() } }.accessibilityIdentifier("connection-test-button")
                if connectionValidated {
                    Button(L10n.text("connectAnotherAccount")) { startLoginFlow() }
                    Button(L10n.text("disconnect"), role: .destructive) { showingDisconnectConfirmation = true }
                }
                Text(state).accessibilityIdentifier("connection-status")
                    .foregroundStyle(validationSucceeded ? .green : (state == L10n.text("notChecked") ? .secondary : .red))
                    .fontWeight(!validationSucceeded && state != L10n.text("notChecked") ? .bold : .regular)
            }
            Section {
                UploadTargetSummaryView(server: server, user: user, targetPath: targetPath)
                Button(L10n.text("changeTarget")) { browserSelectedPath = targetPath; showingDirectories = true }.accessibilityIdentifier("target-directory-button").disabled(!connectionValidated)
            }
            Section(L10n.text("behavior")) {
                Toggle(L10n.text("retryTransfer"), isOn: $retransferMissing)
                    .accessibilityIdentifier("retransfer-missing-toggle")
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
            password = (try? ConnectionPreferences(server: server, user: user).loadPassword()) ?? ""
            validationSucceeded = connectionValidated
            preferencesLoaded = true
            if !server.isEmpty && !user.isEmpty && !password.isEmpty {
                await validateConnection()
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
        .alert(L10n.text("disconnectConfirmationTitle"), isPresented: $showingDisconnectConfirmation) {
            Button(L10n.text("cancel"), role: .cancel) { }
            Button(L10n.text("disconnect"), role: .destructive) { disconnectLocally() }
        } message: {
            Text(L10n.text("disconnectConfirmationMessage"))
        }
        .background(SettingsWindowObserver())
        .onAppear { SettingsWindowLifecycle.shared.prepareToOpen() }
    }
    private func applyTargetPath(_ path: String) {
        targetPath = path
        targetValidated = connectionValidated && !path.isEmpty
        TargetDirectoryPreferences().markConfirmed(targetValidated)
        NotificationCenter.default.post(name: .targetDirectoryChanged, object: nil)
    }
    private func invalidate() { validationSucceeded = false; connectionValidated = false; targetValidated = false; state = L10n.text("notChecked") }
    private func startLoginFlow() {
        loginFlowRunning = true; state = L10n.text("loginFlowBrowserOpened")
        persistentDebugLogger?.log("login.start")
        let requestedServer = server
        loginFlowTask = Task {
            do {
                let service = NextcloudLoginFlowService()
                let start = try await service.initiate(server: requestedServer)
                _ = NSWorkspace.shared.open(start.login)
                await MainActor.run { state = L10n.text("loginFlowWaiting") }
                let credentials = try await service.poll(start)
                let connection = try ConnectorConnection(server: credentials.server.absoluteString, user: credentials.loginName, password: credentials.appPassword)
                let result = await NextcloudConnectionClient(connection: connection).validate()
                let statusCode = result.statusCode.map(String.init) ?? "none"
                persistentDebugLogger?.log("login.validation status=\(statusCode)")
                guard result.result == .success else { throw LoginFlowError.invalidResponse }
                try ConnectionPreferences(server: credentials.server.absoluteString, user: credentials.loginName).savePassword(credentials.appPassword)
                await MainActor.run {
                    applyingLoginFlow = true
                    server = credentials.server.absoluteString; user = credentials.loginName; password = credentials.appPassword
                    connectionValidated = true; validationSucceeded = true; targetValidated = false
                    applyingLoginFlow = false; loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowConnected")
                    persistentDebugLogger?.log("login.success")
                    NotificationCenter.default.post(name: .connectionStateChanged, object: nil)
                }
            } catch is CancellationError {
                persistentDebugLogger?.log("login.cancelled")
                await MainActor.run { loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowCancelled") }
            } catch {
                persistentDebugLogger?.log("login.failed error=\(String(describing: error))")
                await MainActor.run { loginFlowRunning = false; loginFlowTask = nil; state = L10n.text("loginFlowFailed") }
            }
        }
    }
    private func validateConnection() async {
        persistentDebugLogger?.log("connection.validation.start")
        do {
            let result = await NextcloudConnectionClient(connection: try ConnectorConnection(server: server, user: user, password: password)).validate()
            let statusCode = result.statusCode.map(String.init) ?? "none"
            persistentDebugLogger?.log("connection.validation.status=\(statusCode)")
            let apcStatusCode = result.appStatusCode.map(String.init) ?? "none"
            persistentDebugLogger?.log("connection.apc_status.status=\(apcStatusCode)")
            if result.result == .success {
                persistentDebugLogger?.log("connection.keychain.save.start")
                do {
                    try ConnectionPreferences(server: server, user: user).savePassword(password)
                    persistentDebugLogger?.log("connection.keychain.save.success")
                } catch {
                    let nsError = error as NSError
                    persistentDebugLogger?.log("connection.validation.error stage=keychain_save type=\(String(describing: type(of: error))) osStatus=\(nsError.code)")
                    throw error
                }
            }
            await MainActor.run { validationSucceeded = result.result == .success; connectionValidated = validationSucceeded; if !validationSucceeded { targetValidated = false }; state = switch result.result { case .success: L10n.text("connectionSuccess"); case .authenticationFailed: L10n.text("authError"); case .appMissing: L10n.text("appMissing"); case .unavailable: L10n.text("serverUnavailable"); case .tlsOrNetworkError, .unreachable: L10n.text("serverUnavailable"); case .unexpectedResponse: L10n.text("unexpectedResponse") }; persistentDebugLogger?.log(validationSucceeded ? "connection.validation.success" : "connection.validation.failed"); if validationSucceeded { NotificationCenter.default.post(name: .connectionStateChanged, object: nil) } }
        } catch { persistentDebugLogger?.log("connection.validation.error stage=outer type=\(String(describing: type(of: error)))"); await MainActor.run { validationSucceeded = false; state = L10n.text("serverUnavailable") } }
    }
    private func disconnectLocally() {
        try? ConnectionPreferences(server: server, user: user).deletePassword()
        password = ""; validationSucceeded = false; connectionValidated = false; targetValidated = false
        state = L10n.text("notChecked")
        NotificationCenter.default.post(name: .connectionStateChanged, object: nil)
    }
    private func verifyTargetPath() async {
        guard connectionValidated, !targetPath.isEmpty else { return }
        do {
            let parts = targetPath.split(separator: "/").map(String.init)
            let parent = Array(parts.dropLast())
            let entries = try await NextcloudConnectionClient(connection: ConnectorConnection(server: server, user: user, password: password)).listDirectories(path: parent)
            let exists = entries.contains { $0.path == targetPath }
            await MainActor.run { targetValidated = exists; TargetDirectoryPreferences().markConfirmed(exists) }
            if !exists { await MainActor.run { state = L10n.text("targetNotFound") } }
        } catch {
            await MainActor.run { targetValidated = false; TargetDirectoryPreferences().markConfirmed(false); state = L10n.text("targetCheckFailed") }
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
                    .accessibilityLabel(expanded.contains(entry.path) ? "\(entry.name) einklappen" : "\(entry.name) erweitern")
                    .accessibilityIdentifier("dav-expand-\(identifier(for: entry.path))")
                    .accessibilityValue(expanded.contains(entry.path) ? "expanded" : "collapsed")
                    Button { selectedPath = entry.path } label: { Text(entry.name) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.name) auswählen")
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
    private func loadRoot() async { do { entries = try await client().listDirectories() } catch { errors["/"] = "Root konnte nicht geladen werden." } }
    private func toggle(_ entry: DAVDirectory) {
        if expanded.contains(entry.path) { expanded.remove(entry.path); return }
        expanded.insert(entry.path)
        guard children[entry.path] == nil, !loading.contains(entry.path) else { return }
        loading.insert(entry.path)
        Task { do { let value = try await client().listDirectories(path: entry.path.split(separator: "/").map(String.init)); await MainActor.run { children[entry.path] = value; loading.remove(entry.path) } } catch { await MainActor.run { errors[entry.path] = "Unterordner konnte nicht geladen werden."; loading.remove(entry.path) } } }
    }
    private func createFolder() {
        guard let name = DAVPathValidator.component(newFolderName) else { errors[selectedPath] = L10n.text("invalidFolderName"); return }
        let parent = selectedPath.split(separator: "/").map(String.init)
        Task { do {
            let created = try await client().createDirectory(parent: parent, name: name)
            await MainActor.run { children[parent.joined(separator: "/"), default: []].append(created); expanded.insert(selectedPath); selectedPath = created.path }
        } catch let error as LocalizedError { await MainActor.run { errors[selectedPath] = error.errorDescription ?? L10n.text("folderCreateFailed") } }
        catch { Task { @MainActor in errors[selectedPath] = L10n.text("folderCreateFailed") } }
        }
    }
}
