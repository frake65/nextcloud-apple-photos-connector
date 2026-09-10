import SwiftUI
import InventoryCore
import Photos
import AppKit
import OSLog

extension Notification.Name {
    static let requestPhotoAccess = Notification.Name("APCRequestPhotoAccess")
    static let targetDirectoryChanged = Notification.Name("APCTargetDirectoryChanged")
    static let connectionStateChanged = Notification.Name("APCConnectionStateChanged")
}

extension Color {
    static let nextcloudBlue = Color(red: 0.0, green: 0.51, blue: 0.79)
    static let nextcloudBlueDark = Color(red: 0.0, green: 0.35, blue: 0.56)
}

@main
struct MacAgentApp: App {
    var body: some Scene {
        WindowGroup(L10n.text("title")) {
            InventoryView()
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("requestPhotoAccess")) {
                    NotificationCenter.default.post(name: .requestPhotoAccess, object: nil)
                }
            }
        }
        Settings {
            ConnectorSettingsView()
        }
    }

    init() {
        // ImportScope was removed. Drop only its obsolete per-source values;
        // credentials, server, target and PhotoKit selection state are kept.
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("nextcloud.importScope.") {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class InventoryModel: ObservableObject {
    let scanner = PhotoLibraryScanner()
    let uploader = UploadCoordinator()
    let albums = AlbumInventoryCoordinator()
    @Published private(set) var server = ""
    @Published private(set) var user = ""
    @Published private(set) var targetPath = TargetDirectoryPreferences.defaultPath
    @Published var json = ""
    @Published var status = ""
    @Published var scanning = false
    @Published var uploadProgress: UploadCoordinator.Progress?
    @Published var uploadInProgress = false
    @Published var debugLog: [String] = []
    var uploadTask: Task<Void, Never>?
    private var uploadLogger: DebugFileLogger?
    private var preferences: ConnectionPreferences!

    init() {
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        server = defaults.string(forKey: "nextcloud.server") ?? ""
        user = defaults.string(forKey: "nextcloud.user") ?? ""
        preferences = ConnectionPreferences(server: server, user: user)
        targetPath = TargetDirectoryPreferences().path
        uploadLogger = DebugFileLogger(enabled: defaults.bool(forKey: UploadPreferences.debugModeKey))
    }
    func refreshPreferences() {
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        server = defaults.string(forKey: "nextcloud.server") ?? ""
        user = defaults.string(forKey: "nextcloud.user") ?? ""
        preferences = ConnectionPreferences(server: server, user: user)
        targetPath = TargetDirectoryPreferences().path
        let enabled = defaults.bool(forKey: UploadPreferences.debugModeKey)
        if (uploadLogger != nil) != enabled { uploadLogger = DebugFileLogger(enabled: enabled) }
    }
    func logUploadEvent(_ event: String) {
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        guard defaults.bool(forKey: UploadPreferences.debugModeKey), isSafeUploadEvent(event) else { return }
        uploadLogger?.log(event)
    }
    private func isSafeUploadEvent(_ event: String) -> Bool {
        let prefixes = ["upload.ui.requested", "upload.ui.requested selectedAssets=", "upload.ui.reinventory=", "upload.snapshot assets=", "upload.start.skipped reason=", "upload.coordinator.entered", "inventory.request.start", "inventory.candidates assets=", "inventory.payload.assets=", "inventory.payload.invalid expected=", "reinventory.enabled=", "inventory.response.state=", "inventory.response.ticket=", "upload.queue.added", "upload.queue.skipped reason=", "upload.prepare.start", "upload.prepare.status=", "upload.prepare.error=", "upload.prepare.validate.", "upload.prepare.target.", "upload.export.start", "upload.export.success", "upload.put.start", "upload.put.status=", "upload.put.success", "upload.put.failed category=", "upload.put.http.status=", "upload.put.error.domain=", "upload.put.error.code=", "upload.complete.status=", "upload.complete.http.success", "upload.complete.request.status=", "upload.complete.success", "upload.complete.error category=", "upload.counter.uploaded=", "upload.outcome="]
        return prefixes.contains { event.hasPrefix($0) } && !event.contains("/") && !event.contains("\\")
    }
    func loadConnection() throws -> ConnectorConnection {
        refreshPreferences()
        let preferences = ConnectionPreferences(server: server, user: user)
        guard let password = try preferences.loadPassword(), !password.isEmpty else { throw UploadError.invalidConfiguration }
        return try ConnectorConnection(server: server, user: user, password: password)
    }
    func importGuardFailure() -> String? {
        refreshPreferences()
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        let hasPassword = ((try? ConnectionPreferences(server: server, user: user).loadPassword()) ?? nil).map { !$0.isEmpty } ?? false
        let connectionValidated = defaults.bool(forKey: ImportGuard.validatedKey)
        // A persisted target belongs to the currently validated connection. Older
        // installations may not have written targetValidated; preserve the
        // one-time target choice instead of asking the user to select it again.
        let targetConfirmed = defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey)
            || (connectionValidated && !targetPath.isEmpty)
        if targetConfirmed && !defaults.bool(forKey: TargetDirectoryPreferences.confirmedKey) {
            defaults.set(true, forKey: TargetDirectoryPreferences.confirmedKey)
        }
        let state = ImportConfigurationState(serverSet: !server.isEmpty, userSet: !user.isEmpty, passwordAvailable: hasPassword,
            connectionValidated: connectionValidated, targetSet: !targetPath.isEmpty,
            targetConfirmed: targetConfirmed)
        return ImportGuard.failure(for: state)
    }
}

@MainActor
private final class VisualLibraryModel: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var albums: [AlbumInventory] = []
    @Published var selectedAssetIDs: Set<String> = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var loading = false
    @Published var authorizationMessage: String?
    @Published var diagnosticLog: [String] = []
    let imageManager = PHCachingImageManager()
    private let logger = Logger(subsystem: "de.applephotosconnector.macagent", category: "PhotoGrid")
    private let persistentLogger: DebugFileLogger
    private var selectionSourceId: String?

    init() {
        let defaults = UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard
        persistentLogger = DebugFileLogger(enabled: defaults.bool(forKey: UploadPreferences.debugModeKey))
    }

    private func authorizationName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func log(_ message: String) {
        diagnosticLog.append(message)
        logger.info("\(message, privacy: .public)")
        persistentLogger.log(message)
    }

    func load() async {
        log("visual_library.load.start")
        guard !loading else { log("gallery.load.skipped reason=already_loading"); return }
        loading = true
        defer { loading = false }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log("photos.authorization.status=\(authorizationName(status))")
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            log("photos.authorization.status=\(authorizationName(status))")
        }
        guard PhotoKitBrowsingEligibility.allows(authorized: status == .authorized || status == .limited) else {
            log("gallery.load.skipped reason=authorization_\(authorizationName(status))")
            authorizationMessage = status == .restricted ? "Der Fotozugriff ist eingeschränkt." : "Bitte erlaube den Fotozugriff in den Systemeinstellungen."
            log("photos.fetch.skipped authorization=\(status.rawValue)")
            return
        }
        authorizationMessage = nil
        log("photos.fetch.authorization=\(authorizationName(status))")
        log("photos.fetch.authorization=\(authorizationName(status))")
        log("photos.fetch.start")
        let fetched = PHAsset.fetchAssets(with: nil)
        log("photos.fetch.count=\(fetched.count)")
        log("photos.fetch.success")
        var values: [PHAsset] = []
        values.reserveCapacity(fetched.count)
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
            // Audio remains supported internally by the inventory format, but
            // is intentionally excluded from the user-facing import picker.
            if asset.mediaType == .image || asset.mediaType == .video { values.append(asset) }
        }
        assets = values
        log("photos.ui.count=\(assets.count)")
        log("photos.fetch.end")
        log("thumbnails.requested=0")
        log("albums.fetch.start")
        if let document = try? await PhotoLibraryScanner().scanAlbums() {
            albums = document.albums
            log("albums.fetch.count=\(document.albums.count)")
            log("albums.ui.count=\(albums.count)")
        }
        log("albums.fetch.end")
        if let source = try? PhotoSourceStore.applicationStore().loadOrCreate() {
            selectionSourceId = source.sourceId.uuidString
            let persisted = PhotoSelectionPreferences.load(sourceId: source.sourceId.uuidString, defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard)
            let assetIds = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, assetIdentity($0)) })
            let restored = PhotoSelectionRestorer.reconcile(persisted, assetIdentitiesByLocal: assetIds, albums: albums)
            selectedAssetIDs = restored.assetIdentities
            selectedAlbumIDs = restored.albumIdentities
            PhotoSelectionPreferences.save(restored, sourceId: source.sourceId.uuidString, defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard)
        }
    }

    func assetIdentity(_ asset: PHAsset) -> String {
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])[asset.localIdentifier]
        if case .success(let cloud) = mapping, let encoded = CloudIdentifierCodec.encode(cloud) { return "cloud:\(encoded)" }
        return "local:\(asset.localIdentifier)"
    }

    func toggleAlbum(_ album: AlbumInventory) {
        guard album.kind == "album" else { return }
        let identity = PhotoSelectionIdentity.album(album)
        if selectedAlbumIDs.contains(identity) {
            selectedAlbumIDs.remove(identity)
        } else {
            selectedAlbumIDs.insert(identity)
        }
        let albumAssets = Set(album.assetIdentities.compactMap { local in
            assets.first(where: { $0.localIdentifier == local }).map(assetIdentity)
        })
        if selectedAlbumIDs.contains(identity) { selectedAssetIDs.formUnion(albumAssets) }
        else { selectedAssetIDs.subtract(albumAssets) }
        saveSelection()
    }

    func toggleAsset(_ asset: PHAsset) {
        let identity = assetIdentity(asset)
        if selectedAssetIDs.contains(identity) { selectedAssetIDs.remove(identity) }
        else { selectedAssetIDs.insert(identity) }
        saveSelection()
    }

    func saveSelection() {
        guard let source = selectionSourceId else { return }
        PhotoSelectionPreferences.save(PhotoSelectionState(assetIdentities: selectedAssetIDs, albumIdentities: selectedAlbumIDs), sourceId: source, defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard)
    }
    func selectAll() { selectedAssetIDs = Set(assets.map { assetIdentity($0) }); saveSelection() }
    func clearSelection() { selectedAssetIDs.removeAll(); selectedAlbumIDs.removeAll(); saveSelection() }

    var selectedAlbums: [AlbumInventory] {
        albums.filter { selectedAlbumIDs.contains(PhotoSelectionIdentity.album($0)) }
    }
}

