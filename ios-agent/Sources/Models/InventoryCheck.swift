import Foundation
import InventoryCore
import Photos

enum IOSImportDiagnostics {
    static let defaultsKey = "apc.debug.importDiagnostics"
    static var enabled: Bool {
        #if DEBUG
        let defaults = UserDefaults.standard
        return defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
        #else
        return false
        #endif
    }
    static func log(_ message: String) {
        #if DEBUG
        guard enabled else { return }
        print(message.hasPrefix("APC IMPORT ") ? message : "APC IMPORT \(message)")
        #endif
    }
    static func announceIfEnabled() {
        #if DEBUG
        if enabled { print("APC IMPORT DIAGNOSTICS ENABLED") }
        #endif
    }
    static func start(_ phase: String) -> ContinuousClock.Instant? {
        guard enabled else { return nil }
        let now = ContinuousClock.now; log("\(phase) START"); return now
    }
    static func finish(_ phase: String, started: ContinuousClock.Instant?, detail: String = "") {
        guard let started, enabled else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        log("\(phase) OK elapsed=\(started.duration(to: .now))\(suffix)")
    }
    static func failure(_ phase: String, started: ContinuousClock.Instant?, error: Error) {
        guard let started, enabled else { return }
        let category: String
        if let urlError = error as? URLError { category = "urlError=\(urlError.code.rawValue)" }
        else if case let UploadError.http(status) = error { category = "httpStatus=\(status)" }
        else { category = "error=\(String(describing: type(of: error)))" }
        log("\(phase) ERROR elapsed=\(started.duration(to: .now)) \(category)")
    }
}

struct InventoryAssetReply: Decodable, Equatable {
    enum State: String, Decodable { case new, known }
    let cloudIdentifier: String?
    let state: State
    let upload: UploadTicket?

    struct UploadTicket: Decodable, Equatable {
        let uploadId: String
        let assetId: String
    }
}

struct InventoryReply: Decodable, Equatable {
    struct Summary: Decodable, Equatable { let seen: Int; let new: Int; let known: Int }
    let runId: String
    let summary: Summary
    let assets: [InventoryAssetReply]
}

struct InventoryCheckResult {
    let selected: Int
    let known: Int
    let new: Int
    let assets: [AssetInventory]
    let states: [InventoryAssetReply.State]
}

struct IOSImportProgressAggregation: Sendable {
    private var jobs: [Int: (sent: Int64, total: Int64)] = [:]
    var sentBytes: Int64 { jobs.values.reduce(0) { $0 + $1.sent } }
    var totalBytes: Int64 { jobs.values.reduce(0) { $0 + $1.total } }
    var fraction: Double { totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 0 }
    mutating func update(job: Int, sent: Int64, total: Int64) { jobs[job] = (max(0, sent), max(0, total)) }
    mutating func remove(job: Int) { jobs.removeValue(forKey: job) }
    var activeFraction: Double { jobs.values.reduce(0) { $0 + ($1.total > 0 ? min(1, Double($1.sent) / Double($1.total)) : 0) } }
    var activeEntries: [(job: Int, sent: Int64, total: Int64)] { jobs.keys.sorted().compactMap { key in guard let value = jobs[key] else { return nil }; return (key, value.sent, value.total) } }
}

enum InventoryCheckError: LocalizedError {
    case noServerConfiguration, unavailableAsset, invalidSourceIdentifier, authenticationFailed, endpointUnavailable, network, invalidResponse

    var errorDescription: String? {
        switch self {
        case .noServerConfiguration: "Bitte zuerst eine gültige APC-Verbindung konfigurieren und testen."
        case .unavailableAsset: "Mindestens ein ausgewähltes Foto ist nicht mehr erreichbar. Bitte aktualisiere die Mediathek und wähle es erneut aus."
        case .invalidSourceIdentifier: "Die Source-ID muss eine gültige UUID sein."
        case .authenticationFailed: "Nextcloud hat die Anmeldung abgelehnt. Prüfe Benutzername und App-Passwort."
        case .endpointUnavailable: "Der APC-Inventar-Endpunkt ist nicht verfügbar. Prüfe, ob die APC-App aktiviert ist."
        case .network: "Der Server ist nicht erreichbar. Prüfe Netzwerk und HTTPS-Adresse."
        case .invalidResponse: "Der Server hat eine ungültige Inventarantwort zurückgegeben."
        }
    }
}

