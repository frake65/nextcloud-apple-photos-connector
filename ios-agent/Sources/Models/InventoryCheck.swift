import Foundation
import OSLog
#if DEBUG
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif
import Network
import InventoryCore
import Photos

enum IOSImportDiagnostics {
    private static let processStart = ContinuousClock.now
    private static let errorLogger = Logger(subsystem: "de.applephotosconnector.ios", category: "ImportFailure")
    private static let phaseLogger = Logger(subsystem: "de.applephotosconnector.ios", category: "ImportPhase")
    private static let putLogger = Logger(subsystem: "de.applephotosconnector.ios", category: "WebDAVPUT")
    static let defaultsKey = "apc.debug.importDiagnostics"
#if DEBUG
    nonisolated(unsafe) static var testLogHandler: ((String) -> Void)?
    nonisolated(unsafe) private static var didAnnounceBuild = false
#endif
    static var enabled: Bool {
        #if DEBUG
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: defaultsKey)
        #else
        return false
        #endif
    }
    static func log(_ message: String) {
        #if DEBUG
        guard enabled else { return }
        let elapsed = processStart.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let prefix = String(format: "APC IMPORT [Startup +%.3fs] ", seconds)
        let line = prefix + (message.hasPrefix("APC IMPORT ") ? String(message.dropFirst("APC IMPORT ".count)) : message)
        print(line)
        #if DEBUG
        testLogHandler?(line)
        #endif
        #endif
    }
    static func announceIfEnabled() {
        #if DEBUG
        if !didAnnounceBuild {
            didAnnounceBuild = true
            print("iOS build source: base=0ecc975 inventoryBatchFastPath=true diagnosticRevision=webdav-put-device-1")
        }
        if enabled { print("APC IMPORT DIAGNOSTICS ENABLED") }
        #endif
    }
    static func start(_ phase: String) -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        if enabled { log("\(phase) START") }
        return now
    }
    static func finish(_ phase: String, started: ContinuousClock.Instant?, detail: String = "") {
        guard let started, enabled else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        log("\(phase) OK elapsed=\(started.duration(to: .now))\(suffix)")
    }
    static func failure(_ phase: String, started: ContinuousClock.Instant?, error: Error) {
        let elapsed = started.map { durationSeconds($0.duration(to: .now)) } ?? -1
        let category: String
        if let failure = error as? IOSUploadFailure { category = failure.diagnosticCategory }
        else if let urlError = error as? URLError { category = "urlError=\(urlError.code.rawValue)" }
        else if case let UploadError.http(status) = error { category = "httpStatus=\(status)" }
        else { category = "error=\(String(describing: type(of: error)))" }
        // Always retain one privacy-safe failure record in Release/TestFlight.
        // Phase names are fixed protocol steps; no filenames, paths, identities,
        // hashes, credentials, or response bodies are included.
        errorLogger.error("phase=\(phase, privacy: .public) elapsedSeconds=\(elapsed, privacy: .public) \(category, privacy: .public)")
        if enabled { log("\(phase) ERROR elapsedSeconds=\(elapsed) \(category)") }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    static func jobPhaseStarted(lane: Int, phase: IOSImportJobPhase, activeJobs: Int, visibleRows: Int) {
        phaseLogger.info("event=start lane=\(lane, privacy: .public) phase=\(phase.rawValue, privacy: .public) activeJobs=\(activeJobs, privacy: .public) visibleRows=\(visibleRows, privacy: .public)")
    }

    static func jobPhaseFinished(lane: Int, phase: IOSImportJobPhase, started: ContinuousClock.Instant, result: String, activeJobs: Int, visibleRows: Int, error: Error? = nil) {
        let elapsed = durationSeconds(started.duration(to: .now))
        let detail = error.map(errorCategory) ?? "error=none"
        phaseLogger.info("event=end lane=\(lane, privacy: .public) phase=\(phase.rawValue, privacy: .public) elapsedSeconds=\(elapsed, privacy: .public) result=\(result, privacy: .public) activeJobs=\(activeJobs, privacy: .public) visibleRows=\(visibleRows, privacy: .public) \(detail, privacy: .public)")
    }

    private static func errorCategory(_ error: Error) -> String {
        if let failure = error as? IOSUploadFailure { return failure.diagnosticCategory }
        if let urlError = error as? URLError { return "urlError=\(urlError.code.rawValue)" }
        if case let UploadError.http(status) = error { return "httpStatus=\(status)" }
        let nsError = error as NSError
        return "errorDomain=\(nsError.domain) errorCode=\(nsError.code)"
    }

    static func putSnapshot(event: String, lane: Int, task: String, expectedBytes: Int64, sentBytes: Int64, lastProgressAt: String, duration: Double, taskState: String, requestTimeout: Double, resourceTimeout: Double, httpStatus: Int?, responseDuration: Double?, error: Error? = nil) {
        let percent = expectedBytes > 0 ? min(100, max(0, Double(sentBytes) / Double(expectedBytes) * 100)) : 0
        let transferState = BackgroundPUTObservation.classify(expectedBytes: expectedBytes, sentBytes: sentBytes, responseReceived: httpStatus != nil).rawValue
        let status = httpStatus.map(String.init) ?? "none"
        let response = responseDuration.map { String(format: "%.3f", $0) } ?? "none"
        let failure = error.map(errorCategory) ?? "error=none"
        putLogger.info("event=\(event, privacy: .public) lane=\(lane, privacy: .public) task=\(task, privacy: .public) transferState=\(transferState, privacy: .public) expectedBytes=\(expectedBytes, privacy: .public) sentBytes=\(sentBytes, privacy: .public) percent=\(percent, privacy: .public) lastProgressAt=\(lastProgressAt, privacy: .public) durationSeconds=\(duration, privacy: .public) taskState=\(taskState, privacy: .public) requestTimeout=\(requestTimeout, privacy: .public) resourceTimeout=\(resourceTimeout, privacy: .public) httpStatus=\(status, privacy: .public) responseDurationSeconds=\(response, privacy: .public) \(failure, privacy: .public)")
    }

    static func memory(phase: String, asset: String? = nil, job: Int? = nil, readMiB: Double? = nil) {
        #if DEBUG
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { log("APC MEMORY phase=\(phase) error=task_info_\(result)"); return }
        let mib = 1024.0 * 1024.0
        let assetPart = asset.map { " asset=\($0.prefix(8))" } ?? ""
        let jobPart = job.map { " job=\($0)" } ?? ""
        let readPart = readMiB.map { String(format: " readMiB=%.1f", $0) } ?? ""
        log(String(format: "APC MEMORY phase=%@%@%@%@ physFootprintMiB=%.1f residentMiB=%.1f", phase, assetPart, jobPart, readPart, Double(info.phys_footprint) / mib, Double(info.resident_size) / mib))
        #endif
    }
}

enum IOSImportJobPhase: String, Sendable {
    case photoKitResource = "photokit-resource"
    case photoKitExport = "photokit-export"
    case hashing
    case prepare
    case put
    case complete
    case reconciliation
}

struct IOSImportTransferSlot: Equatable, Sendable, Identifiable {
    let slot: Int
    let lane: Int
    let job: Int?
    let assetPrefix: String?
    let filename: String?
    let mediaType: String?
    let phase: IOSImportJobPhase?
    let sent: Int64
    let total: Int64

    var id: Int { slot }
    var isOccupied: Bool { job != nil }

    static func free(slot: Int) -> Self {
        Self(slot: slot, lane: slot + 1, job: nil, assetPrefix: nil, filename: nil, mediaType: nil, phase: nil, sent: 0, total: 0)
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
    private var jobs: [Int: (slot: Int, filename: String?, mediaType: String?, sent: Int64, total: Int64, phase: IOSImportJobPhase)] = [:]
    var sentBytes: Int64 { jobs.values.reduce(0) { $0 + $1.sent } }
    var totalBytes: Int64 { jobs.values.reduce(0) { $0 + $1.total } }
    var fraction: Double { totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 0 }
    mutating func register(job: Int, filename: String?, mediaType: String? = nil) {
        guard jobs[job] == nil else { return }
        let occupiedSlots = Set(jobs.values.map(\.slot))
        let slot = (0..<2).first { !occupiedSlots.contains($0) } ?? jobs.count
        jobs[job] = (slot, filename, mediaType, 0, 0, .photoKitResource)
    }
    mutating func setPhase(job: Int, phase: IOSImportJobPhase) {
        guard let existing = jobs[job] else { return }
        jobs[job] = (existing.slot, existing.filename, existing.mediaType, existing.sent, existing.total, phase)
    }
    mutating func update(job: Int, filename: String? = nil, sent: Int64, total: Int64) {
        guard let existing = jobs[job] else { return }
        jobs[job] = (existing.slot, filename ?? existing.filename, existing.mediaType, max(0, sent), max(0, total), existing.phase)
    }
    mutating func remove(job: Int) { jobs.removeValue(forKey: job) }
    func slot(for job: Int) -> Int? { jobs[job]?.slot }
    var activeFraction: Double { jobs.values.reduce(0) { $0 + ($1.total > 0 ? min(1, Double($1.sent) / Double($1.total)) : 0) } }
    var activeEntries: [(slot: Int, job: Int, filename: String?, mediaType: String?, sent: Int64, total: Int64, phase: IOSImportJobPhase)] {
        jobs.map { (slot: $0.value.slot, job: $0.key, filename: $0.value.filename, mediaType: $0.value.mediaType, sent: $0.value.sent, total: $0.value.total, phase: $0.value.phase) }
            .sorted { $0.slot < $1.slot }
    }
    func slotEntries(assetPrefixes: [Int: String] = [:]) -> [IOSImportTransferSlot] {
        (0..<2).map { slot in
            guard let entry = activeEntries.first(where: { $0.slot == slot }) else {
                return .free(slot: slot)
            }
            return IOSImportTransferSlot(
                slot: entry.slot,
                lane: entry.slot + 1,
                job: entry.job,
                assetPrefix: assetPrefixes[entry.job],
                filename: entry.filename,
                mediaType: entry.mediaType,
                phase: entry.phase,
                sent: entry.sent,
                total: entry.total)
        }
    }
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

enum IOSImportServerStatusPolicy {
    static let sideRequestFailureMessage = "Die Inventarprüfung für weitere Dateien ist fehlgeschlagen. Laufende Übertragungen werden fortgesetzt."

    static func shouldClearUnreachableStatus(activeUploadProgress: Bool, successfulResponse: Bool) -> Bool {
        activeUploadProgress || successfulResponse
    }

    static func isNetworkError(_ error: Error) -> Bool {
        guard let issue = error as? InventoryCheckError else { return false }
        if case .network = issue { return true }
        return false
    }

    static func message(for error: Error, activeUploadProgress: Bool) -> String {
        if isNetworkError(error), activeUploadProgress {
            return sideRequestFailureMessage
        }
        return error.localizedDescription
    }
}

enum ImportRunState: String, Codable, Sendable {
    case assetProcessing
    case assetsComplete
    case albumSyncPending
    case completed
    case cancelled
    case failed

    var hasOpenImport: Bool {
        self == .assetProcessing || self == .assetsComplete || self == .albumSyncPending
    }
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
    var stableIdentity: String
    let localIdentifier: String
    var cloudIdentifier: String?
    var mediaType: String
    var filenameHint: String?
    var captureDate: Date?
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
    static let metadataProtection: FileProtectionType = .completeUntilFirstUserAuthentication
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
        try? FileManager.default.setAttributes([.protectionKey: Self.metadataProtection], ofItemAtPath: fileURL.path)
    }

    func allRuns() -> [PersistedImportRun] { document.runs }
    func run(localRunID: UUID) -> PersistedImportRun? { document.runs.first { $0.localRunID == localRunID } }
    func fileExists() -> Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    func recoverableRuns() -> [PersistedImportRun] {
        var seen = Set<String>()
        return document.runs
            .filter { $0.state == .assetProcessing || $0.state == .assetsComplete || $0.state == .albumSyncPending }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert("\($0.account.serverBaseURL)|\($0.account.username)|\($0.sourceID.uuidString)").inserted }
    }
    func save(_ run: PersistedImportRun) throws { upsert(run); try persist() }
    func updateInventory(runID: UUID, assets: [PersistedImportAsset]) throws {
        guard let runIndex = document.runs.firstIndex(where: { $0.localRunID == runID }) else { return }
        var run = document.runs[runIndex]
        let updates = Dictionary(uniqueKeysWithValues: assets.map { ($0.queueAssetID, $0) })
        run.assets = run.assets.map { updates[$0.queueAssetID] ?? $0 }
        run.updatedAt = Date()
        upsert(run)
        try persist()
    }
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
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.protectionKey: Self.metadataProtection], ofItemAtPath: fileURL.path)
    }
}