private struct InventoryView: View {
    @StateObject private var model = InventoryModel()
    @StateObject private var visual = VisualLibraryModel()
    @State private var visualMode = 0
    @AppStorage(L10n.languageKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var language = L10n.currentLanguage(defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard)
    @State private var albumSyncRunning = false
    @State private var albumSyncStatus = "Noch kein Album-Abgleich gestartet."
    @Environment(\.openSettings) private var openSettings
    @AppStorage(UploadPreferences.debugModeKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var debugMode = false
    @AppStorage(UploadPreferences.retransferMissingKey, store: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)) private var retransferMissing = false
    @State private var persistentDebugLogger: DebugFileLogger?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("title")).font(.title)
            Text(L10n.text("subtitle"))
            HStack {
                /* Photo access and inventory are available from the app menu. */
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isErrorStatus ? .red : .primary)
                    .fontWeight(isErrorStatus ? .bold : .regular)
            }
            UploadTargetSummaryView(server: model.server, user: model.user, targetPath: model.targetPath)
            Divider()
            Button(uploadButtonTitle) {
                model.debugLog = []
                model.logUploadEvent("upload.ui.requested selectedAssets=\(visual.selectedAssetIDs.count) selectedAlbums=\(visual.selectedAlbumIDs.count)")
                model.logUploadEvent("upload.ui.reinventory=\(retransferMissing)")
                let selectionSnapshot = Set(visual.selectedAssetIDs)
                model.logUploadEvent("upload.snapshot assets=\(selectionSnapshot.count) albums=\(visual.selectedAlbumIDs.count)")
                if let failure = model.importGuardFailure() {
                    model.logUploadEvent("upload.start.skipped reason=guard")
                    model.status = failure
                    model.debugLog.append("Import guard · blocked · reason=\(failure)")
                    return
                }
                model.scanning = true
                model.uploadProgress = nil
                model.uploadInProgress = true
                model.status = L10n.text("uploadRunning")
                model.uploadTask = Task {
                    defer { model.scanning = false; model.uploadInProgress = false }
                    do {
                        let connection = try model.loadConnection()
                        guard !selectionSnapshot.isEmpty else {
                            model.logUploadEvent("upload.start.skipped reason=empty-selection")
                            throw NSError(domain: "ApplePhotosConnector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bitte mindestens ein Foto oder Album auswählen."])
                        }
                        let result = try await model.scanner.scan(candidates: selectionSnapshot)
                        model.logUploadEvent("inventory.candidates assets=\(result.summary.totalAssets)")
                        guard result.summary.totalAssets == selectionSnapshot.count else {
                            model.logUploadEvent("inventory.payload.invalid expected=\(selectionSnapshot.count) actual=\(result.summary.totalAssets)")
                            throw NSError(domain: "ApplePhotosConnector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Die Auswahl konnte nicht vollständig inventarisiert werden."])
                        }
                        model.json = result.json
                        var uploadJSON = result.json
                        uploadJSON = try InventoryJSON.filteringByStableIdentity(uploadJSON, allowed: visual.selectedAssetIDs).json
                        model.debugLog.append("Photo inventory ready · assets=\(result.summary.totalAssets) · endpoint=/index.php/apps/apple_photos_connector/api/v1/inventory")
                        model.debugLog.append("Inventory request pending · retransferMissing=\(UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)?.bool(forKey: UploadPreferences.retransferMissingKey) ?? false)")
                        let summary = try await model.uploader.run(json: uploadJSON, connection: connection, retransferMissing: retransferMissing, progress: { progress in
                            Task { @MainActor in model.uploadProgress = progress }
                        }, debug: { message in
                            Task { @MainActor in
                                model.debugLog.append(message)
                                model.logUploadEvent(message)
                            }
                        })
                        model.status = uploadSummary(summary)
                    } catch { model.status = "Error: \(L10n.text("upload"))" }
                }
            }.disabled(model.scanning)
            if let progress = model.uploadProgress {
                GroupBox(L10n.text("uploadProgress")) {
                    VStack(alignment: .leading, spacing: 6) {
                        let fraction = progress.total == 0 ? 1.0 : Double(progress.completed) / Double(progress.total)
                        ProgressView(value: fraction)
                        if let filename = progress.filename {
                            Text(progress.failed ? L10n.text("failed") + ": \(filename)" : L10n.text("file") + ": \(filename)")
                                .foregroundStyle(progress.failed ? .red : .primary)
                        } else {
                            Text(progress.total == 0 ? L10n.text("noNewUploads") : L10n.text("preparingUploads"))
                        }
                        Text(L10n.format("uploadsProgressFormat", progress.completed, progress.total))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Picker(L10n.text("view"), selection: $visualMode) {
                Text(L10n.text("photos")).tag(0)
                Text(L10n.text("albums")).tag(1)
            }.pickerStyle(.segmented)
            if visualMode == 0 {
                PhotoThumbnailGrid(model: visual)
            } else {
                AlbumGrid(model: visual)
            }
            if let message = visual.authorizationMessage {
                Text(message).foregroundStyle(.red).fontWeight(.semibold)
            } else if !visual.loading && visualMode == 0 && visual.assets.isEmpty {
                Text(L10n.text("noPhotos")).foregroundStyle(.secondary)
            }
            let visibleAlbumCount = visual.albums.filter { $0.kind == "album" }.count
            Text("Fotos: \(visual.assets.count) · Alben: \(visibleAlbumCount) · Ausgewählt: \(visual.selectedAssetIDs.count)")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("selectAll")) { visual.selectAll() }
                Button(L10n.text("clearSelection")) { visual.clearSelection() }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    let selected = visual.selectedAlbums
                    Text("\(L10n.text("albums")): \(selected.isEmpty ? "—" : selected.map(\.name).joined(separator: ", "))")
                    let membershipCount = selected.reduce(0) { $0 + $1.assetIdentities.count }
                    Text(L10n.format("membershipsNotice", membershipCount, L10n.text("notDeletedNotice")))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("albumSync")) {
                        guard !albumSyncRunning else { return }
                        guard model.importGuardFailure() == nil else {
                            albumSyncStatus = "Album-Abgleich blockiert: Verbindung/Ziel nicht bestätigt."
                            return
                        }
                        albumSyncRunning = true
                        albumSyncStatus = L10n.text("albumsChecking")
                        Task {
                            defer { albumSyncRunning = false }
                            do {
                                let connection = try model.loadConnection()
                                _ = try await model.albums.run(scanner: model.scanner, connection: connection)
                                let result = try await model.albums.sync(scanner: model.scanner, connection: connection)
                                let checked = result.albumsCreated + result.albumsReused
                                await MainActor.run { albumSyncStatus = L10n.format("albumSyncResult", checked, L10n.text(checked == 1 ? "albumOne" : "albumMany")) }
                            } catch {
                                await MainActor.run { albumSyncStatus = "Album-Abgleich fehlgeschlagen: \(error.localizedDescription)" }
                            }
                        }
                    }
                    .disabled(albumSyncRunning || model.scanning)
                    Text(albumSyncStatus)
                        .foregroundStyle(albumSyncStatus.lowercased().contains("fehlgeschlagen") ? .red : .primary)
                }
            } label: {
                Text(L10n.text("albumSyncGroup")).font(.headline)
            }
        }
        .id(language)
        .onAppear {
            persistentDebugLogger?.log("gallery.load.requested")
            persistentDebugLogger = DebugFileLogger(enabled: debugMode)
            model.refreshPreferences()
            let guardFailure = model.importGuardFailure()
            // Local PhotoKit browsing depends only on Photos authorization,
            // not on the Nextcloud upload guard or target validation.
            Task { await visual.load() }
            if guardFailure != nil {
                DispatchQueue.main.async { openSettings() }
            }
        }
        .onChange(of: debugMode) { _, enabled in
            persistentDebugLogger = DebugFileLogger(enabled: enabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestPhotoAccess)) { _ in
            guard !model.scanning else { return }
            model.scanning = true; model.json = ""; model.status = "Fotozugriff prüfen und Fotos einlesen …"
            if debugMode {
                model.debugLog = ["Lokale PhotoKit-Inventarisierung gestartet · kein Serverrequest"]
            }
            Task { defer { model.scanning = false }; do { let result = try await model.scanner.scan(); model.json = result.json } catch { model.status = "Fehler beim Einlesen der Fotos" } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .targetDirectoryChanged)) { _ in
            model.refreshPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionStateChanged)) { _ in
            model.refreshPreferences()
            persistentDebugLogger?.log("gallery.load.requested reason=connection_state_changed")
            Task { await visual.load() }
        }
        .tint(.nextcloudBlue)
        .padding(20)
        .frame(minWidth: 900, minHeight: 650)
        .sheet(isPresented: $model.uploadInProgress) {
            UploadProgressSheet(progress: model.uploadProgress, debugLog: model.debugLog, debugEnabled: debugMode) { model.uploadTask?.cancel() }
        }
    }

    private var isErrorStatus: Bool {
        let value = model.status.lowercased()
        // A completed run may report a zero count ("0 fehlgeschlagen") as
        // part of its normal summary. Only actual failures should be red.
        if value.contains("erfolgreich") || value.contains("fehler: 0") ||
            value.contains("fehlgeschlagen: 0") || value.contains("0 fehlgeschlagen") ||
            value.contains("0 failed") {
            return false
        }
        return value.contains("fehler") || value.contains("fehlgeschlagen") || value.contains("konnte nicht") || value.contains("ungültig") || value.contains("verweigert") || value.contains("nicht erreichbar")
    }

    private var uploadButtonTitle: String {
        let selected = visual.assets.filter { visual.selectedAssetIDs.contains(visual.assetIdentity($0)) }
        let photos = selected.filter { $0.mediaType == .image }.count
        let videos = selected.filter { $0.mediaType == .video }.count
        let albums = visual.selectedAlbums.count
        var parts = [L10n.text("upload")]
        if photos > 0 { parts.append("\(photos) Fotos") }
        if videos > 0 { parts.append("\(videos) Videos") }
        if albums > 0 { parts.append("\(albums) Alben") }
        return parts.joined(separator: " · ")
    }


    private func uploadSummary(_ summary: UploadCoordinator.RunSummary) -> String {
        var parts: [String] = [L10n.text("uploadComplete")]
        if summary.uploadedImages > 0 { parts.append(L10n.format("transferredCount", summary.uploadedImages, L10n.text(summary.uploadedImages == 1 ? "photoCountOne" : "photoCountMany"))) }
        if summary.uploadedVideos > 0 { parts.append(L10n.format("transferredCount", summary.uploadedVideos, L10n.text(summary.uploadedVideos == 1 ? "videoCountOne" : "videoCountMany"))) }
        return parts.joined(separator: " · ")
    }
}