enum ImportRunState: String, Codable, Sendable {
    case assetProcessing
    case assetsComplete
    case albumSyncPending
    case completed
    case cancelled
    case failed
}

enum ImportAssetState: String, Codable, Sendable {
    case queued
    case needsPrepare
    case needsReconcile
    case completed
    case failed
}

struct ImportAccountReference: Codable, Equatable, Sendable {
    let serverBaseURL: String
    let username: String
}

struct PersistedImportAsset: Codable, Equatable, Sendable, Identifiable {
    let queueAssetID: UUID
    let stableIdentity: String
    let localIdentifier: String
    let cloudIdentifier: String?
    let mediaType: String
    let filenameHint: String?
    let captureDate: Date?
    var state: ImportAssetState
    var serverAssetID: String?
    var uploadID: String?
    var targetPath: String?
    var expectedBytes: Int64?
    var expectedSHA256: String?
    var lastConfirmedStep: String
    var retryCount: Int
    var lastErrorCode: String?
    var id: UUID { queueAssetID }
}

struct PersistedImportRun: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let localRunID: UUID
    let account: ImportAccountReference
    let sourceID: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: ImportRunState
    var serverRunID: String?
    let assetOrder: [UUID]
    var albumSyncPending: Bool
    var id: UUID { localRunID }
    var assets: [PersistedImportAsset]
}

struct ImportQueueDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var runs: [PersistedImportRun]
}