private enum ImportQueueDocumentSchema { static let current = 1 }

enum ImportRecoveryAction: Equatable, Sendable {
    case prepare
    case reconcile
    case albumSync
    case none
}

struct BackgroundTaskBinding: Codable, Equatable, Sendable, Identifiable {
    let queueAssetID: UUID
    let localRunID: UUID
    let uploadAttemptID: UUID
    let sessionIdentifier: String
    let taskIdentifier: Int
    let relativeTransferPath: String
    let expectedHost: String
    let targetPath: String
    let createdAt: Date
    var id: UUID { uploadAttemptID }
}

struct BackgroundTransferActivity: Sendable {
    let binding: BackgroundTaskBinding
    let sentBytes: Int64
    let expectedBytes: Int64
}

/// Owns completed PhotoKit exports used by background URLSession. The URL is
/// only published after an atomic move from a private staging file.
actor BackgroundTransferFileStore {
    private let root: URL
    init(directoryURL: URL? = nil) {
        root = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ApplePhotosConnector", isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
    }
    func prepare(source: URL, uploadAttemptID: UUID) throws -> (url: URL, relativePath: String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relative = "\(uploadAttemptID.uuidString).upload"
        let staging = root.appendingPathComponent(".\(relative).staging")
        let destination = root.appendingPathComponent(relative)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
        try FileManager.default.moveItem(at: staging, to: destination)
        return (destination, relative)
    }
    func remove(relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
    func url(relativePath: String) -> URL { root.appendingPathComponent(relativePath) }
}

actor BackgroundTaskBindingStore {
    static let metadataProtection: FileProtectionType = .completeUntilFirstUserAuthentication
    private let fileURL: URL
    private var bindings: [BackgroundTaskBinding] = []
    init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ApplePhotosConnector", isDirectory: true)
        fileURL = directory.appendingPathComponent("background-task-bindings-v1.json")
        if let data = try? Data(contentsOf: fileURL), let loaded = try? JSONDecoder().decode([BackgroundTaskBinding].self, from: data) { bindings = loaded }
        try? FileManager.default.setAttributes([.protectionKey: Self.metadataProtection], ofItemAtPath: fileURL.path)
    }
    func all() -> [BackgroundTaskBinding] { bindings }
    func binding(uploadAttemptID: UUID) -> BackgroundTaskBinding? { bindings.first { $0.uploadAttemptID == uploadAttemptID } }
    func upsert(_ binding: BackgroundTaskBinding) throws { bindings.removeAll { $0.uploadAttemptID == binding.uploadAttemptID }; bindings.append(binding); try persist() }
    func remove(taskIdentifier: Int, sessionIdentifier: String) throws { bindings.removeAll { $0.taskIdentifier == taskIdentifier && $0.sessionIdentifier == sessionIdentifier }; try persist() }
    func remove(uploadAttemptID: UUID) throws { bindings.removeAll { $0.uploadAttemptID == uploadAttemptID }; try persist() }
    func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(bindings)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.protectionKey: Self.metadataProtection], ofItemAtPath: fileURL.path)
    }
}

enum BackgroundTransferOutcome: Equatable, Sendable { case success, failure, unknown }
enum BackgroundTaskReconciliation: Equatable, Sendable { case attached, missingTask, orphanTask, conflictingBinding }

struct BackgroundTransferNetworkPolicy: Equatable, Sendable {
    let allowsCellularAccess: Bool
    let waitsForConnectivity: Bool

    init(allowsCellularAccess: Bool) {
        self.allowsCellularAccess = allowsCellularAccess
        waitsForConnectivity = true
    }
}

enum ImportConnectivityPolicy {
    static func shouldWait(allowsCellular: Bool, networkSatisfied: Bool, wifiAvailable: Bool) -> Bool {
        !networkSatisfied || (!allowsCellular && !wifiAvailable)
    }
}

/// Gates the import workflow before each control request. URLSession also
/// waits for connectivity, but this gate prevents a Wi-Fi-only import from
/// turning an unavailable path into a misleading server error.
final class ImportConnectivityGate: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "de.applephotosconnector.import-connectivity")
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waitingHandler: (@Sendable (Bool) -> Void)?
    private var preferenceObserver: NSObjectProtocol?

    init(waitingHandler: (@Sendable (Bool) -> Void)? = nil) {
        self.waitingHandler = waitingHandler
        monitor.pathUpdateHandler = { [weak self] _ in self?.resumeIfUsable() }
        monitor.start(queue: queue)
        preferenceObserver = NotificationCenter.default.addObserver(forName: IOSTransferNetworkPreferences.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.resumeIfUsable()
        }
    }

    deinit {
        monitor.cancel()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    func waitUntilUsable() async -> Bool {
        if isUsable() {
            waitingHandler?(false)
            return !Task.isCancelled
        }
        waitingHandler?(true)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    lock.lock(); continuations.append(continuation); lock.unlock()
                    resumeIfUsable()
                }
            }
        }, onCancel: {
            cancelWaiters()
        })
        waitingHandler?(false)
        return !Task.isCancelled && isUsable()
    }

    var isCurrentlyUsable: Bool { isUsable() }

    private func isUsable() -> Bool {
        let path = monitor.currentPath
        return !ImportConnectivityPolicy.shouldWait(
            allowsCellular: IOSTransferNetworkPreferences.useCellularAccess(),
            networkSatisfied: path.status == .satisfied,
            wifiAvailable: path.usesInterfaceType(.wifi)
        )
    }

    private func resumeIfUsable() {
        guard isUsable() else { return }
        lock.lock(); let pending = continuations; continuations.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }

    private func cancelWaiters() {
        lock.lock(); let pending = continuations; continuations.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
}

final class ImportNetworkTransport: @unchecked Sendable, DAVTransport {
    private let base: any DAVTransport
    private let gate: ImportConnectivityGate

    init(base: any DAVTransport, waitingHandler: (@Sendable (Bool) -> Void)? = nil) {
        self.base = base
        self.gate = ImportConnectivityGate(waitingHandler: waitingHandler)
    }

    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: nil)
    }

    func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: progress)
    }

    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard await gate.waitUntilUsable() else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            return try await base.send(request, file: file, kind: kind, progress: progress)
        } catch let error as URLError where Self.isConnectivityError(error) && !gate.isCurrentlyUsable {
            IOSImportDiagnostics.log("import connectivity request transient error code=\(error.code.rawValue); waiting for permitted path")
            guard await gate.waitUntilUsable() else { throw CancellationError() }
            try Task.checkCancellation()
            return try await base.send(request, file: file, kind: kind, progress: progress)
        }
    }

    private static func isConnectivityError(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
}

enum IOSImportTransportFactory {
    static func make(base: (any DAVTransport)? = nil, waitingHandler: (@Sendable (Bool) -> Void)? = nil) -> any DAVTransport {
        waitingHandler?(false)
        return base ?? NetworkTransport(allowsCellularAccess: IOSTransferNetworkPreferences.useCellularAccess(), waitsForConnectivity: false, responseDiagnostics: { response in
            InventoryCheckClient.logInventoryResponse(response)
        })
    }
}

struct BackgroundPUTTaskStateAggregation: Equatable, Sendable {
    private(set) var activePUTTasks = Set<String>()
    private(set) var waitingTasks = Set<String>()
    private(set) var activeSendingTasks = Set<String>()

    var waitingForConnectivity: Bool {
        !activePUTTasks.isEmpty && !waitingTasks.isEmpty && activeSendingTasks.isEmpty
    }

    mutating func started(_ key: String) {
        activePUTTasks.insert(key)
        waitingTasks.remove(key)
        activeSendingTasks.remove(key)
    }

    mutating func waiting(_ key: String) {
        activePUTTasks.insert(key)
        waitingTasks.insert(key)
        activeSendingTasks.remove(key)
    }

    mutating func sending(_ key: String) {
        activePUTTasks.insert(key)
        waitingTasks.remove(key)
        activeSendingTasks.insert(key)
    }

    mutating func completed(_ key: String) {
        activePUTTasks.remove(key)
        waitingTasks.remove(key)
        activeSendingTasks.remove(key)
    }
}

enum BackgroundPUTTaskKey {
    static func make(sessionIdentifier: String, taskIdentifier: Int) -> String {
        "\(sessionIdentifier):\(taskIdentifier)"
    }
}

enum BackgroundPUTObservation: String, Equatable, Sendable {
    case sending
    case awaitingResponse
    case responseReceived

    static func classify(expectedBytes: Int64, sentBytes: Int64, responseReceived: Bool) -> Self {
        if responseReceived { return .responseReceived }
        if expectedBytes > 0, sentBytes >= expectedBytes { return .awaitingResponse }
        return .sending
    }
}

