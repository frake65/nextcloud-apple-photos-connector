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
final class VisualLibraryModel: ObservableObject {
    @Published private(set) var assetCount = 0
    @Published private(set) var generation = UUID()
    @Published private(set) var albumDetails: [GalleryAlbum] = []
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published private(set) var selectedPhotos = 0
    @Published private(set) var selectedVideos = 0
    @Published var loading = false
    @Published private(set) var selectionBusy = false
    @Published var authorizationMessage: String?
    let library: any GalleryLibraryProviding
    let thumbnails: GalleryThumbnailLoader
    private let gate: SettingsWorkGate
    private var selectionSourceId: String?
    private var manuallySelectedAssetIDs: Set<String> = []
    private var albumMembers: [String: Set<String>] = [:]
    private(set) var loadedAlbums = false
    private var selectionTask: Task<Void, Never>?
    private let loadRequests: CoalescingWorkRequest
    private let albumRequests: CoalescingWorkRequest

    init(library: any GalleryLibraryProviding = GalleryLibrary(),
         thumbnails: GalleryThumbnailLoader = GalleryThumbnailLoader(),
         gate: SettingsWorkGate = .shared) {
        self.library = library; self.thumbnails = thumbnails; self.gate = gate
        loadRequests = CoalescingWorkRequest(gate: gate)
        albumRequests = CoalescingWorkRequest(gate: gate)
    }

    var albums: [AlbumInventory] { albumDetails.map(\.inventory) }
    var selectedAlbums: [AlbumInventory] {
        albums.filter { selectedAlbumIDs.contains(PhotoSelectionIdentity.album($0)) }
    }
    var selectedMembershipCount: Int {
        albumDetails.filter { selectedAlbumIDs.contains(PhotoSelectionIdentity.album($0.inventory)) }
            .reduce(0) { $0 + $1.photos + $1.videos }
    }

    func requestLoad() {
        loadRequests.request { [weak self] in await self?.load() }
    }

    private func load() async {
        do {
            try await gate.checkpoint()
            loading = true
            defer { loading = false }
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            guard status == .authorized || status == .limited else {
                authorizationMessage = status == .restricted ? "Der Fotozugriff ist eingeschränkt." : "Bitte erlaube den Fotozugriff in den Systemeinstellungen."
                return
            }
            try await openSource()
        } catch is CancellationError { }
        catch { authorizationMessage = "Galerie konnte nicht geladen werden: \(error.localizedDescription)" }
    }

    // Separate entry point also lets tests exercise the real load path without
    // requesting Photos permission. It performs no cell/identity/image work.
    func openSource(persisted: PhotoSelectionState? = nil) async throws {
        await selectionTask?.value
        if let albumTask { _ = try? await albumTask.value }
        try await gate.checkpoint()
        let count = try await library.open()
        assetCount = count
        generation = UUID()
        thumbnails.clearCache()
        authorizationMessage = nil
        loadedAlbums = false
        albumDetails = []
        if let persisted { restore(persisted) }
        else if selectionSourceId == nil {
            let source = try PhotoSourceStore.applicationStore().loadOrCreate()
            selectionSourceId = source.sourceId.uuidString
            restore(PhotoSelectionPreferences.load(sourceId: source.sourceId.uuidString, defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard))
        }
        GalleryDebug.log("gallery.initial.ready count=\(count)")
        // Resolve only an existing selection, after publishing the gallery.
        // Never reconcile against the partial set of displayed cells.
        if !manuallySelectedAssetIDs.isEmpty || !selectedAlbumIDs.isEmpty {
            performSelection { model in
                if !model.selectedAlbumIDs.isEmpty {
                    try await model.ensureAlbums()
                    try await model.resolveSelectedAlbumMembers()
                }
                try await model.refreshEffectiveSelectionCounts()
            }
        }
    }

    func restore(_ state: PhotoSelectionState) {
        manuallySelectedAssetIDs = state.manuallySelectedAssetIDs
        selectedAlbumIDs = state.selectedAlbumIDs
        albumMembers.removeAll()
        selectedAssetIDs = manuallySelectedAssetIDs
    }

    func requestAlbums() {
        albumRequests.request { [weak self] in
            guard let self else { return }
            do { try await ensureAlbums() }
            catch is CancellationError { }
            catch { authorizationMessage = "Alben konnten nicht geladen werden: \(error.localizedDescription)" }
        }
    }