struct UploadTargetSummaryView: View {
    let server: String
    let user: String
    let targetPath: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("uploadTarget")).font(.headline)
            Text("\(L10n.text("server")): \(server.isEmpty ? L10n.text("noServerConfigured") : server)")
            Text("\(L10n.text("configuredUser")): \(user.isEmpty ? L10n.text("noUserConfigured") : user)")
            Text("\(L10n.text("target")): \(targetPath.isEmpty ? L10n.text("targetNotSelected") : targetPath)")
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UploadProgressSheet: View {
    let progress: UploadCoordinator.Progress?
    let debugLog: [String]
    let debugEnabled: Bool
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("uploadingOriginals")).font(.headline)
            if let progress {
                ProgressView(value: progress.total == 0 ? 1 : Double(progress.completed) / Double(progress.total))
                Text(progress.filename.map { "Datei: \($0)" } ?? "Upload wird vorbereitet …")
                Text(L10n.format("uploadsProgressFormat", progress.completed, progress.total))
                    .foregroundStyle(.secondary)
            } else { ProgressView(); Text(L10n.text("preparingUploads")) }
            if debugEnabled { GroupBox(L10n.text("debug")) {
                ScrollView {
                    Text(debugLog.isEmpty ? L10n.text("noNetworkActivity") : debugLog.joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100, maxHeight: 220)
            } }
            HStack { Spacer(); Button(L10n.text("cancelUpload"), role: .cancel) { cancel(); dismiss() } }
        }.padding(24).frame(width: 380)
    }
}