/// Small, versioned JSON persistence for recovery metadata. It intentionally
/// stores no credentials, task handles, progress values, or temporary paths.
actor ImportQueueStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var document: ImportQueueDocument

    init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ApplePhotosConnector", isDirectory: true)
        fileURL = directory.appendingPathComponent("import-queue-v1.json")
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode(ImportQueueDocument.self, from: data),
           loaded.schemaVersion == ImportQueueDocumentSchema.current {
            document = loaded
        } else {
            document = ImportQueueDocument(schemaVersion: ImportQueueDocumentSchema.current, runs: [])
        }
    }

    func allRuns() -> [PersistedImportRun] { document.runs }
    func recoverableRuns() -> [PersistedImportRun] {
        var seen = Set<String>()
        return document.runs
            .filter { $0.state == .assetProcessing || $0.state == .assetsComplete || $0.state == .albumSyncPending }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert("\($0.account.serverBaseURL)|\($0.account.username)|\($0.sourceID.uuidString)").inserted }
    }
    func save(_ run: PersistedImportRun) throws { upsert(run); try persist() }
    func markAsset(runID: UUID, assetID: UUID, state: ImportAssetState, lastConfirmedStep: String, serverAssetID: String? = nil, uploadID: String? = nil, targetPath: String? = nil) throws {
        guard let runIndex = document.runs.firstIndex(where: { $0.localRunID == runID }), let assetIndex = document.runs[runIndex].assets.firstIndex(where: { $0.queueAssetID == assetID }) else { return }
        var run = document.runs[runIndex]; var asset = run.assets[assetIndex]
        asset.state = state; asset.lastConfirmedStep = lastConfirmedStep
        asset.serverAssetID = serverAssetID ?? asset.serverAssetID; asset.uploadID = uploadID ?? asset.uploadID; asset.targetPath = targetPath ?? asset.targetPath
        run.assets[assetIndex] = asset; run.updatedAt = Date(); upsert(run); try persist()
    }
    func markRun(runID: UUID, state: ImportRunState, serverRunID: String? = nil, albumSyncPending: Bool? = nil) throws {
        guard let index = document.runs.firstIndex(where: { $0.localRunID == runID }) else { return }
        var run = document.runs[index]; run.state = state; run.updatedAt = Date(); run.serverRunID = serverRunID ?? run.serverRunID
        if let albumSyncPending { run.albumSyncPending = albumSyncPending }; upsert(run); try persist()
    }
    func remove(runID: UUID) throws { document.runs.removeAll { $0.localRunID == runID }; try persist() }
    func serializedData() throws -> Data { try encoder.encode(document) }

    private func upsert(_ run: PersistedImportRun) {
        if let index = document.runs.firstIndex(where: { $0.localRunID == run.localRunID }) { document.runs[index] = run }
        else { document.runs.append(run) }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

private enum ImportQueueDocumentSchema { static let current = 1 }

enum ImportRecoveryAction: Equatable, Sendable {
    case prepare
    case reconcile
    case albumSync
    case none
}

enum ImportRecoveryCoordinator {
    static func action(for run: PersistedImportRun, asset: PersistedImportAsset) -> ImportRecoveryAction {
        switch run.state {
        case .assetsComplete, .albumSyncPending: return .albumSync
        case .completed, .cancelled, .failed: return .none
        case .assetProcessing:
            switch asset.state {
            case .queued, .needsPrepare: return .prepare
            case .needsReconcile: return .reconcile
            case .completed, .failed: return .none
            }
        }
    }
}

enum InventoryCheckClient {
    static func check(connection: ConnectorConnection, source: PhotoSource, assets: [AssetInventory], transport: any DAVTransport = NetworkTransport()) async throws -> InventoryReply {
        guard !assets.isEmpty else { throw InventoryCheckError.invalidResponse }
        let json = try InventoryJSON.encode(assets, source: source)
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let phase = IOSImportDiagnostics.start("asset-inventory")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.finish("asset-inventory", started: phase, detail: "status=\(response.status)") }
        catch let error {
            IOSImportDiagnostics.failure("asset-inventory", started: phase, error: error)
            if case let UploadError.http(status) = error {
            if status == 401 || status == 403 { throw InventoryCheckError.authenticationFailed }
            if status == 404 { throw InventoryCheckError.endpointUnavailable }
            if status >= 500 { throw InventoryCheckError.endpointUnavailable }
            throw InventoryCheckError.invalidResponse
            }
            throw InventoryCheckError.network
        }
        guard (200..<300).contains(response.status), let decoded = try? JSONDecoder().decode(InventoryReply.self, from: response.data),
              decoded.assets.count == assets.count, decoded.summary.seen == assets.count,
              decoded.summary.new == decoded.assets.filter({ $0.state == .new }).count,
              decoded.summary.known == decoded.assets.filter({ $0.state == .known }).count,
              decoded.summary.new + decoded.summary.known == decoded.summary.seen else {
            throw InventoryCheckError.invalidResponse
        }
        return decoded
    }
}

enum IOSAlbumSyncClient {
    static func inventoryAndSync(connection: ConnectorConnection, source: PhotoSource, albums: [AlbumInventory], selectedAssets: [AssetInventory], transport: any DAVTransport = NetworkTransport()) async throws {
        let document = AlbumInventoryDocument(source: source, albums: albums)
        IOSImportDiagnostics.log("album-inventory-build OK albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })")
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "albums", "inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(document)
        let inventoryPhase = IOSImportDiagnostics.start("albums/inventory")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.finish("albums/inventory", started: inventoryPhase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure("albums/inventory", started: inventoryPhase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
        let selectedAlbumIDs = albums.filter { album in
            album.assetIdentities.contains { identity in selectedAssets.contains { $0.stableIdentity == identity } }
        }.map { $0.cloudIdentifier.map { "cloud:\($0)" } ?? "local:\($0.localIdentifier)" }
        var sync = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "albums", "sync"], method: "POST")
        sync.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sync.httpBody = try JSONSerialization.data(withJSONObject: ["sourceId": source.sourceId.uuidString.lowercased(), "selectedAlbumIDs": selectedAlbumIDs, "selectedAssetIDs": selectedAssets.map(\.stableIdentity)])
        let syncPhase = IOSImportDiagnostics.start("albums/sync")
        let syncResponse: DAVResponse
        do { syncResponse = try await transport.send(sync, file: nil); IOSImportDiagnostics.finish("albums/sync", started: syncPhase, detail: "status=\(syncResponse.status)") }
        catch { IOSImportDiagnostics.failure("albums/sync", started: syncPhase, error: error); throw error }
        guard (200..<300).contains(syncResponse.status) else { throw UploadError.http(syncResponse.status) }
    }
}

