import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: IOSConnectionModel
    private enum Field: Hashable { case server, username, password }
    @FocusState private var focusedField: Field?
    #if DEBUG
    @State private var diagnosticsEnabled = IOSImportDiagnostics.enabled
    #endif

    var body: some View {
        Form {
            Section("Nextcloud") {
                TextField("Server-URL", text: $model.server)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    .textContentType(.URL)
                    .focused($focusedField, equals: .server)
                Button("Mit Nextcloud anmelden") { model.startBrowserLogin() }
                    .disabled(model.server.isEmpty || model.loginFlowState == .starting || model.loginFlowState == .waiting)
                if model.loginFlowState == .starting {
                    ProgressView("Anmeldung im Browser …")
                } else if model.loginFlowState == .waiting {
                    ProgressView("Warte auf Freigabe in Nextcloud …")
                    Button("Abbrechen") { model.cancelBrowserLogin() }
                } else if case .connected = model.loginFlowState {
                    Text("Verbunden als \(model.username)")
                } else if model.loginFlowState == .failed {
                    Text("Die Anmeldung konnte nicht abgeschlossen werden.").font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Manuell anmelden") {
                Text("Alternativ kannst du Benutzername und App-Passwort manuell eingeben.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Benutzername", text: $model.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focusedField, equals: .username)
                SecureField("App-Passwort", text: $model.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                HStack {
                    Image(systemName: model.state == .connected ? "checkmark.circle.fill" : model.state == .checking ? "arrow.triangle.2.circlepath" : "circle")
                        .foregroundStyle(model.state == .connected ? .green : .secondary)
                    Text(model.state.title).font(.subheadline)
                }
                Button("Verbindung testen") { Task { await model.testConnection() } }
                    .disabled(model.state == .checking || model.server.isEmpty || model.username.isEmpty || model.password.isEmpty)
            }

            Section("Quellen-ID") {
                TextField("UUID der logischen Fotomediathek", text: $model.sourceId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Text("Für Mac-Importe als „bereits in Nextcloud“ muss hier dieselbe Source-ID stehen wie auf dem Mac. Sie ist in der Datei source.json im Application-Support-Ordner von Apple Photos Connector gespeichert. Eine neue ID erzeugt einen getrennten Server-Namensraum. Für eine eigenständige Fotomediathek eine eigene ID verwenden.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.parsedSourceId == nil { Text("Bitte eine gültige UUID eingeben.").font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Text("Das App-Passwort wird im iOS-Schlüsselbund gespeichert. Serveradresse, Benutzername und Source-ID liegen in den App-Einstellungen.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Einstellungen speichern") {
                    do { try model.save(); model.saved() }
                    catch { model.showSaveError() }
                }
                .disabled(model.password.isEmpty || model.username.isEmpty || model.parsedSourceId == nil)
            }

            #if DEBUG
            Section("Diagnose") {
                Toggle("Diagnoseprotokoll", isOn: Binding(
                    get: { diagnosticsEnabled },
                    set: { value in
                        diagnosticsEnabled = value
                        UserDefaults.standard.set(value, forKey: IOSImportDiagnostics.defaultsKey)
                    }
                ))
            }
            #endif
        }
        .navigationTitle("Verbindung")
        .onChange(of: model.state) { _, state in
            if state == .connected { focusedField = nil }
        }
        .onChange(of: model.loginFlowState) { _, state in
            if case .connected = state { focusedField = nil }
        }
        .onChange(of: model.server) { _, _ in model.markEdited() }
        .onChange(of: model.username) { _, _ in model.markEdited() }
        .onChange(of: model.password) { _, _ in model.markEdited() }
        .alert("Einstellungen konnten nicht gespeichert werden", isPresented: $model.isShowingSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Prüfe Serveradresse, Benutzername und App-Passwort.")
        }
    }
}