/// Background URLSession adapter for the existing WebDAV PUT contract.
/// Prepare and Complete remain on the existing DAVTransport path.
final class BackgroundTransferCoordinator: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.applephotosconnector.background-webdav-put.v1"
    static let wifiSessionIdentifier = "com.applephotosconnector.background-webdav-put.wifi.v1"
    static let cellularSessionIdentifier = "com.applephotosconnector.background-webdav-put.cellular.v1"
    static let shared = BackgroundTransferCoordinator()
    private let bindingStore: BackgroundTaskBindingStore
    private let fileStore: BackgroundTransferFileStore
    private let queueStore: ImportQueueStore?
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<DAVResponse, Error>] = [:]
    private var responses: [Int: (Data, HTTPURLResponse)] = [:]
    private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
    private var completionInFlight = Set<UUID>()
    private var connectivityWaitingHandler: (@Sendable (Bool) -> Void)?
    private var putTaskStates = BackgroundPUTTaskStateAggregation()
    private struct PUTDiagnosticState {
        let token: String
        let lane: Int
        let startedAt: Date
        let expectedBytes: Int64
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval
        var sentBytes: Int64
        var lastProgressAt: Date?
        var responseAt: Date?
        var httpStatus: Int?
    }
    private var putDiagnostics: [String: PUTDiagnosticState] = [:]
    private var putDiagnosticMonitors: [String: Task<Void, Never>] = [:]
    private let lifecycleLock = NSLock()
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var sessions: [String: URLSession] = [:]
    private func sessionIdentifier(allowsCellular: Bool) -> String {
        allowsCellular ? Self.cellularSessionIdentifier : Self.wifiSessionIdentifier
    }
    private func session(allowsCellular: Bool) -> URLSession {
        let identifier = sessionIdentifier(allowsCellular: allowsCellular)
        if let existing = sessions[identifier] { return existing }
        IOSImportDiagnostics.log("background session create identifier=\(identifier)")
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        let policy = BackgroundTransferNetworkPolicy(allowsCellularAccess: allowsCellular)
        configuration.allowsCellularAccess = policy.allowsCellularAccess
        configuration.waitsForConnectivity = policy.waitsForConnectivity
        IOSImportDiagnostics.log("[NetworkPolicy] mobileTransfersEnabled=\(policy.allowsCellularAccess) allowsCellularAccess=\(configuration.allowsCellularAccess) waitsForConnectivity=\(configuration.waitsForConnectivity) sessionIdentifier=\(identifier)")
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessions[identifier] = created
        return created
    }
    private func allSessions() -> [(String, URLSession)] {
        [(Self.wifiSessionIdentifier, session(allowsCellular: false)),
         (Self.cellularSessionIdentifier, session(allowsCellular: true)),
         (Self.sessionIdentifier, legacySession())]
    }
    private func legacySession() -> URLSession {
        if let existing = sessions[Self.sessionIdentifier] { return existing }
        IOSImportDiagnostics.log("background session reconstruct legacy identifier=\(Self.sessionIdentifier)")
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = true
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessions[Self.sessionIdentifier] = created
        return created
    }
    private func updatePUTTaskState(_ update: (inout BackgroundPUTTaskStateAggregation) -> Void) {
        lock.lock()
        let previous = putTaskStates.waitingForConnectivity
        update(&putTaskStates)
        let current = putTaskStates.waitingForConnectivity
        let handler = previous == current ? nil : connectivityWaitingHandler
        lock.unlock()
        handler?(current)
    }
    init(bindingStore: BackgroundTaskBindingStore = BackgroundTaskBindingStore(), fileStore: BackgroundTransferFileStore = BackgroundTransferFileStore(), queueStore: ImportQueueStore? = nil) {
        self.bindingStore = bindingStore; self.fileStore = fileStore; self.queueStore = queueStore
        IOSImportDiagnostics.log("background session coordinator initialized/reconstructed identifier=\(Self.sessionIdentifier)")
    }
    func send(_ request: URLRequest, file: URL, queueAssetID: UUID, localRunID: UUID, uploadAttemptID: UUID, diagnosticLane: Int, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw UploadError.invalidConfiguration }
        IOSImportDiagnostics.memory(phase: "transfer-file-prepare-start", asset: queueAssetID.uuidString)
        let prepared = try await fileStore.prepare(source: file, uploadAttemptID: uploadAttemptID)
        let allowsCellular = IOSTransferNetworkPreferences.useCellularAccess()
        let activeSession = session(allowsCellular: allowsCellular)
        let preparedBytes = ((try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        IOSImportDiagnostics.log("transfer file prepared queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) bytes=\(preparedBytes)")
        IOSImportDiagnostics.memory(phase: "transfer-file-prepare-end", asset: queueAssetID.uuidString, job: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                IOSImportDiagnostics.memory(phase: "background-upload-task-create-start", asset: queueAssetID.uuidString)
                let task = activeSession.uploadTask(with: request, fromFile: prepared.url)
                IOSImportDiagnostics.memory(phase: "background-upload-task-create-end", asset: queueAssetID.uuidString)
                lock.lock(); continuations[task.taskIdentifier] = continuation; progressHandlers[task.taskIdentifier] = progress; lock.unlock()
                task.taskDescription = uploadAttemptID.uuidString
                IOSImportDiagnostics.log("[BackgroundPUT] task=\(task.taskIdentifier) asset=\(queueAssetID.uuidString.prefix(8)) bytes=\(preparedBytes) policyCellular=\(IOSTransferNetworkPreferences.useCellularAccess())")
                let sessionIdentifier = sessionIdentifier(allowsCellular: allowsCellular)
                let key = BackgroundPUTTaskKey.make(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)
                updatePUTTaskState { $0.started(key) }
                startPUTDiagnostics(key: key, task: task, session: activeSession, lane: diagnosticLane, expectedBytes: preparedBytes)
                IOSImportDiagnostics.log("background task start taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) session=\(sessionIdentifier)")
                Task { let binding = BackgroundTaskBinding(queueAssetID: queueAssetID, localRunID: localRunID, uploadAttemptID: uploadAttemptID, sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier, relativeTransferPath: prepared.relativePath, expectedHost: host, targetPath: request.url?.path ?? "", createdAt: Date()); try? await bindingStore.upsert(binding); IOSImportDiagnostics.log("binding created taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString)") }
                task.resume()
                IOSImportDiagnostics.memory(phase: "background-upload-started", asset: queueAssetID.uuidString)
            }
        } onCancel: {
            IOSImportDiagnostics.log("asset-job swift-task cancellation handler queueAssetID=\(queueAssetID.uuidString.prefix(8)) runID=\(localRunID.uuidString.prefix(8)) phase=put")
            self.cancelAll(for: uploadAttemptID)
        }
    }

    private func startPUTDiagnostics(key: String, task: URLSessionTask, session: URLSession, lane: Int, expectedBytes: Int64) {
        let state = PUTDiagnosticState(
            token: String(UUID().uuidString.prefix(8)).lowercased(),
            lane: lane,
            startedAt: Date(),
            expectedBytes: expectedBytes,
            requestTimeout: task.currentRequest?.timeoutInterval ?? session.configuration.timeoutIntervalForRequest,
            resourceTimeout: session.configuration.timeoutIntervalForResource,
            sentBytes: max(0, task.countOfBytesSent),
            lastProgressAt: nil,
            responseAt: nil,
            httpStatus: nil)
        lock.lock(); putDiagnostics[key] = state; lock.unlock()
        logPUTSnapshot(key: key, task: task, event: "start")
        let monitor = Task { [weak self, weak task] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard let self, let task else { return }
                self.logPUTSnapshot(key: key, task: task, event: "tick")
            }
        }
        lock.lock(); putDiagnosticMonitors[key] = monitor; lock.unlock()
    }

    private func logPUTSnapshot(key: String, task: URLSessionTask, event: String, error: Error? = nil, remove: Bool = false) {
        lock.lock()
        guard let state = putDiagnostics[key] else { lock.unlock(); return }
        let monitor = remove ? putDiagnosticMonitors.removeValue(forKey: key) : nil
        if remove { putDiagnostics.removeValue(forKey: key) }
        lock.unlock()
        monitor?.cancel()
        let taskState: String = switch task.state {
        case .running: "running"
        case .suspended: "suspended"
        case .canceling: "canceling"
        case .completed: "completed"
        @unknown default: "unknown"
        }
        let formatter = ISO8601DateFormatter()
        let lastProgress = state.lastProgressAt.map(formatter.string(from:)) ?? "none"
        IOSImportDiagnostics.putSnapshot(
            event: event,
            lane: state.lane,
            task: state.token,
            expectedBytes: state.expectedBytes,
            sentBytes: state.sentBytes,
            lastProgressAt: lastProgress,
            duration: Date().timeIntervalSince(state.startedAt),
            taskState: taskState,
            requestTimeout: state.requestTimeout,
            resourceTimeout: state.resourceTimeout,
            httpStatus: state.httpStatus,
            responseDuration: state.responseAt.map { $0.timeIntervalSince(state.startedAt) },
            error: error)
    }
    func reconcileTasks(queueStore: ImportQueueStore? = nil) async -> [BackgroundTaskReconciliation] {
        IOSImportDiagnostics.log("reconciliation started sessions=\(Self.wifiSessionIdentifier),\(Self.cellularSessionIdentifier),\(Self.sessionIdentifier)")
        var tasksBySession: [String: [URLSessionTask]] = [:]
        for (identifier, session) in allSessions() {
            tasksBySession[identifier] = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
        }
        let persisted = await bindingStore.all()
        IOSImportDiagnostics.log("startup reconciliation tasks=\(tasksBySession.values.reduce(0) { $0 + $1.count }) bindings=\(persisted.count)")
        var result: [BackgroundTaskReconciliation] = []
        for binding in persisted {
            let task = tasksBySession[binding.sessionIdentifier]?.first { $0.taskIdentifier == binding.taskIdentifier }
            guard let task else {
                let completeIsInFlight = isCompleteInFlight(binding.uploadAttemptID)
                if completeIsInFlight {
                    IOSImportDiagnostics.log("reconciliation deferred binding without task during complete queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
                    result.append(.attached); continue
                }
                IOSImportDiagnostics.log("binding without task taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
                if let queueStore { try? await queueStore.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "background-task-missing") }
                try? await bindingStore.remove(uploadAttemptID: binding.uploadAttemptID)
                IOSImportDiagnostics.log("asset -> needsReconcile queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) reason=background-task-missing; binding removed")
                result.append(.missingTask); continue
            }
            updatePUTTaskState { $0.started(BackgroundPUTTaskKey.make(sessionIdentifier: binding.sessionIdentifier, taskIdentifier: binding.taskIdentifier)) }
            guard task.taskDescription == binding.uploadAttemptID.uuidString,
                  task.originalRequest?.url?.host == binding.expectedHost else {
                IOSImportDiagnostics.log("conflicting binding taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
                IOSImportDiagnostics.log("background-task cancel requested reason=reconciliation session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))")
                task.cancel()
                if let queueStore { try? await queueStore.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "background-binding-conflict") }
                try? await bindingStore.remove(uploadAttemptID: binding.uploadAttemptID)
                IOSImportDiagnostics.log("asset -> needsReconcile queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) reason=background-binding-conflict; binding removed")
                result.append(.conflictingBinding); continue
            }
            IOSImportDiagnostics.log("task + binding taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
            result.append(.attached)
        }
        for (identifier, tasks) in tasksBySession {
            let boundIDs = Set(persisted.filter { $0.sessionIdentifier == identifier }.map(\.taskIdentifier))
            for task in tasks where !boundIDs.contains(task.taskIdentifier) { IOSImportDiagnostics.log("task without binding session=\(identifier) taskIdentifier=\(task.taskIdentifier)"); IOSImportDiagnostics.log("background-task cancel requested reason=reconciliation session=\(identifier) taskIdentifier=\(task.taskIdentifier)"); task.cancel(); result.append(.orphanTask) }
        }
        return result
    }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        _ = allSessions()
        lifecycleLock.lock(); backgroundEventsCompletionHandler = handler; lifecycleLock.unlock()
        IOSImportDiagnostics.log("background events completion handler received")
    }
    func setConnectivityWaitingHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.lock(); connectivityWaitingHandler = handler; lock.unlock()
    }
    func activeTransferActivities(queueStore: ImportQueueStore? = nil) async -> [BackgroundTransferActivity] {
        var activeTasks: [String: URLSessionTask] = [:]
        for (identifier, session) in allSessions() {
            let tasks = await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning: $0) } }
            for task in tasks { activeTasks["\(identifier):\(task.taskIdentifier)"] = task }
        }
        let bindings = await bindingStore.all()
        let completing = completionInFlightSnapshot()
        var active: [BackgroundTransferActivity] = []
        for binding in bindings {
            let run = await (queueStore ?? self.queueStore)?.run(localRunID: binding.localRunID)
            let runIsOpen = run?.state.hasOpenImport == true
            let task = activeTasks["\(binding.sessionIdentifier):\(binding.taskIdentifier)"]
            let hasTechnicalActivity = task != nil || completing.contains(binding.uploadAttemptID)
            if runIsOpen && hasTechnicalActivity {
                active.append(BackgroundTransferActivity(
                    binding: binding,
                    sentBytes: max(0, task?.countOfBytesSent ?? 0),
                    expectedBytes: max(0, task?.countOfBytesExpectedToSend ?? 0)))
            }
        }
        for activity in active {
            let binding = activity.binding
            IOSImportDiagnostics.log("task reattached taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString) sentBytes=\(activity.sentBytes) expectedBytes=\(activity.expectedBytes)")
        }
        return active
    }

    func activeBindings(queueStore: ImportQueueStore? = nil) async -> [BackgroundTaskBinding] {
        await activeTransferActivities(queueStore: queueStore).map(\.binding)
    }
    func cancelAll(for uploadAttemptID: UUID) { Task { for binding in await bindingStore.all() where binding.uploadAttemptID == uploadAttemptID { let session = binding.sessionIdentifier == Self.cellularSessionIdentifier ? self.session(allowsCellular: true) : binding.sessionIdentifier == Self.wifiSessionIdentifier ? self.session(allowsCellular: false) : self.legacySession(); session.getAllTasks { tasks in if let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) { IOSImportDiagnostics.log("background-task cancel requested reason=swift-task-cancellation session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))"); task.cancel() } } } } }
    func cancelAllForRun(_ localRunID: UUID) { Task { for binding in await bindingStore.all() where binding.localRunID == localRunID { let session = binding.sessionIdentifier == Self.cellularSessionIdentifier ? self.session(allowsCellular: true) : binding.sessionIdentifier == Self.wifiSessionIdentifier ? self.session(allowsCellular: false) : self.legacySession(); session.getAllTasks { tasks in if let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) { IOSImportDiagnostics.log("background-task cancel requested reason=user-cancel session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))"); task.cancel() } } } } }
    func cancelAll() { for (identifier, session) in allSessions() { session.getAllTasks { tasks in tasks.forEach { task in IOSImportDiagnostics.log("background-task cancel requested reason=other session=\(identifier) taskIdentifier=\(task.taskIdentifier)"); task.cancel() } } } }
    func beginComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.insert(uploadAttemptID); lock.unlock() }
    func endComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.remove(uploadAttemptID); lock.unlock() }
    private func isCompleteInFlight(_ uploadAttemptID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return completionInFlight.contains(uploadAttemptID) }
    private func completionInFlightSnapshot() -> Set<UUID> { lock.lock(); defer { lock.unlock() }; return completionInFlight }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let identifier = session.configuration.identifier ?? "unknown"
        let key = BackgroundPUTTaskKey.make(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier)
        lock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        if var diagnostic = putDiagnostics[key] {
            diagnostic.sentBytes = max(diagnostic.sentBytes, totalBytesSent)
            diagnostic.lastProgressAt = Date()
            putDiagnostics[key] = diagnostic
        }
        lock.unlock()
        updatePUTTaskState { $0.sending(key) }
        IOSImportDiagnostics.log("[BackgroundPUT] task=\(task.taskIdentifier) didSendBodyData=\(bytesSent) totalBytesSent=\(totalBytesSent) expected=\(totalBytesExpectedToSend) state=sending")
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard IOSImportDiagnostics.enabled, task.originalRequest?.httpMethod == "PUT" else { return }
        func seconds(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "unavailable" }
            return String(format: "%.3f", end.timeIntervalSince(start))
        }
        for (index, transaction) in metrics.transactionMetrics.enumerated() {
            IOSImportDiagnostics.log("[BackgroundPUT] metrics task=\(task.taskIdentifier) transaction=\(index) protocol=\(transaction.networkProtocolName ?? "unknown") queue=\(seconds(transaction.fetchStartDate, transaction.requestStartDate)) request=\(seconds(transaction.requestStartDate, transaction.requestEndDate)) responseWait=\(seconds(transaction.requestEndDate, transaction.responseStartDate)) response=\(seconds(transaction.responseStartDate, transaction.responseEndDate)) bytesSent=\(transaction.countOfRequestBodyBytesSent)")
        }
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { let identifier = session.configuration.identifier ?? "unknown"; updatePUTTaskState { $0.waiting(BackgroundPUTTaskKey.make(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier)) }; IOSImportDiagnostics.log("background-task waitingForConnectivity session=\(identifier) taskIdentifier=\(task.taskIdentifier) state=waiting") }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let identifier = session.configuration.identifier ?? "unknown"
        let key = BackgroundPUTTaskKey.make(sessionIdentifier: identifier, taskIdentifier: dataTask.taskIdentifier)
        lock.lock()
        if var diagnostic = putDiagnostics[key] {
            diagnostic.responseAt = Date()
            diagnostic.httpStatus = (response as? HTTPURLResponse)?.statusCode
            putDiagnostics[key] = diagnostic
        }
        if let http = response as? HTTPURLResponse {
            responses[dataTask.taskIdentifier] = (Data(), http)
        }
        lock.unlock()
        logPUTSnapshot(key: key, task: dataTask, event: "response")
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { lock.lock(); if let current = responses[dataTask.taskIdentifier] { responses[dataTask.taskIdentifier] = (current.0 + data, current.1) }; lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sessionIdentifier = session.configuration.identifier ?? "unknown"
        let key = BackgroundPUTTaskKey.make(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)
        updatePUTTaskState { $0.completed(key) }
        lock.lock()
        if var diagnostic = putDiagnostics[key], let http = task.response as? HTTPURLResponse {
            diagnostic.httpStatus = http.statusCode
            diagnostic.responseAt = diagnostic.responseAt ?? Date()
            putDiagnostics[key] = diagnostic
        }
        lock.unlock()
        logPUTSnapshot(key: key, task: task, event: "end", error: error, remove: true)
        lock.lock(); let continuation = continuations.removeValue(forKey: task.taskIdentifier); let response = responses.removeValue(forKey: task.taskIdentifier); progressHandlers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if let error {
            let nsError = error as NSError
            IOSImportDiagnostics.log("background-task completed session=\(sessionIdentifier) taskIdentifier=\(task.taskIdentifier) errorDomain=\(nsError.domain) errorCode=\(nsError.code)")
            Task { if let binding = await bindingStore.all().first(where: { $0.taskIdentifier == task.taskIdentifier }) { IOSImportDiagnostics.log("background-task completed correlation session=\(binding.sessionIdentifier) taskIdentifier=\(task.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)") } }
            continuation?.resume(throwing: error); return
        }
        guard let http = (task.response as? HTTPURLResponse) else { IOSImportDiagnostics.log("delegate completion taskIdentifier=\(task.taskIdentifier) error=invalid-response"); continuation?.resume(throwing: UploadError.invalidResponse); return }
        IOSImportDiagnostics.log("background-task completed session=\(sessionIdentifier) taskIdentifier=\(task.taskIdentifier) httpStatus=\(http.statusCode)")
        if http.statusCode >= 400 {
            let responseData = response?.0 ?? Data()
            let safeHeaders = Self.diagnosticHeaders(http.allHeaderFields)
            Task {
                let binding = await bindingStore.all().first { $0.taskIdentifier == task.taskIdentifier }
                let asset = binding.map { $0.queueAssetID.uuidString.prefix(8) } ?? "unknown"
                let attempt = binding.map { $0.uploadAttemptID.uuidString.prefix(8) } ?? "unknown"
                let body: String
                if responseData.isEmpty {
                    body = "<empty>"
                } else if let decoded = String(data: responseData, encoding: .utf8) {
                    let normalized = decoded.replacingOccurrences(of: "\\r", with: "\\\\r").replacingOccurrences(of: "\\n", with: "\\\\n")
                    body = normalized.count > 4096 ? String(normalized.prefix(4096)) + "…<truncated>" : normalized
                } else {
                    body = "<non-utf8 bytes=\(responseData.count)>"
                }
                IOSImportDiagnostics.log("background-task HTTP ERROR session=\(sessionIdentifier) taskIdentifier=\(task.taskIdentifier) queueAssetID=\(asset) uploadAttemptID=\(attempt) status=\(http.statusCode) responseBytes=\(responseData.count) headers=\(safeHeaders) responseBody=\(body)")
            }
            continuation?.resume(throwing: UploadError.http(http.statusCode)); return
        }
        let davResponse = DAVResponse(status: http.statusCode, data: response?.0 ?? Data(), headers: http.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) })
        Task {
            if [200, 201, 204].contains(http.statusCode), let binding = await bindingStore.all().first(where: { $0.taskIdentifier == task.taskIdentifier }) {
                try? await queueStore?.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "put-succeeded-needs-complete", targetPath: binding.targetPath)
                IOSImportDiagnostics.log("completed PUT recovered queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString) state=needsReconcile")
            }
            IOSImportDiagnostics.log("delegate completion taskIdentifier=\(task.taskIdentifier) status=\(http.statusCode)")
            continuation?.resume(returning: davResponse)
        }
    }
    private static func diagnosticHeaders(_ fields: [AnyHashable: Any]) -> String {
        let allowed = ["content-type", "content-length", "location", "dav", "server", "retry-after", "x-request-id", "request-id"]
        return fields.compactMap { key, value in
            let name = String(describing: key)
            guard allowed.contains(name.lowercased()) else { return nil }
            let safeValue = name.lowercased() == "location" ? "<redacted>" : value
            return "\(name)=\(safeValue)"
        }.sorted().joined(separator: ",")
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        IOSImportDiagnostics.log("urlSessionDidFinishEvents")
        lifecycleLock.lock(); let handler = backgroundEventsCompletionHandler; backgroundEventsCompletionHandler = nil; lifecycleLock.unlock()
        if let handler { IOSImportDiagnostics.log("background events completion handler invoked"); handler() }
    }
    func cleanup(uploadAttemptID: UUID, deleteFile: Bool) async {
        guard let binding = await bindingStore.binding(uploadAttemptID: uploadAttemptID) else { return }
        if deleteFile { try? await fileStore.remove(relativePath: binding.relativeTransferPath); IOSImportDiagnostics.log("transfer file removed uploadAttemptID=\(uploadAttemptID.uuidString) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8))") }
        else { IOSImportDiagnostics.log("transfer file retained uploadAttemptID=\(uploadAttemptID.uuidString) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8))") }
        try? await bindingStore.remove(uploadAttemptID: uploadAttemptID)
        IOSImportDiagnostics.log("binding removed uploadAttemptID=\(uploadAttemptID.uuidString) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8))")
    }
}