/// Runs a bounded set of independent jobs without creating an unbounded task set.
/// Results are returned in input order; completion order has no semantic meaning.
struct IOSAssetJobScheduler {
    static func run<Result: Sendable>(count: Int, maxConcurrent: Int = 2, operation: @escaping @Sendable (Int) async throws -> Result) async throws -> [Result] {
        guard count >= 0, maxConcurrent > 0 else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var results = Array<Result?>(repeating: nil, count: count)
            var next = 0
            var running = 0
            try Task.checkCancellation()
            func launch(_ index: Int) {
                group.addTask { (index, try await operation(index)) }
                running += 1
            }
            while next < count && running < maxConcurrent { launch(next); next += 1 }
            while running > 0 {
                try Task.checkCancellation()
                guard let (index, result) = try await group.next() else { break }
                results[index] = result
                running -= 1
                if next < count { launch(next); next += 1 }
            }
            return results.compactMap { $0 }
        }
    }
}

/// Foreground-only iOS import.  It deliberately keeps orchestration in the
/// iOS target while reusing the shared WebDAV uploader and content identity.
@MainActor
final class IOSForegroundImportCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, inventory, exporting, hashing, preparing, uploading, completing, finished, failed, cancelled }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentFilename: String?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var uploaded = 0
    @Published private(set) var alreadyPresent = 0
    @Published private(set) var reconciled = 0
    @Published private(set) var transferSentBytes: Int64 = 0
    @Published private(set) var transferTotalBytes: Int64 = 0
    @Published private(set) var failure: String?
    private var task: Task<Void, Never>?
    private let queueStore: ImportQueueStore
    private var activeRunID: UUID?
    private var transferProgress = IOSImportProgressAggregation()
    private var pendingCompletion = Set<Int>()
    init(queueStore: ImportQueueStore = ImportQueueStore()) { self.queueStore = queueStore }
    var overallProgress: Double {
        guard total > 0 else { return 0 }
        if completed >= total { return 1 }
        return min(0.999, (Double(completed + pendingCompletion.count) + transferProgress.activeFraction) / Double(total))
    }
    var isRunning: Bool { ![.idle, .finished, .failed, .cancelled].contains(phase) }
    var activeTransfers: [(job: Int, sent: Int64, total: Int64)] { transferProgress.activeEntries }
    /// The server-side verification is only the visible phase when no other
    /// asset is still sending PUT bytes.
    var isVerifyingCompletedUpload: Bool {
        Self.isVerifyingCompletedUpload(pendingCompletionCount: pendingCompletion.count, activeTransferCount: transferProgress.activeEntries.count)
    }
    static func isVerifyingCompletedUpload(pendingCompletionCount: Int, activeTransferCount: Int) -> Bool {
        pendingCompletionCount > 0 && activeTransferCount == 0
    }

    private enum AssetJobOutcome: Sendable {
        case known
        case uploaded
        case reconciled
        case completed
    }

    func cancel() {
        phase = .cancelled
        task?.cancel()
        if let runID = activeRunID { Task { try? await queueStore.markRun(runID: runID, state: .cancelled, albumSyncPending: false) } }
    }

    func recoverableRuns() async -> [PersistedImportRun] { await queueStore.recoverableRuns() }

    func start(selection: [GalleryAsset], library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, transport: any DAVTransport = NetworkTransport(), resumeRun: PersistedImportRun? = nil) {
        IOSImportDiagnostics.announceIfEnabled()
        cancel(); phase = .inventory; failure = nil; completed = 0; uploaded = 0; alreadyPresent = 0; reconciled = 0; transferProgress = IOSImportProgressAggregation(); pendingCompletion = []; transferSentBytes = 0; transferTotalBytes = 0; total = selection.count
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let uploader = WebDAVUploader(connection: connection, transport: transport, debug: { message in IOSImportDiagnostics.log(message) })
                let inventoryPhase = IOSImportDiagnostics.start("asset-inventory-build")
                let assets: [AssetInventory]
                do { assets = try library.inventory(for: selection); IOSImportDiagnostics.finish("asset-inventory-build", started: inventoryPhase, detail: "assets=\(assets.count)") }
                catch { IOSImportDiagnostics.failure("asset-inventory-build", started: inventoryPhase, error: error); throw error }
                let runID = resumeRun?.localRunID ?? UUID()
                let persistedAssets = resumeRun?.assets ?? zip(selection, assets).map { selected, asset in
                    PersistedImportAsset(queueAssetID: UUID(), stableIdentity: asset.stableIdentity, localIdentifier: selected.id, cloudIdentifier: asset.cloudIdentifier,
                        mediaType: asset.mediaType, filenameHint: asset.filename, captureDate: asset.creationDate, state: .queued, serverAssetID: nil, uploadID: nil,
                        targetPath: nil, expectedBytes: nil, expectedSHA256: nil, lastConfirmedStep: "selected", retryCount: 0, lastErrorCode: nil)
                }
                let persistedRun = PersistedImportRun(schemaVersion: PersistedImportRun.currentSchemaVersion, localRunID: runID,
                    account: ImportAccountReference(serverBaseURL: connection.base.absoluteString, username: connection.user), sourceID: source.sourceId,
                    createdAt: Date(), updatedAt: Date(), state: .assetProcessing, serverRunID: nil, assetOrder: persistedAssets.map(\.queueAssetID),
                    albumSyncPending: false, assets: persistedAssets)
                if resumeRun == nil { try await queueStore.save(persistedRun) }
                else { try await queueStore.markRun(runID: runID, state: .assetProcessing, albumSyncPending: false) }
                activeRunID = runID
                if let resumeRun, (resumeRun.state == .assetsComplete || resumeRun.state == .albumSyncPending) {
                    try await queueStore.markRun(runID: runID, state: .albumSyncPending, albumSyncPending: true)
                    self.setPhase(.completing)
                    let albums = try library.albumInventory()
                    try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: transport)
                    try await queueStore.markRun(runID: runID, state: .completed, albumSyncPending: false)
                    self.finish()
                    return
                }
                let reply = try await InventoryCheckClient.check(connection: connection, source: source, assets: assets, transport: transport)
                try await queueStore.markRun(runID: runID, state: .assetProcessing, serverRunID: reply.runId)
                for (index, entry) in reply.assets.enumerated() where persistedAssets.indices.contains(index) {
                    try await queueStore.markAsset(runID: runID, assetID: persistedAssets[index].queueAssetID,
                        state: entry.state == .known ? .completed : .needsPrepare,
                        lastConfirmedStep: entry.state == .known ? "inventory-known" : "inventory-ticket",
                        serverAssetID: entry.upload?.assetId, uploadID: entry.upload?.uploadId)
                }
                self.setPhase(.uploading)
                try await self.runAssetJobs(selection: selection, assets: assets, reply: reply, library: library, connection: connection, source: source, transport: transport, uploader: uploader, runID: runID, persistedAssets: persistedAssets)
                try await queueStore.markRun(runID: runID, state: .assetsComplete, albumSyncPending: true)
                self.setPhase(.completing)
                let albumBuild = IOSImportDiagnostics.start("album-inventory-build")
                let albums: [AlbumInventory]
                do { albums = try library.albumInventory(); IOSImportDiagnostics.finish("album-inventory-build", started: albumBuild, detail: "albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })") }
                catch { IOSImportDiagnostics.failure("album-inventory-build", started: albumBuild, error: error); throw error }
                try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: transport)
                try await queueStore.markRun(runID: runID, state: .completed, albumSyncPending: false)
                self.finish()
            } catch is CancellationError { self.cancelled() }
            catch { self.failed(error.localizedDescription) }
        }
    }

    private func runAssetJobs(selection: [GalleryAsset], assets: [AssetInventory], reply: InventoryReply, library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, transport: any DAVTransport, uploader: WebDAVUploader, runID: UUID, persistedAssets: [PersistedImportAsset]) async throws {
        let outcomes = try await IOSAssetJobScheduler.run(count: selection.count, maxConcurrent: 2) { [weak self] index in
            guard let self else { throw CancellationError() }
            let selected = selection[index]
            let asset = assets[index]
            let entry = reply.assets[index]
            IOSImportDiagnostics.log("asset-job[\(index + 1)] START")
            let started = ContinuousClock.now
            do {
                let outcome = try await self.runAssetJob(index: index, selected: selected, asset: asset, entry: entry, reply: reply, library: library, connection: connection, source: source, transport: transport, uploader: uploader, runID: runID, queueAsset: persistedAssets[index])
                IOSImportDiagnostics.log("asset-job[\(index + 1)] OK elapsed=\(started.duration(to: .now))")
                return (index, outcome)
            } catch {
                IOSImportDiagnostics.log("asset-job[\(index + 1)] ERROR elapsed=\(started.duration(to: .now)) error=\(String(describing: type(of: error)))")
                throw error
            }
        }
        for (index, outcome) in outcomes.enumerated() {
            self.apply(outcome.1, job: index, filename: assets[index].filename ?? selection[index].asset.localIdentifier)
        }
    }

    private func runAssetJob(index: Int, selected: GalleryAsset, asset: AssetInventory, entry: InventoryAssetReply, reply: InventoryReply, library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, transport: any DAVTransport, uploader: WebDAVUploader, runID: UUID, queueAsset: PersistedImportAsset) async throws -> AssetJobOutcome {
        try Task.checkCancellation()
        guard reply.assets.indices.contains(index) else { throw InventoryCheckError.invalidResponse }
        if queueAsset.state == .completed { return .completed }
        let queueAssetID = queueAsset.queueAssetID
        if entry.state == .known { try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "inventory-known"); self.markAlready(); return .known }
        guard let ticket = entry.upload else { throw InventoryCheckError.invalidResponse }
        let exportPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] photo-original-export")
        let exported: PhotoLibraryModel.ExportedOriginal
        do { exported = try await library.exportOriginal(for: selected); IOSImportDiagnostics.finish("asset-job[\(index + 1)] photo-original-export", started: exportPhase, detail: "bytes=pending") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] photo-original-export", started: exportPhase, error: error); throw error }
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        let hashPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] sha256")
        let identity: ContentIdentity
        do { identity = try await Task.detached { try ContentIdentity.read(exported.url) }.value; IOSImportDiagnostics.finish("asset-job[\(index + 1)] sha256", started: hashPhase, detail: "bytes=\(identity.bytes)") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] sha256", started: hashPhase, error: error); throw error }
        let calendar = Calendar(identifier: .gregorian)
        let date = selected.creationDate
        let folder = "Photos/Apple Photos Connector/\(calendar.component(.year, from: date))/\(String(format: "%02d", calendar.component(.month, from: date)))"
        let provider = IOSUploadTargets(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, folder: folder)
        let putPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] webdav-transfer")
        try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .needsReconcile, lastConfirmedStep: "remote-state-unknown")
        let target: UploadTarget
        do { target = try await uploader.uploadWithTarget(file: exported.url, filename: exported.filename, assetId: ticket.assetId, captureDate: date, targets: provider, targetRoot: "Photos/Apple Photos Connector", progress: { [weak self] sent, total in
            Task { @MainActor in self?.updateTransferProgress(job: index, sent: sent, total: total) }
        }); IOSImportDiagnostics.finish("asset-job[\(index + 1)] webdav-transfer", started: putPhase, detail: "bytes=\(identity.bytes)") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] webdav-transfer", started: putPhase, error: error); throw error }
        if target.state == "contentAlreadyPresent" { try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "content-reconciled", targetPath: target.path); self.markReconciled(); return .reconciled }
        pendingCompletion.insert(index)
        transferProgress.remove(job: index)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
        try Task.checkCancellation()
        do {
            try await IOSUploadHTTP.complete(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: target.path)
        } catch {
            pendingCompletion.remove(index)
            throw error
        }
        pendingCompletion.remove(index)
        try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "complete-confirmed", targetPath: target.path)
        self.markUploaded()
        return .uploaded
    }

    private func apply(_ outcome: AssetJobOutcome, job: Int, filename: String) {
        currentFilename = filename
        pendingCompletion.remove(job)
        transferProgress.remove(job: job)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
        switch outcome {
        case .known, .uploaded, .reconciled, .completed: break
        }
    }

    private func updateTransferProgress(job: Int, sent: Int64, total: Int64) {
        transferProgress.update(job: job, sent: sent, total: total)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
    }

    private func setCurrent(_ asset: PHAsset, filename: String?) { currentFilename = filename ?? asset.localIdentifier }
    private func setProgress(_ _: Double) {}
    private func setPhase(_ value: Phase) { phase = value }
    private func markAlready() { alreadyPresent += 1; completed += 1 }
    private func markUploaded() { uploaded += 1; completed += 1 }
    private func markReconciled() { reconciled += 1; alreadyPresent += 1; completed += 1 }
    private func finish() { phase = .finished }
    private func cancelled() { phase = .cancelled; if let runID = activeRunID { Task { try? await queueStore.markRun(runID: runID, state: .cancelled, albumSyncPending: false) } } }
    private func failed(_ message: String) { failure = message; phase = .failed; if let runID = activeRunID { Task { try? await queueStore.markRun(runID: runID, state: .failed) } } }
}