private struct PhotoThumbnailGrid: View {
    @ObservedObject var model: VisualLibraryModel
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.assets, id: \.localIdentifier) { asset in
                    let identity = model.assetIdentity(asset)
                    Button {
                        model.toggleAsset(asset)
                    } label: {
                        AssetThumbnail(asset: asset, manager: model.imageManager)
                            .overlay(alignment: .topTrailing) {
                                if model.selectedAssetIDs.contains(identity) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(4)
                                }
                            }
                    }.buttonStyle(.plain)
                }
            }.padding(4)
        }.frame(minHeight: 180)
    }
}

private struct AlbumGrid: View {
    @ObservedObject var model: VisualLibraryModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.albums.filter { $0.kind == "album" }, id: \.localIdentifier) { album in
                    let identity = PhotoSelectionIdentity.album(album)
                    Button {
                        model.toggleAlbum(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let local = album.assetIdentities.first,
                               let asset = model.assets.first(where: { $0.localIdentifier == local }) {
                                AssetThumbnail(asset: asset, manager: model.imageManager)
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).frame(height: 92)
                            }
                            Text(album.name).lineLimit(1)
                            let albumAssets = album.assetIdentities.compactMap { local in model.assets.first { $0.localIdentifier == local } }
                            let imageCount = albumAssets.filter { $0.mediaType == .image }.count
                            let videoCount = albumAssets.filter { $0.mediaType == .video }.count
                            Text(mediaSummary(images: imageCount, videos: videoCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(model.selectedAlbumIDs.contains(identity) ? Color.nextcloudBlue.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }.padding(4)
        }.frame(minHeight: 180)
    }

    private func mediaSummary(images: Int, videos: Int) -> String {
        var parts: [String] = []
        if images > 0 { parts.append(L10n.count(images, singularKey: "photoCountOne", pluralKey: "photoCountMany")) }
        if videos > 0 { parts.append(L10n.count(videos, singularKey: "videoCountOne", pluralKey: "videoCountMany")) }
        return parts.isEmpty ? "0 \(L10n.text("media"))" : parts.joined(separator: " · ")
    }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: NSImage?
    private let logger = Logger(subsystem: "de.applephotosconnector.macagent", category: "PhotoGrid")

    var body: some View {
        Group {
            if let image {
                ZStack(alignment: .bottomLeading) {
                    Image(nsImage: image).resizable().scaledToFill()
                    if asset.mediaType == .video {
                        Label(Self.duration(asset.duration), systemImage: "play.fill")
                            .font(.caption2).padding(4).foregroundStyle(.white)
                            .background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                }
            }
            else { RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).overlay { ProgressView() } }
        }
        .frame(height: 92).clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            logger.info("photos.thumbnail.request")
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            await withCheckedContinuation { continuation in
                manager.requestImage(for: asset, targetSize: CGSize(width: 180, height: 180), contentMode: .aspectFill, options: options) { value, _ in
                    image = value
                    if value == nil { logger.info("photos.thumbnail.failure") }
                    else { logger.info("photos.thumbnail.success") }
                    logger.info("thumbnails.completed")
                    continuation.resume()
                }
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        MediaPresentation.durationString(seconds)
    }
}