final class IOSPhaseReportingDAVTransport: DAVTransport, @unchecked Sendable {
    private let base: any DAVTransport
    private let onPUT: (@Sendable () async -> Void)?
    init(base: any DAVTransport, onPUT: (@Sendable () async -> Void)? = nil) {
        self.base = base
        self.onPUT = onPUT
    }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: nil) }
    func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse { try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: progress) }
    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard kind == .fileTransfer, let file else { return try await base.send(request, file: file, kind: kind, progress: progress) }
        await onPUT?()
        return try await base.send(request, file: file, kind: kind, progress: progress)
    }
}

final class IOSUploadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastUpdate = Date.distantPast

    init(minimumInterval: TimeInterval = 0.2) {
        self.minimumInterval = minimumInterval
    }

    func shouldPublish(sent: Int64, total: Int64, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard (total > 0 && sent >= total) || now.timeIntervalSince(lastUpdate) >= minimumInterval else { return false }
        lastUpdate = now
        return true
    }
}

// Retained only to decode and inspect legacy queue files in tests and future
// migrations. No production path reads or resumes these records.
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

struct IOSInventoryBatchPlan: Sendable, Equatable {
    let indices: [Int]
}

struct IOSInventoryBatchClassification: Equatable, Sendable {
    let knownIndices: [Int]
    let newIndices: [Int]

    init(reply: InventoryReply) {
        knownIndices = reply.assets.indices.filter { reply.assets[$0].state == .known }
        newIndices = reply.assets.indices.filter { reply.assets[$0].state == .new }
    }
}

struct IOSImportProgressCounts: Equatable, Sendable {
    var completed = 0
    var uploaded = 0
    var alreadyPresent = 0
    var reconciled = 0

    mutating func markInventoryKnown(_ count: Int) {
        guard count > 0 else { return }
        alreadyPresent += count
        completed += count
    }

    mutating func markUploaded() {
        uploaded += 1
        completed += 1
    }

    mutating func markReconciled(_ count: Int) {
        guard count > 0 else { return }
        reconciled += count
        completed += count
    }
}