    private var albumTask: Task<[GalleryAlbum], Error>?
    private func ensureAlbums() async throws {
        if loadedAlbums { return }
        let requestedGeneration = generation
        let task: Task<[GalleryAlbum], Error>
        if let existing = albumTask { task = existing }
        else {
            let library = library
            task = Task { try await library.albumCatalog() }
            albumTask = task
        }
        do {
            let details = try await task.value
            guard requestedGeneration == generation else { return }
            albumDetails = details
            loadedAlbums = true
            albumTask = nil
        } catch { albumTask = nil; throw error }
    }

    private func performSelection(_ operation: @escaping @MainActor (VisualLibraryModel) async throws -> Void) {
        guard !selectionBusy else { return }
        selectionBusy = true
        selectionTask = Task {
            defer { selectionBusy = false; selectionTask = nil }
            do {
                try await gate.checkpoint()
                try await operation(self)
                saveSelection()
            } catch is CancellationError { }
            catch { authorizationMessage = "Auswahl konnte nicht aufgelöst werden: \(error.localizedDescription)" }
        }
    }

    func toggleAsset(_ asset: GalleryAsset) {
        performSelection { model in
            let identity = asset.identity
            let localFallback = "local:\(asset.localIdentifier)"
            let selectedThroughAlbum = model.albumMembers.values.contains { $0.contains(identity) || $0.contains(localFallback) }
            guard !selectedThroughAlbum else { return }
            if model.manuallySelectedAssetIDs.contains(identity) || model.manuallySelectedAssetIDs.contains(localFallback) {
                model.manuallySelectedAssetIDs.remove(identity)
                model.manuallySelectedAssetIDs.remove(localFallback)
            } else { model.manuallySelectedAssetIDs.insert(identity) }
            model.rebuildEffectiveSelection()
            try await model.refreshEffectiveSelectionCounts()
        }
    }

    func toggleAlbum(_ album: AlbumInventory) {
        performSelection { model in
            let members = try await model.library.albumAssets(album.localIdentifier)
            let identity = PhotoSelectionIdentity.album(album)
            if model.selectedAlbumIDs.contains(identity) {
                model.selectedAlbumIDs.remove(identity)
                model.albumMembers.removeValue(forKey: identity)
            } else {
                model.selectedAlbumIDs.insert(identity)
                model.albumMembers[identity] = members.identities
            }
            model.rebuildEffectiveSelection()
            try await model.refreshEffectiveSelectionCounts()
        }
    }

    func selectAll() {
        performSelection { model in
            let all = try await model.library.resolveAll()
            model.manuallySelectedAssetIDs = all.identities
            model.rebuildEffectiveSelection()
            model.selectedPhotos = all.photos; model.selectedVideos = all.videos
        }
    }

    func clearSelection() {
        guard !selectionBusy else { return }
        manuallySelectedAssetIDs.removeAll(); selectedAssetIDs.removeAll(); selectedAlbumIDs.removeAll(); albumMembers.removeAll()
        selectedPhotos = 0; selectedVideos = 0
        saveSelection()
    }

    private func resolveSelectedAlbumMembers() async throws {
        for album in selectedAlbums where albumMembers[PhotoSelectionIdentity.album(album)] == nil {
            albumMembers[PhotoSelectionIdentity.album(album)] = try await library.albumAssets(album.localIdentifier).identities
        }
        rebuildEffectiveSelection()
    }