private struct IOSUploadTargets: UploadTargetProvider {
    let connection: ConnectorConnection; let transport: any DAVTransport
    let source: String; let runId: String; let uploadId: String; let folder: String
    func prepare(identity: ContentIdentity) async throws -> UploadTarget {
        let data: [String: Any] = ["sourceId": source, "runId": runId, "uploadId": uploadId, "bytes": identity.bytes, "sha256": identity.sha256, "folder": folder]
        return try await IOSUploadHTTP.request(connection: connection, transport: transport, endpoint: "uploads/prepare", body: data)
    }
}

private enum IOSUploadHTTP {
    static func request(connection: ConnectorConnection, transport: any DAVTransport, endpoint: String, body: [String: Any]) async throws -> UploadTarget {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1"] + endpoint.split(separator: "/").map(String.init), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let phase = IOSImportDiagnostics.start(endpoint)
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.finish(endpoint, started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure(endpoint, started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
        return try JSONDecoder().decode(UploadTarget.self, from: response.data)
    }
    static func complete(connection: ConnectorConnection, transport: any DAVTransport, source: String, runId: String, uploadId: String, path: String) async throws {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "uploads", "complete"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sourceId": source, "runId": runId, "uploadId": uploadId, "status": "uploaded", "path": path])
        let phase = IOSImportDiagnostics.start("uploads/complete")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil, kind: .longRunningVerification, progress: nil); IOSImportDiagnostics.finish("uploads/complete", started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure("uploads/complete", started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
    }
}