struct IOSClientRunGeneration: Equatable, Sendable {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        current = id
        return id
    }

    mutating func cancel() {
        current = nil
    }

    func accepts(_ id: UUID) -> Bool {
        current == id
    }
}

@MainActor
enum IOSInventoryBatchFastPath {
    static func process(
        classification: IOSInventoryBatchClassification,
        markKnown: (Int) -> Void,
        scheduleNew: ([Int]) async throws -> Void
    ) async throws {
        markKnown(classification.knownIndices.count)
        try await scheduleNew(classification.newIndices)
    }
}

enum IOSInventoryBatching {
    static let maximumAssetCount = 100

    static func plan(count: Int, maximum: Int = maximumAssetCount) -> [IOSInventoryBatchPlan] {
        guard count > 0, maximum > 0 else { return [] }
        return stride(from: 0, to: count, by: maximum).map { start in
            IOSInventoryBatchPlan(indices: Array(start..<min(start + maximum, count)))
        }
    }

}

enum IOSPersistedInventory {
    static func placeholder(for asset: GalleryAsset) -> PersistedImportAsset {
        let mediaType = asset.isVideo ? "video" : "image"
        return PersistedImportAsset(
            queueAssetID: UUID(),
            stableIdentity: "local:\(asset.id)",
            localIdentifier: asset.id,
            cloudIdentifier: nil,
            mediaType: mediaType,
            filenameHint: nil,
            captureDate: asset.asset.creationDate,
            state: .queued,
            serverAssetID: nil,
            uploadID: nil,
            targetPath: nil,
            expectedBytes: nil,
            expectedSHA256: nil,
            lastConfirmedStep: "selected",
            retryCount: 0,
            lastErrorCode: nil)
    }

    static func merging(_ persisted: PersistedImportAsset, inventory: AssetInventory) -> PersistedImportAsset {
        var result = persisted
        result.stableIdentity = inventory.stableIdentity
        result.cloudIdentifier = inventory.cloudIdentifier
        result.mediaType = inventory.mediaType
        result.filenameHint = inventory.filename
        result.captureDate = inventory.creationDate
        return result
    }
}

enum IOSUploadStep: Sendable, Equatable {
    case prepare
    case webDAVPut
    case complete

    var germanName: String {
        switch self {
        case .prepare: "Upload-Vorbereitung"
        case .webDAVPut: "WebDAV-Übertragung"
        case .complete: "Upload-Abschluss"
        }
    }
}

struct IOSUploadFailure: LocalizedError, Sendable {
    let step: IOSUploadStep
    let status: Int?
    let urlErrorCode: Int?

    init(step: IOSUploadStep, status: Int) {
        self.step = step
        self.status = status
        urlErrorCode = nil
    }

    init(step: IOSUploadStep, urlErrorCode: Int) {
        self.step = step
        status = nil
        self.urlErrorCode = urlErrorCode
    }

    var errorDescription: String? {
        if status == 413 {
            return "Der Server oder ein Proxy hat die Übertragung wegen einer Größenbegrenzung abgelehnt (HTTP 413)."
        }
        if let status { return "\(step.germanName) fehlgeschlagen (HTTP \(status))." }
        if let urlErrorCode {
            let code = URLError.Code(rawValue: urlErrorCode)
            return "\(step.germanName) fehlgeschlagen: \(URLError(code).localizedDescription)"
        }
        return "\(step.germanName) fehlgeschlagen."
    }

    var diagnosticCategory: String {
        let stepName: String = switch step {
        case .prepare: "prepare"
        case .webDAVPut: "put"
        case .complete: "complete"
        }
        if let status { return "step=\(stepName) httpStatus=\(status)" }
        if let urlErrorCode { return "step=\(stepName) urlError=\(urlErrorCode)" }
        return "step=\(stepName) error=unknown"
    }

    static func preserving(step: IOSUploadStep, from error: Error) -> Error {
        if error is IOSUploadFailure { return error }
        if let urlError = error as? URLError {
            return IOSUploadFailure(step: step, urlErrorCode: urlError.code.rawValue)
        }
        if case let UploadError.http(status) = error {
            return IOSUploadFailure(step: step, status: status)
        }
        if case let UploadError.server(serverError) = error {
            return IOSUploadFailure(step: step, status: serverError.status)
        }
        return error
    }
}

enum InventoryCheckClient {
    static func check(connection: ConnectorConnection, source: PhotoSource, assets: [AssetInventory], batchNumber: Int? = nil, transport: (any DAVTransport)? = nil) async throws -> InventoryReply {
        guard !assets.isEmpty else { throw InventoryCheckError.invalidResponse }
        let payloadBuildStarted = ContinuousClock.now
        let json = try InventoryJSON.encode(assets, source: source)
        let payloadBuildDuration = payloadBuildStarted.duration(to: .now)
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let requestStarted = ContinuousClock.now
        let phase = IOSImportDiagnostics.start("asset-inventory")
        let requestMethod = request.httpMethod ?? "<missing>"
        let endpoint = safeEndpoint(request)
        IOSImportDiagnostics.log("inventory.request method=\(requestMethod) endpoint=\(endpoint) batch=\(batchNumber.map(String.init) ?? "unknown") assets=\(assets.count) requestBytes=\(request.httpBody?.count ?? 0)")
        let requestTransport = transport ?? NetworkTransport(allowsCellularAccess: true, waitsForConnectivity: false, responseDiagnostics: { response in
            Self.logInventoryResponse(response)
        })
        let response: DAVResponse
        do {
            response = try await requestTransport.send(request, file: nil)
            IOSImportDiagnostics.finish("asset-inventory", started: phase, detail: "method=\(requestMethod) endpoint=\(endpoint) status=\(response.status)")
        }
        catch let error {
            IOSImportDiagnostics.log("inventory.request ERROR method=\(requestMethod) endpoint=\(endpoint) duration=\(requestStarted.duration(to: .now)) \(diagnosticError(error))")
            IOSImportDiagnostics.failure("asset-inventory", started: phase, error: error)
            if case let UploadError.http(status) = error {
            if status == 401 || status == 403 { throw InventoryCheckError.authenticationFailed }
            if status == 404 { throw InventoryCheckError.endpointUnavailable }
            if status >= 500 { throw InventoryCheckError.endpointUnavailable }
            throw InventoryCheckError.invalidResponse
            }
            throw InventoryCheckError.network
        }
        Self.logInventoryResponse(response)
        guard (200..<300).contains(response.status) else {
            IOSImportDiagnostics.log("inventory.response ERROR method=\(requestMethod) endpoint=\(endpoint) status=\(response.status) duration=\(requestStarted.duration(to: .now)) errorDomain=HTTP errorCode=\(response.status)")
            throw InventoryCheckError.invalidResponse
        }
        let decoded: InventoryReply
        do {
            decoded = try JSONDecoder().decode(InventoryReply.self, from: response.data)
        } catch let error as DecodingError {
            IOSImportDiagnostics.log("inventory.response ERROR method=\(requestMethod) endpoint=\(endpoint) status=\(response.status) duration=\(requestStarted.duration(to: .now)) errorDomain=Swift.DecodingError errorCode=0")
            IOSImportDiagnostics.log(Self.decodingDiagnostic(error))
            throw InventoryCheckError.invalidResponse
        } catch {
            IOSImportDiagnostics.log("inventory.response ERROR method=\(requestMethod) endpoint=\(endpoint) status=\(response.status) duration=\(requestStarted.duration(to: .now)) \(diagnosticError(error))")
            IOSImportDiagnostics.log("Inventory decoding failed error=\(String(describing: type(of: error)))")
            throw InventoryCheckError.invalidResponse
        }
        let responseNew = decoded.assets.filter { $0.state == .new }.count
        let responseKnown = decoded.assets.filter { $0.state == .known }.count
        let batchLabel = batchNumber.map { String($0) } ?? "unknown"
        IOSImportDiagnostics.log("inventory.response-metrics batchNumber=\(batchLabel) requestAssetCount=\(assets.count) responseAssetCount=\(decoded.assets.count) responseKnownCount=\(responseKnown) responseNewCount=\(responseNew) payloadBuildDuration=\(payloadBuildDuration) inventoryRequestDuration=\(requestStarted.duration(to: .now))")
        IOSImportDiagnostics.log("Inventory response assets=\(decoded.assets.count) summary.seen=\(decoded.summary.seen) summary.new=\(decoded.summary.new) summary.known=\(decoded.summary.known) calculated.new=\(responseNew) calculated.known=\(responseKnown) requestAssets=\(assets.count)")
        guard decoded.assets.count == assets.count else {
            IOSImportDiagnostics.log("Inventory validation failed reason=asset-count request=\(assets.count) response=\(decoded.assets.count)")
            throw InventoryCheckError.invalidResponse
        }
        guard decoded.summary.seen == assets.count else {
            IOSImportDiagnostics.log("Inventory validation failed reason=summary-seen request=\(assets.count) summary.seen=\(decoded.summary.seen)")
            throw InventoryCheckError.invalidResponse
        }
        guard decoded.summary.new == responseNew else {
            IOSImportDiagnostics.log("Inventory validation failed reason=summary-new summary.new=\(decoded.summary.new) calculated.new=\(responseNew)")
            throw InventoryCheckError.invalidResponse
        }
        guard decoded.summary.known == responseKnown else {
            IOSImportDiagnostics.log("Inventory validation failed reason=summary-known summary.known=\(decoded.summary.known) calculated.known=\(responseKnown)")
            throw InventoryCheckError.invalidResponse
        }
        guard decoded.summary.new + decoded.summary.known == decoded.summary.seen else {
            IOSImportDiagnostics.log("Inventory validation failed reason=summary-total new=\(decoded.summary.new) known=\(decoded.summary.known) seen=\(decoded.summary.seen)")
            throw InventoryCheckError.invalidResponse
        }
        return decoded
    }

    static func logInventoryResponse(_ response: DAVResponse) {
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "<missing>"
        let allowedHeaders = Set(["content-type", "content-length", "location", "server", "dav"])
        let headers = response.headers.compactMap { key, value in
            guard allowedHeaders.contains(key.lowercased()) else { return nil }
            let safeValue: String
            if key.lowercased() == "location", let components = URLComponents(string: value) {
                var sanitized = components
                sanitized.user = nil
                sanitized.password = nil
                sanitized.query = nil
                sanitized.fragment = nil
                safeValue = sanitized.string ?? "<redacted>"
            } else {
                safeValue = value
            }
            return "\(key)=\(safeValue)"
        }.sorted().joined(separator: ",")
        IOSImportDiagnostics.log("Inventory HTTP \(response.status) headers=\(headers) responseBytes=\(response.data.count)")
        if !(200..<300).contains(response.status) {
            IOSImportDiagnostics.log("HTTP response body=\(safeResponseBody(response.data))")
            logServerError(response.data, contentType: contentType)
        }
    }

    private static func safeEndpoint(_ request: URLRequest) -> String {
        guard let url = request.url else { return "<missing>" }
        return url.path.isEmpty ? "/" : url.path
    }