    private func rebuildEffectiveSelection() {
        selectedAssetIDs = manuallySelectedAssetIDs.union(albumMembers.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }

    private func refreshEffectiveSelectionCounts() async throws {
        let selected = try await library.resolveSelection(selectedAssetIDs)
        // Missing/inaccessible identities remain selected. The unchanged upload
        // scanner will explicitly reject an incomplete snapshot.
        selectedAssetIDs = selected.identities
        selectedPhotos = selected.photos
        selectedVideos = selected.videos
    }

    func uploadSnapshot() -> Set<String> { selectedAssetIDs }

    func resolveUploadSnapshot(_ frozen: Set<String>) async throws -> Set<String> {
        // A local fallback may have gained a cloud identity since selection.
        // Resolve the frozen membership, never the subsequently edited UI set.
        try await library.resolveSelection(frozen).identities
    }

    func saveSelection() {
        guard let source = selectionSourceId else { return }
        PhotoSelectionPreferences.save(PhotoSelectionState(manuallySelectedAssetIDs: manuallySelectedAssetIDs, selectedAlbumIDs: selectedAlbumIDs), sourceId: source, defaults: UserDefaults(suiteName: ConnectionPreferences.preferencesSuite) ?? .standard)
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
                guard !model.scanning, !visual.selectionBusy else { return }
                let selectionSnapshot = visual.uploadSnapshot()
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
                        try await SettingsWorkGate.shared.checkpoint()
                        // A pending start must validate the settings that exist
                        // after resumption, before capturing its run snapshot.
                        if let failure = model.importGuardFailure() {
                            throw UploadError.diagnostic(failure)
                        }
                        let connection = try model.loadConnection()
                        let targetRoot = TargetDirectoryPreferences().path
                        let runRetransferMissing = retransferMissing
                        guard !selectionSnapshot.isEmpty else {
                            model.logUploadEvent("upload.start.skipped reason=empty-selection")
                            throw NSError(domain: "ApplePhotosConnector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bitte mindestens ein Foto oder Album auswählen."])
                        }
                        let selectionSnapshot = try await visual.resolveUploadSnapshot(selectionSnapshot)
                        let result = try await model.scanner.scan(candidates: selectionSnapshot)
                        model.logUploadEvent("inventory.candidates assets=\(result.summary.totalAssets)")
                        guard result.summary.totalAssets == selectionSnapshot.count else {
                            model.logUploadEvent("inventory.payload.invalid expected=\(selectionSnapshot.count) actual=\(result.summary.totalAssets)")
                            throw NSError(domain: "ApplePhotosConnector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Die Auswahl konnte nicht vollständig inventarisiert werden."])
                        }
                        model.json = result.json
                        var uploadJSON = result.json
                        uploadJSON = try InventoryJSON.filteringByStableIdentity(uploadJSON, allowed: selectionSnapshot).json
                        model.debugLog.append("Photo inventory ready · assets=\(result.summary.totalAssets) · endpoint=/index.php/apps/apple_photos_connector/api/v1/inventory")
                        model.debugLog.append("Inventory request pending · retransferMissing=\(runRetransferMissing)")
                        let summary = try await model.uploader.run(json: uploadJSON, connection: connection, targetRoot: targetRoot, retransferMissing: runRetransferMissing, progress: { progress in
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
            }.disabled(model.scanning || visual.selectionBusy || visual.loading)
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
                AlbumGrid(model: visual).id(visual.generation)
            }
            if let message = visual.authorizationMessage {
                Text(message).foregroundStyle(.red).fontWeight(.semibold)
            } else if !visual.loading && visualMode == 0 && visual.assetCount == 0 {
                Text(L10n.text("noPhotos")).foregroundStyle(.secondary)
            }
            let visibleAlbumCount = visual.loadedAlbums ? String(visual.albums.count) : "—"
            Text("Fotos: \(visual.assetCount) · Alben: \(visibleAlbumCount) · Ausgewählt: \(visual.selectedAssetIDs.count)")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("selectAll")) { visual.selectAll() }.disabled(visual.selectionBusy || visual.loading)
                Button(L10n.text("clearSelection")) { visual.clearSelection() }.disabled(visual.selectionBusy)
                if visual.selectionBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    let selected = visual.selectedAlbums
                    Text("\(L10n.text("albums")): \(selected.isEmpty ? "—" : selected.map(\.name).joined(separator: ", "))")
                    let membershipCount = visual.selectedMembershipCount
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
                                try await SettingsWorkGate.shared.checkpoint()
                                if let failure = model.importGuardFailure() {
                                    throw UploadError.diagnostic(failure)
                                }
                                let connection = try model.loadConnection()
                                _ = try await model.albums.run(scanner: model.scanner, connection: connection)
                                let result = try await model.albums.sync(scanner: model.scanner, connection: connection,
                                    selectedAlbumIDs: visual.selectedAlbumIDs, selectedAssetIDs: visual.uploadSnapshot())
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
            if guardFailure != nil {
                // Fetching the Photos library is CPU-intensive.  On a first
                // launch, put the Settings window ahead of that work so the
                // user can enter connection credentials without contention.
                SettingsWindowLifecycle.shared.prepareToOpen()
                DispatchQueue.main.async { openSettings() }
            }
            visual.requestLoad()
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
            persistentDebugLogger?.log("gallery.load.deferred reason=connection_state_changed")
            visual.requestLoad()
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
        let photos = visual.selectedPhotos
        let videos = visual.selectedVideos
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
                ForEach(0..<model.assetCount, id: \.self) { index in
                    GalleryCell(model: model, index: index)
                }
            }
            .padding(4)
            .id(model.generation)
        }.frame(minHeight: 180)
    }
}