    private static func diagnosticError(_ error: Error) -> String {
        if case let UploadError.http(status) = error {
            return "errorDomain=UploadError errorCode=http-\(status) httpStatus=\(status)"
        }
        let nsError = error as NSError
        var detail = "errorDomain=\(nsError.domain) errorCode=\(nsError.code)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += " underlyingDomain=\(underlying.domain) underlyingCode=\(underlying.code)"
        }
        return detail
    }

    private static func safeResponseBody(_ data: Data, limit: Int = 4096) -> String {
        guard !data.isEmpty else { return "<empty>" }
        guard var body = String(data: data, encoding: .utf8) else { return "<non-utf8 bytes=\(data.count)>" }
        body = body.replacingOccurrences(of: "(?i)(authorization|password|token|cookie|secret)(\\s*[:=]\\s*)([^\\s,;\"'<>]+)", with: "$1$2<redacted>", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "(?i)Basic\\s+[A-Za-z0-9+/=]+", with: "Basic <redacted>", options: [.regularExpression, .caseInsensitive])
        let normalized = body.replacingOccurrences(of: "\\r", with: "\\\\r").replacingOccurrences(of: "\\n", with: "\\\\n")
        return normalized.count > limit ? String(normalized.prefix(limit)) + "…<truncated>" : normalized
    }

    private static func logServerError(_ data: Data, contentType: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            IOSImportDiagnostics.log("error body decoding failed Content-Type: \(contentType) Response bytes: \(data.count)")
            return
        }
        if let error = object["error"] as? String {
            IOSImportDiagnostics.log("Server error: \(safeResponseBody(Data(error.utf8), limit: 1024))")
        }
        else { IOSImportDiagnostics.log("error body decoding failed Content-Type: \(contentType) Response bytes: \(data.count)") }
        if let runId = object["runId"] as? String { IOSImportDiagnostics.log("Inventory server runIdPrefix=\(runId.prefix(8))") }
    }

    private static func decodingDiagnostic(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context): return "Inventory decoding failed typeMismatch codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debugDescription=\(context.debugDescription)"
        case .valueNotFound(_, let context): return "Inventory decoding failed valueNotFound codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debugDescription=\(context.debugDescription)"
        case .keyNotFound(let key, let context): return "Inventory decoding failed keyNotFound codingPath=\((context.codingPath + [key]).map(\.stringValue).joined(separator: ".")) debugDescription=\(context.debugDescription)"
        case .dataCorrupted(let context): return "Inventory decoding failed dataCorrupted codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debugDescription=\(context.debugDescription)"
        @unknown default: return "Inventory decoding failed unknown"
        }
    }
}

enum IOSUploadPath {
    static func folder(base: String, date: Date) -> (root: String, folder: String)? {
        let root = IOSTargetDirectoryPreferences.normalize(base)
        guard !root.isEmpty else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let folder = "\(root)/\(calendar.component(.year, from: date))/\(String(format: "%02d", calendar.component(.month, from: date)))"
        return (root, folder)
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
    struct CollectedResult<Result: Sendable>: Sendable {
        let index: Int
        let result: Result?
        let errorDescription: String?
        let isFatalServerError: Bool
    }

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

    static func runCollectingFailures<Result: Sendable>(count: Int, maxConcurrent: Int = 2, operation: @escaping @Sendable (Int) async throws -> Result) async throws -> [CollectedResult<Result>] {
        guard count >= 0, maxConcurrent > 0 else { return [] }
        return try await withThrowingTaskGroup(of: CollectedResult<Result>.self) { group in
            var results: [CollectedResult<Result>] = []
            var next = 0
            var running = 0
            try Task.checkCancellation()
            func launch(_ index: Int) {
                group.addTask {
                    do {
                        return CollectedResult(index: index, result: try await operation(index), errorDescription: nil, isFatalServerError: false)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let isFatalServerError: Bool
                        if let failure = error as? IOSUploadFailure {
                            isFatalServerError = (failure.status ?? 0) >= 500
                        } else if case let UploadError.http(status) = error {
                            isFatalServerError = status >= 500
                        } else {
                            isFatalServerError = false
                        }
                        return CollectedResult(index: index, result: nil, errorDescription: error.localizedDescription, isFatalServerError: isFatalServerError)
                    }
                }
                running += 1
            }
            var stopLaunching = false
            while next < count && running < maxConcurrent { launch(next); next += 1 }
            while running > 0 {
                try Task.checkCancellation()
                guard let result = try await group.next() else { break }
                results.append(result)
                running -= 1
                if result.isFatalServerError { stopLaunching = true }
                if !stopLaunching, next < count { launch(next); next += 1 }
            }
            return results.sorted { $0.index < $1.index }
        }
    }
}

actor IOSImportWorkerLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active = max(0, active - 1)
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
    @Published private(set) var progressCounts = IOSImportProgressCounts()
    var completed: Int { progressCounts.completed }
    @Published private(set) var total = 0
    var uploaded: Int { progressCounts.uploaded }
    var alreadyPresent: Int { progressCounts.alreadyPresent }
    var reconciled: Int { progressCounts.reconciled }
    @Published private(set) var transferSentBytes: Int64 = 0
    @Published private(set) var transferTotalBytes: Int64 = 0
    @Published private(set) var failure: String?
    @Published private(set) var isWaitingForWiFi = false
    private var isServerUnreachableFailure = false
    private var task: Task<Void, Never>?
    private var clientRunGeneration = IOSClientRunGeneration()
    private var transferProgress = IOSImportProgressAggregation()
    private var pendingCompletion = Set<Int>()
    private var diagnosticJobPhases: [Int: (phase: IOSImportJobPhase, started: ContinuousClock.Instant, lane: Int)] = [:]
    private var diagnosticJobAssets: [Int: String] = [:]
    private var lastRenderedTransferSlotsSignature: String?

    nonisolated static func completedAssetCount(in run: PersistedImportRun) -> Int {
        run.assets.reduce(into: 0) { count, asset in
            if asset.state == .completed { count += 1 }
        }
    }

    nonisolated static func resumeInventoryState(localState: ImportAssetState, serverState: InventoryAssetReply.State) -> ImportAssetState? {
        if localState == .completed { return nil }
        return serverState == .known ? .completed : .needsPrepare
    }
    var overallProgress: Double {
        guard total > 0 else { return 0 }
        if completed >= total { return 1 }
        return min(0.999, (Double(completed + pendingCompletion.count) + transferProgress.activeFraction) / Double(total))
    }
    var isRunning: Bool { ![.idle, .finished, .failed, .cancelled].contains(phase) }
    var activeTransfers: [(slot: Int, job: Int, filename: String?, mediaType: String?, sent: Int64, total: Int64, phase: IOSImportJobPhase)] { transferProgress.activeEntries }
    /// Fixed two-lane snapshot consumed by the UI. Free lanes are explicit.
    var transferSlots: [IOSImportTransferSlot] {
        transferProgress.slotEntries(assetPrefixes: diagnosticJobAssets.mapValues { $0.prefix(8).description })
    }
    /// The server-side verification is only the visible phase when no other
    /// asset is still sending PUT bytes.
    var isVerifyingCompletedUpload: Bool {
        Self.isVerifyingCompletedUpload(pendingCompletionCount: pendingCompletion.count, activeTransferCount: transferProgress.activeEntries.count)
    }
    static func isVerifyingCompletedUpload(pendingCompletionCount: Int, activeTransferCount: Int) -> Bool {
        pendingCompletionCount > 0 && activeTransferCount == 0
    }

    static func restoredProgressCounts(in run: PersistedImportRun) -> IOSImportProgressCounts {
        var counts = IOSImportProgressCounts()
        for asset in run.assets where asset.state == .completed {
            switch asset.lastConfirmedStep {
            case "inventory-known": counts.markInventoryKnown(1)
            case "complete-confirmed": counts.markUploaded()
            case "content-reconciled": counts.markReconciled(1)
            default: counts.completed += 1
            }
        }
        return counts
    }

    private enum AssetJobOutcome: Sendable {
        case known
        case uploaded
        case reconciled
        case completed
    }

    func cancel() {
        IOSImportDiagnostics.memory(phase: "import-cancel-requested")
        IOSImportDiagnostics.log("cancel requested")
        let cancelledTask = task
        clientRunGeneration.cancel()
        task = nil
        phase = .cancelled
        cancelledTask?.cancel()
        isWaitingForWiFi = false
        pendingCompletion.removeAll()
        diagnosticJobPhases.removeAll()
        diagnosticJobAssets.removeAll()
        lastRenderedTransferSlotsSignature = nil
        isServerUnreachableFailure = false
        transferProgress = IOSImportProgressAggregation()
        transferSentBytes = 0
        transferTotalBytes = 0
        currentFilename = nil
        IOSImportDiagnostics.log("cancel swift-task")
    }

    func start(selection: [GalleryAsset], library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: (any DAVTransport)? = nil, onAssetCompleted: @escaping @MainActor (String) -> Void = { _ in }) {
        IOSImportDiagnostics.announceIfEnabled()
        IOSImportDiagnostics.memory(phase: "import-start")
        cancel()
        let clientRunID = clientRunGeneration.begin()
        // A new foreground session is created for every user-started run. It
        // fails normally when connectivity is lost and is never reattached.
        let importTransport = IOSImportTransportFactory.make(base: transport) { [weak self] waiting in
            Task { @MainActor in
                guard self?.clientRunGeneration.accepts(clientRunID) == true else { return }
                self?.isWaitingForWiFi = waiting && !IOSTransferNetworkPreferences.useCellularAccess()
            }
        }
        isWaitingForWiFi = false; phase = .inventory; failure = nil; isServerUnreachableFailure = false; progressCounts = IOSImportProgressCounts(); transferProgress = IOSImportProgressAggregation(); pendingCompletion = []; diagnosticJobPhases = [:]; diagnosticJobAssets = [:]; lastRenderedTransferSlotsSignature = nil; transferSentBytes = 0; transferTotalBytes = 0; total = selection.count
        let targetRootSnapshot = IOSTargetDirectoryPreferences.normalize(targetRoot)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let folderCoordinator = WebDAVFolderCoordinator()
                let jobIDs = selection.map { _ in UUID() }
                let inventoryBatches = IOSInventoryBatching.plan(count: selection.count)
                let batchSelections = inventoryBatches.map { batch in batch.indices.map { selection[$0] } }
                let workerLimiter = IOSImportWorkerLimiter(limit: 2)
                var uploadTasks: [Task<Void, Error>] = []
                var inventoriedAssets = Array<AssetInventory?>(repeating: nil, count: selection.count)
                var inventoryTask = batchSelections.first.map { batchSelection in
                    Task { try await library.inventoryInBackground(for: batchSelection) }
                }
                defer { inventoryTask?.cancel() }
                for (batchNumber, batch) in inventoryBatches.enumerated() {
                    try Task.checkCancellation()
                    self.setPhase(.inventory)
                    let batchSelection = batchSelections[batchNumber]
                    let inventoryPhase = IOSImportDiagnostics.start("asset-inventory-build[\(batchNumber + 1)]")
                    let batchAssets: [AssetInventory]
                    do {
                        guard let currentInventoryTask = inventoryTask else { throw InventoryCheckError.unavailableAsset }
                        batchAssets = try await currentInventoryTask.value
                        IOSImportDiagnostics.finish("asset-inventory-build[\(batchNumber + 1)]", started: inventoryPhase, detail: "assets=\(batchAssets.count)")
                    } catch {
                        IOSImportDiagnostics.failure("asset-inventory-build[\(batchNumber + 1)]", started: inventoryPhase, error: error)
                        throw error
                    }
                    let nextBatchNumber = batchNumber + 1
                    inventoryTask = batchSelections.indices.contains(nextBatchNumber) ? Task {
                        try await library.inventoryInBackground(for: batchSelections[nextBatchNumber])
                    } : nil
                    for (batchIndex, globalIndex) in batch.indices.enumerated() {
                        inventoriedAssets[globalIndex] = batchAssets[batchIndex]
                    }
                    IOSImportDiagnostics.log("inventory-batch index=\(batchNumber + 1)/\(inventoryBatches.count) assets=\(batchAssets.count)")
                    let reply = try await InventoryCheckClient.check(connection: connection, source: source, assets: batchAssets, batchNumber: batchNumber + 1, transport: importTransport)
                    self.markServerReachable()
                    let classification = IOSInventoryBatchClassification(reply: reply)
                    IOSImportDiagnostics.log("inventory-classification batchNumber=\(batchNumber + 1) batchCount=\(inventoryBatches.count) requestAssetCount=\(batchAssets.count) responseKnownCount=\(classification.knownIndices.count) responseNewCount=\(classification.newIndices.count) schedulerAssetCount=\(classification.newIndices.count) bulkUpdateCallCount=1 persistenceWriteCount=1")
                    for index in classification.knownIndices {
                        onAssetCompleted(batchSelection[index].id)
                    }
                    try await IOSInventoryBatchFastPath.process(
                        classification: classification,
                        markKnown: { count in
                            let started = IOSImportDiagnostics.start("known.bulkUpdate batchNumber=\(batchNumber + 1)")
                            self.markAlready(count: count, source: "inventory-bulk")
                            IOSImportDiagnostics.finish("known.bulkUpdate batchNumber=\(batchNumber + 1)", started: started, detail: "knownCount=\(count) bulkUpdateCallCount=1 progressPublishCount=\(count > 0 ? 1 : 0)")
                        },
                        scheduleNew: { newIndices in
                            self.setPhase(.uploading)
                            IOSImportDiagnostics.log("upload.queue.ready batch=\(batchNumber + 1) assets=\(newIndices.count) activeSlots=\(self.transferProgress.activeEntries.count)")
                            let uploadTask = Task {
                                try await self.runAssetJobs(
                                    selection: batchSelection,
                                    assets: batchAssets,
                                    reply: reply,
                                    newIndices: newIndices,
                                    library: library,
                                    connection: connection,
                                    source: source,
                                    targetRoot: targetRootSnapshot,
                                    transport: importTransport,
                                    folderCoordinator: folderCoordinator,
                                    clientRunID: clientRunID,
                                    jobIDs: batch.indices.map { jobIDs[$0] },
                                    workerLimiter: workerLimiter,
                                    onAssetCompleted: onAssetCompleted)
                            }
                            uploadTasks.append(uploadTask)
                        })
                }
                do {
                    for uploadTask in uploadTasks { try await uploadTask.value }
                } catch {
                    uploadTasks.forEach { $0.cancel() }
                    throw error
                }
                let assets = inventoriedAssets.compactMap { $0 }
                guard assets.count == selection.count else { throw InventoryCheckError.unavailableAsset }
                self.setPhase(.completing)
                let albumBuild = IOSImportDiagnostics.start("album-inventory-build")
                let albums: [AlbumInventory]
                do { albums = try library.albumInventory(); IOSImportDiagnostics.finish("album-inventory-build", started: albumBuild, detail: "albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })") }
                catch { IOSImportDiagnostics.failure("album-inventory-build", started: albumBuild, error: error); throw error }
                try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: importTransport)
                guard self.clientRunGeneration.accepts(clientRunID) else { return }
                self.finish()
            } catch is CancellationError {
                IOSImportDiagnostics.memory(phase: "import-task-cancelled")
                guard self.clientRunGeneration.accepts(clientRunID) else { return }
                self.cancelled()
            } catch {
                guard self.clientRunGeneration.accepts(clientRunID) else { return }
                let activeUploadProgress = !self.transferProgress.activeEntries.isEmpty
                if IOSImportServerStatusPolicy.isNetworkError(error), activeUploadProgress {
                    self.failure = IOSImportServerStatusPolicy.message(for: error, activeUploadProgress: true)
                    self.isServerUnreachableFailure = false
                } else {
                    self.failed(error.localizedDescription, serverUnreachable: IOSImportServerStatusPolicy.isNetworkError(error))
                }
            }
        }
    }

    private func runAssetJobs(selection: [GalleryAsset], assets: [AssetInventory], reply: InventoryReply, newIndices: [Int], library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: any DAVTransport, folderCoordinator: WebDAVFolderCoordinator, clientRunID: UUID, jobIDs: [UUID], workerLimiter: IOSImportWorkerLimiter, onAssetCompleted: @escaping @MainActor (String) -> Void) async throws {
        guard newIndices.allSatisfy(selection.indices.contains) else { throw InventoryCheckError.invalidResponse }
        guard jobIDs.count == selection.count else { throw InventoryCheckError.invalidResponse }
        let jobIndices = newIndices
        IOSImportDiagnostics.log("asset-scheduler START jobs=\(jobIndices.count) new=\(newIndices.count) workerLimit=2")
        let outcomes = try await IOSAssetJobScheduler.runCollectingFailures(count: jobIndices.count, maxConcurrent: 2) { [weak self] jobIndex in
            guard let self else { throw CancellationError() }
            let index = jobIndices[jobIndex]
            let selected = selection[index]
            let asset = assets[index]
            let entry = reply.assets[index]
            guard await self.isCurrentRun(clientRunID) else { throw CancellationError() }
            IOSImportDiagnostics.log("upload.queue.dispatch job=\(index + 1) status=waiting-for-slot")
            await workerLimiter.acquire()
            IOSImportDiagnostics.log("upload.queue.dispatch job=\(index + 1) status=slot-acquired")
            defer { Task { await workerLimiter.release() } }
            await self.beginTransfer(job: index, assetID: jobIDs[index].uuidString, asset: selected.asset, filename: asset.filename, mediaType: asset.mediaType)
            IOSImportDiagnostics.log("upload.start asset=\(jobIDs[index].uuidString.prefix(8)) job=\(index + 1) filename=\(asset.filename ?? "<unnamed>")")
            IOSImportDiagnostics.log("asset-job[\(index + 1)] START")
            let started = ContinuousClock.now
            IOSImportDiagnostics.memory(phase: "asset-job-start", asset: jobIDs[index].uuidString, job: index + 1)
            do {
                let outcome = try await self.runAssetJob(index: index, selected: selected, asset: asset, entry: entry, reply: reply, library: library, connection: connection, source: source, targetRoot: targetRoot, transport: transport, folderCoordinator: folderCoordinator, clientRunID: clientRunID, jobID: jobIDs[index])
                await self.finishTransfer(job: index, assetID: jobIDs[index].uuidString, clientRunID: clientRunID, result: "success")
                IOSImportDiagnostics.memory(phase: "asset-job-end", asset: jobIDs[index].uuidString, job: index + 1)
                IOSImportDiagnostics.log("asset-job[\(index + 1)] OK elapsed=\(started.duration(to: .now))")
                return (index, outcome)
            } catch is CancellationError {
                await self.finishTransfer(job: index, assetID: jobIDs[index].uuidString, clientRunID: clientRunID, result: "cancelled", error: CancellationError())
                IOSImportDiagnostics.memory(phase: "asset-job-cancelled", asset: jobIDs[index].uuidString, job: index + 1)
                throw CancellationError()
            } catch {
                await self.finishTransfer(job: index, assetID: jobIDs[index].uuidString, clientRunID: clientRunID, result: "failure", error: error)
                IOSImportDiagnostics.memory(phase: "asset-job-error", asset: jobIDs[index].uuidString, job: index + 1)
                IOSImportDiagnostics.log("asset-job[\(index + 1)] ERROR elapsed=\(started.duration(to: .now)) error=\(String(describing: type(of: error)))")
                throw error
            }
        }
        var failures: [String] = []
        var reconciledCount = 0
        for outcome in outcomes {
            if let result = outcome.result {
                self.apply(result.1, job: result.0)
                onAssetCompleted(selection[result.0].id)
                if case .reconciled = result.1 { reconciledCount += 1 }
            } else {
                var message = outcome.errorDescription ?? "Asset-Import fehlgeschlagen."
                if outcome.isFatalServerError {
                    message += " Andere bereits laufende Übertragungen werden noch beendet; der Import wird anschließend angehalten."
                }
                failures.append(message)
            }
        }
        self.markReconciled(count: reconciledCount)
        if let firstFailure = failures.first {
            throw UploadError.diagnostic(firstFailure)
        }
        IOSImportDiagnostics.log("asset-scheduler END jobs=\(jobIndices.count) completed=\(outcomes.count)")
    }

    private func runAssetJob(index: Int, selected: GalleryAsset, asset: AssetInventory, entry: InventoryAssetReply, reply: InventoryReply, library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: any DAVTransport, folderCoordinator: WebDAVFolderCoordinator, clientRunID: UUID, jobID: UUID) async throws -> AssetJobOutcome {
        try Task.checkCancellation()
        guard clientRunGeneration.accepts(clientRunID) else { throw CancellationError() }
        guard reply.assets.indices.contains(index) else { throw InventoryCheckError.invalidResponse }
        let queueAssetID = jobID
        if entry.state == .known { throw InventoryCheckError.invalidResponse }
        guard let ticket = entry.upload else { throw InventoryCheckError.invalidResponse }
        IOSImportDiagnostics.log("asset-job[\(index + 1)] resource-selection START")
        IOSImportDiagnostics.memory(phase: "photo-export-start", asset: queueAssetID.uuidString, job: index + 1)
        let exportPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] photo-original-export")
        let exported: PhotoLibraryModel.ExportedOriginal
        do { exported = try await library.exportOriginal(for: selected, diagnosticAssetID: queueAssetID.uuidString, diagnosticJob: index + 1) { [weak self] phase in
            guard await self?.isCurrentRun(clientRunID) == true else { return }
            await self?.transitionJob(index, to: phase)
        }; IOSImportDiagnostics.memory(phase: "photo-export-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] photo-original-export", started: exportPhase, detail: "bytes=pending") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] photo-original-export", started: exportPhase, error: error); throw error }
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        try Task.checkCancellation()
        guard clientRunGeneration.accepts(clientRunID) else { throw CancellationError() }
        transitionJob(index, to: .hashing)
        let hashPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] sha256"); IOSImportDiagnostics.memory(phase: "sha256-start", asset: queueAssetID.uuidString, job: index + 1)
        let identity: ContentIdentity
        do {
            let hashTask = Task.detached {
                #if DEBUG
                return try ContentIdentity.read(exported.url) { event in
                    switch event {
                    case .begin: IOSImportDiagnostics.memory(phase: "sha256-read-begin", asset: queueAssetID.uuidString, job: index + 1)
                    case .progress(let bytes): IOSImportDiagnostics.memory(phase: "sha256-progress", asset: queueAssetID.uuidString, job: index + 1, readMiB: Double(bytes) / (1024.0 * 1024.0))
                    case .end: IOSImportDiagnostics.memory(phase: "sha256-read-end", asset: queueAssetID.uuidString, job: index + 1)
                    }
                }
                #else
                return try ContentIdentity.read(exported.url)
                #endif
            }
            identity = try await withTaskCancellationHandler {
                try await hashTask.value
            } onCancel: {
                hashTask.cancel()
            }
            IOSImportDiagnostics.memory(phase: "sha256-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] sha256", started: hashPhase, detail: "bytes=\(identity.bytes)")
        }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] sha256", started: hashPhase, error: error); throw error }
        try Task.checkCancellation()
        guard clientRunGeneration.accepts(clientRunID) else { throw CancellationError() }
        let date = selected.creationDate
        guard let uploadPath = IOSUploadPath.folder(base: targetRoot, date: date) else { throw UploadError.invalidConfiguration }
        let folder = uploadPath.folder
        let provider = IOSUploadTargets(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, folder: folder) { [weak self] in
            guard await self?.isCurrentRun(clientRunID) == true else { return }
            await self?.transitionJob(index, to: .prepare)
        }
        transitionJob(index, to: .prepare)
        IOSImportDiagnostics.log("asset-job[\(index + 1)] prepare-request START")
        IOSImportDiagnostics.memory(phase: "prepare-start", asset: queueAssetID.uuidString, job: index + 1)
        let putPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] webdav-transfer")
        IOSImportDiagnostics.log("upload.put.begin asset=\(queueAssetID.uuidString.prefix(8)) job=\(index + 1) filename=\(exported.filename) expectedBytes=\(identity.bytes) status=active")
        let target: UploadTarget
        let uploadTransport = IOSPhaseReportingDAVTransport(base: transport) { [weak self] in
            guard await self?.isCurrentRun(clientRunID) == true else { return }
            await self?.transitionJob(index, to: .put)
        }
        let progressThrottle = IOSUploadProgressThrottle()
        let uploader = WebDAVUploader(connection: connection, transport: uploadTransport, debug: { message in IOSImportDiagnostics.log(message) }, folderCoordinator: folderCoordinator)
        do { target = try await uploader.uploadWithTarget(file: exported.url, filename: exported.filename, assetId: ticket.assetId, captureDate: date, targets: provider, targetRoot: uploadPath.root, progress: { [weak self] sent, total in
            guard progressThrottle.shouldPublish(sent: sent, total: total) else { return }
            Task { @MainActor in
                guard self?.clientRunGeneration.accepts(clientRunID) == true else { return }
                self?.updateTransferProgress(assetID: queueAssetID.uuidString, job: index, filename: exported.filename, sent: sent, total: total)
            }
        }, contentIdentityDiagnostics: { event in
            switch event {
            case .begin: IOSImportDiagnostics.memory(phase: "sha256-read-begin", asset: queueAssetID.uuidString, job: index + 1)
            case .progress(let bytes): IOSImportDiagnostics.memory(phase: "sha256-progress", asset: queueAssetID.uuidString, job: index + 1, readMiB: Double(bytes) / (1024.0 * 1024.0))
            case .end: IOSImportDiagnostics.memory(phase: "sha256-read-end", asset: queueAssetID.uuidString, job: index + 1)
            }
        }, contentIdentity: identity); IOSImportDiagnostics.memory(phase: "prepare-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] webdav-transfer", started: putPhase, detail: "bytes=\(identity.bytes)") }
        catch {
            IOSImportDiagnostics.failure("asset-job[\(index + 1)] webdav-transfer", started: putPhase, error: error)
            throw IOSUploadFailure.preserving(step: .webDAVPut, from: error)
        }
        try Task.checkCancellation()
        guard clientRunGeneration.accepts(clientRunID) else { throw CancellationError() }
        if target.state == "contentAlreadyPresent" { transitionJob(index, to: .reconciliation); return .reconciled }
        pendingCompletion.insert(index)
        transferProgress.remove(job: index)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
        try Task.checkCancellation()
        transitionJob(index, to: .complete)
        do {
            try await IOSUploadHTTP.complete(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: target.path, queueAssetID: queueAssetID)
        } catch {
            pendingCompletion.remove(index)
            throw error
        }
        pendingCompletion.remove(index)
        self.markUploaded()
        return .uploaded
    }

    private func apply(_ outcome: AssetJobOutcome, job: Int) {
        pendingCompletion.remove(job)
        clearTransfer(job: job)
        switch outcome {
        case .known, .uploaded, .reconciled, .completed: break
        }
    }

    private func clearTransfer(job: Int) {
        transferProgress.remove(job: job)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
    }

    private func isCurrentRun(_ clientRunID: UUID) -> Bool {
        clientRunGeneration.accepts(clientRunID)
    }

    private func transitionJob(_ job: Int, to phase: IOSImportJobPhase) {
        let activeJobs = diagnosticJobPhases[job] == nil ? diagnosticJobPhases.count + 1 : diagnosticJobPhases.count
        let visibleRows = transferProgress.activeEntries.count
        let lane = transferProgress.slot(for: job).map { $0 + 1 } ?? 0
        transferProgress.setPhase(job: job, phase: phase)
        IOSImportDiagnostics.log("upload.phase asset=\(diagnosticJobAssets[job]?.prefix(8) ?? "unknown") job=\(job + 1) lane=\(lane) phase=\(phase.rawValue) visibleSlots=\(visibleRows)")
        logTransferSlots(event: "phase-\(phase.rawValue)")
        if let previous = diagnosticJobPhases[job] {
            guard previous.phase != phase else { return }
            IOSImportDiagnostics.jobPhaseFinished(lane: previous.lane, phase: previous.phase, started: previous.started, result: "success", activeJobs: activeJobs, visibleRows: visibleRows)
        }
        diagnosticJobPhases[job] = (phase, .now, lane)
        IOSImportDiagnostics.jobPhaseStarted(lane: lane, phase: phase, activeJobs: activeJobs, visibleRows: visibleRows)
    }

    private func finishTransfer(job: Int, assetID: String, clientRunID: UUID, result: String, error: Error? = nil) {
        guard clientRunGeneration.accepts(clientRunID) else { return }
        let activeEntry = transferProgress.activeEntries.first { $0.job == job }
        let remainingJobs = max(0, diagnosticJobPhases.count - 1)
        if let current = diagnosticJobPhases.removeValue(forKey: job) {
            IOSImportDiagnostics.jobPhaseFinished(lane: current.lane, phase: current.phase, started: current.started, result: result, activeJobs: remainingJobs, visibleRows: max(0, transferProgress.activeEntries.count - 1), error: error)
        }
        IOSImportDiagnostics.log("upload.finish asset=\(assetID.prefix(8)) job=\(job + 1) slot=\(activeEntry.map { $0.slot + 1 } ?? 0) filename=\(activeEntry?.filename ?? "<unnamed>") sentBytes=\(activeEntry?.sent ?? 0) expectedBytes=\(activeEntry?.total ?? 0) status=\(result)")
        if result == "success" { markServerReachable() }
        diagnosticJobAssets.removeValue(forKey: job)
        clearTransfer(job: job)
        logTransferSlots(event: "finish-\(result)")
    }

    private func updateTransferProgress(assetID: String, job: Int, filename: String, sent: Int64, total: Int64) {
        guard transferProgress.slot(for: job) != nil else {
            IOSImportDiagnostics.log("upload.progress.ignored asset=\(assetID.prefix(8)) job=\(job + 1) filename=\(filename) sentBytes=\(sent) expectedBytes=\(total) reason=inactive")
            return
        }
        transferProgress.update(job: job, filename: filename, sent: sent, total: total)
        markServerReachable()
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
        let slot = transferProgress.slot(for: job).map { $0 + 1 } ?? 0
        IOSImportDiagnostics.log("upload.progress asset=\(assetID.prefix(8)) job=\(job + 1) slot=\(slot) filename=\(filename) sentBytes=\(sent) expectedBytes=\(total) status=active")
    }

    private func setCurrent(_ asset: PHAsset, filename: String?) { currentFilename = filename ?? asset.localIdentifier }
    private func beginTransfer(job: Int, assetID: String, asset: PHAsset, filename: String?, mediaType: String?) {
        let displayedFilename = filename ?? asset.localIdentifier
        setCurrent(asset, filename: filename)
        diagnosticJobAssets[job] = assetID
        transferProgress.register(job: job, filename: displayedFilename, mediaType: mediaType)
        let slot = transferProgress.slot(for: job).map { $0 + 1 } ?? 0
        IOSImportDiagnostics.log("upload.slot.assigned asset=\(assetID.prefix(8)) job=\(job + 1) slot=\(slot) filename=\(displayedFilename) phase=photokit-resource status=active")
        logTransferSlots(event: "assigned")
    }
    private func logTransferSlots(event: String) {
        let states = transferSlots.map { slot in
            let asset = slot.assetPrefix ?? "-"
            let phase = slot.phase?.rawValue ?? "free"
            let status = slot.isOccupied ? "active" : "free"
            return "slot=\(slot.slot + 1) lane=\(slot.lane) status=\(status) asset=\(asset) phase=\(phase) sentBytes=\(slot.sent) expectedBytes=\(slot.total)"
        }.joined(separator: " | ")
        IOSImportDiagnostics.log("upload.slots event=\(event) \(states)")
    }
    func logRenderedTransferSlotsIfChanged() {
        let slots = transferSlots
        let signature = slots.map { slot in
            "\(slot.slot):\(slot.lane):\(slot.assetPrefix ?? "-"):\(slot.phase?.rawValue ?? "free"): \(slot.sent):\(slot.total)"
        }.joined(separator: "|")
        guard signature != lastRenderedTransferSlotsSignature else { return }
        lastRenderedTransferSlotsSignature = signature
        let states = slots.map { slot in
            "slot=\(slot.slot + 1) lane=\(slot.lane) status=\(slot.isOccupied ? "active" : "free") asset=\(slot.assetPrefix ?? "-") phase=\(slot.phase?.rawValue ?? "free") sentBytes=\(slot.sent) expectedBytes=\(slot.total)"
        }.joined(separator: " | ")
        IOSImportDiagnostics.log("upload.ui.slots \(states)")
    }
    private func setProgress(_ _: Double) {}
    private func setPhase(_ value: Phase) { phase = value }
    private func markServerReachable() {
        guard IOSImportServerStatusPolicy.shouldClearUnreachableStatus(
            activeUploadProgress: !transferProgress.activeEntries.isEmpty,
            successfulResponse: true) else { return }
        if isServerUnreachableFailure {
            failure = nil
            isServerUnreachableFailure = false
        }
    }
    private func markAlready(count: Int, source: String) {
        guard count > 0 else { return }
        progressCounts.markInventoryKnown(count)
        IOSImportDiagnostics.log("progress.already-present source=\(source) increment=\(count) alreadyPresent=\(alreadyPresent) completed=\(completed) progressPublishCount=1")
    }
    private func markUploaded() { progressCounts.markUploaded() }
    private func markReconciled(count: Int) {
        guard count > 0 else { return }
        progressCounts.markReconciled(count)
        IOSImportDiagnostics.log("progress.reconciled-bulk increment=\(count) reconciled=\(reconciled) completed=\(completed) progressPublishCount=1")
    }
    private func finish() { phase = .finished }
    private func cancelled() { phase = .cancelled }
    private func failed(_ message: String, serverUnreachable: Bool = false) {
        failure = message
        isServerUnreachableFailure = serverUnreachable
        phase = .failed
    }
}