private struct GalleryCell: View {
    @ObservedObject var model: VisualLibraryModel
    let index: Int
    @State private var asset: GalleryAsset?

    var body: some View {
        Group {
            if let asset {
                let selected = model.selectedAssetIDs.contains(asset.identity) || model.selectedAssetIDs.contains("local:\(asset.localIdentifier)")
                GeometryReader { geometry in
                Button { model.toggleAsset(asset) } label: {
                    ZStack(alignment: .topTrailing) {
                        AssetThumbnail(asset: asset, loader: model.thumbnails)
                            .frame(width: geometry.size.width, height: 92)
                            .clipped()
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, .blue)
                                .padding(6)
                                .zIndex(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .frame(width: geometry.size.width, height: 92)
                }
                .buttonStyle(.plain)
                .disabled(model.selectionBusy || model.loading)
                .zIndex(selected ? 1 : 0)
                .id(asset.localIdentifier)
                .frame(width: geometry.size.width, height: 92)
                }
                .frame(height: 92)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2))
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
            }
        }
        .task {
            do {
                let value = try await model.library.cell(at: index)
                try Task.checkCancellation()
                asset = value
            } catch { }
        }
        .onDisappear { asset = nil }
    }
}

private struct AlbumGrid: View {
    @ObservedObject var model: VisualLibraryModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.albumDetails, id: \.inventory.localIdentifier) { detail in
                    let album = detail.inventory
                    let identity = PhotoSelectionIdentity.album(album)
                    Button { model.toggleAlbum(album) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            AlbumCover(model: model, local: detail.cover)
                            Text(album.name).lineLimit(1)
                            Text(mediaSummary(images: detail.photos, videos: detail.videos))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(model.selectedAlbumIDs.contains(identity) ? Color.nextcloudBlue.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.selectionBusy || model.loading)
                }
            }.padding(4)
        }.frame(minHeight: 180)
        .onAppear { model.requestAlbums() }
    }

    private func mediaSummary(images: Int, videos: Int) -> String {
        var parts: [String] = []
        if images > 0 { parts.append(L10n.count(images, singularKey: "photoCountOne", pluralKey: "photoCountMany")) }
        if videos > 0 { parts.append(L10n.count(videos, singularKey: "videoCountOne", pluralKey: "videoCountMany")) }
        return parts.isEmpty ? "0 \(L10n.text("media"))" : parts.joined(separator: " · ")
    }
}

private struct AlbumCover: View {
    @ObservedObject var model: VisualLibraryModel
    let local: String?
    @State private var asset: GalleryAsset?
    var body: some View {
        Group {
            if let asset { AssetThumbnail(asset: asset, loader: model.thumbnails) }
            else { RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).frame(height: 92) }
        }
        .task(id: local) {
            asset = nil
            guard let local else { return }
            do {
                let value = try await model.library.asset(local: local)
                try Task.checkCancellation()
                asset = value
            } catch { }
        }
        .onDisappear { asset = nil }
    }
}

private struct AssetThumbnail: View {
    let asset: GalleryAsset
    let loader: GalleryThumbnailLoader
    @State private var image: NSImage?
    @State private var pointSize = CGSize(width: 98, height: 92)
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                ZStack(alignment: .bottomLeading) {
                    Image(nsImage: image).resizable().scaledToFill()
                    if asset.isVideo {
                        Label(MediaPresentation.durationString(asset.duration), systemImage: "play.fill")
                            .font(.caption2).padding(4).foregroundStyle(.white)
                            .background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                }
            } else { RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).overlay { ProgressView() } }
        }
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: GalleryThumbnailSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(GalleryThumbnailSizeKey.self) { size in
            if size.width > 0, size.height > 0 { pointSize = size }
        }
        .task(id: "\(asset.localIdentifier)-\(pointSize.width)-\(pointSize.height)-\(displayScale)") {
            image = nil
            do {
                let value = try await loader.image(local: asset.localIdentifier, targetSize: pointSize, scale: displayScale)
                try Task.checkCancellation()
                image = value?.image
            } catch { }
        }
        .onDisappear { image = nil }
    }
}

private struct GalleryThumbnailSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 98, height: 92)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