private struct IOSUploadTargets: UploadTargetProvider {
    let connection: ConnectorConnection; let transport: any DAVTransport
    let source: String; let runId: String; let uploadId: String; let folder: String
    let onPrepare: @Sendable () async -> Void
    func prepare(identity: ContentIdentity) async throws -> UploadTarget {
        await onPrepare()
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
        catch {
            IOSImportDiagnostics.failure(endpoint, started: phase, error: error)
            throw IOSUploadFailure.preserving(step: .prepare, from: error)
        }
        guard (200..<300).contains(response.status) else { throw IOSUploadFailure(step: .prepare, status: response.status) }
        return try JSONDecoder().decode(UploadTarget.self, from: response.data)
    }
    static func complete(connection: ConnectorConnection, transport: any DAVTransport, source: String, runId: String, uploadId: String, path: String, queueAssetID: UUID? = nil, uploadAttemptID: UUID? = nil) async throws {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "uploads", "complete"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sourceId": source, "runId": runId, "uploadId": uploadId, "status": "uploaded", "path": path])
        let correlation = [queueAssetID.map { "queueAssetID=\($0.uuidString.prefix(8))" }, uploadAttemptID.map { "uploadAttemptID=\($0.uuidString)" }].compactMap { $0 }.joined(separator: " ")
        let phase = IOSImportDiagnostics.start("uploads/complete \(correlation)")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil, kind: .longRunningVerification, progress: nil); IOSImportDiagnostics.finish("uploads/complete", started: phase, detail: "status=\(response.status)") }
        catch {
            IOSImportDiagnostics.failure("uploads/complete", started: phase, error: error)
            throw IOSUploadFailure.preserving(step: .complete, from: error)
        }
        guard (200..<300).contains(response.status) else { throw IOSUploadFailure(step: .complete, status: response.status) }
    }
}
