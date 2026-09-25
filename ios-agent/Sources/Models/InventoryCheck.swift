import Foundation
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
    static let defaultsKey = "apc.debug.importDiagnostics"
    static let diagnosticBuildID = "HEAD=f7411d3bda09c8eacab459e34af34b9799887f13 InventoryCheckSHA256=6a1935074571962e623243b7fb2545d5dd5df749618257533adf5e65d39d7433-preinstrumentation"
#if DEBUG
    nonisolated(unsafe) static var testLogHandler: ((String) -> Void)?
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
    static func state(_ event: String, values: String) { log("APC WAITSTATE \(event) \(values)") }
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

    static func response(step: String, response: DAVResponse, expected: String? = nil, decodeError: Error? = nil) {
        let method = response.requestMethod ?? "?"
        let path = response.requestPath ?? step
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "<missing>"
        var line = "HTTP step=\(step) endpoint=\(path) method=\(method) status=\(response.status) contentType=\(contentType) bytes=\(response.data.count)"
        if let expected { line += " expected=\(expected)" }
        if let decodeError { line += " decodeError=\(String(describing: type(of: decodeError)))" }
        log(line)
        guard !(200..<300).contains(response.status) || decodeError != nil else { return }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            log("HTTP body summary=unavailable")
            return
        }
        let safeKeys = ["error", "message", "code"]
        let summary = safeKeys.compactMap { key -> String? in
            guard let value = object[key] as? String else { return nil }
            let bounded = String(value.prefix(256)).replacingOccurrences(of: "\\n", with: " ")
            return "\(key)=\(bounded)"
        }.joined(separator: " ")
        log(summary.isEmpty ? "HTTP body summary=JSON-without-safe-fields" : "HTTP body summary=\(summary)")
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
enum BackgroundTaskReconciliation: Equatable, Sendable { case attached, missingTask, orphanTask, conflictingBinding, networkPolicyChanged }

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

    static func shouldMigrateBackgroundTask(sessionIdentifier: String, wifiSessionIdentifier: String, allowsCellular: Bool) -> Bool {
        !allowsCellular && sessionIdentifier != wifiSessionIdentifier
    }

    static func shouldShowWiFiWait(allowsCellular: Bool, wifiAvailable: Bool?, gateWaiting: Bool, cancelling: Bool) -> Bool {
        !cancelling && !allowsCellular && (wifiAvailable != true || gateWaiting)
    }

    static func acceptsCallback(callbackGeneration: Int, currentGeneration: Int, cancelling: Bool) -> Bool {
        !cancelling && callbackGeneration == currentGeneration
    }
}

/// Gates the import workflow before each control request. URLSession also
/// waits for connectivity, but this gate prevents a Wi-Fi-only import from
/// turning an unavailable path into a misleading server error.
final class ImportConnectivityGate: @unchecked Sendable {
    private let instanceID = String(UUID().uuidString.prefix(8))
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "de.applephotosconnector.import-connectivity")
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waitingHandler: (@Sendable (Bool) -> Void)?
    private var preferenceObserver: NSObjectProtocol?

    init(waitingHandler: (@Sendable (Bool) -> Void)? = nil) {
        self.waitingHandler = waitingHandler
        IOSImportDiagnostics.state("GATE_INIT", values: "gate=\(instanceID)")
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            let path = self.monitor.currentPath
            IOSImportDiagnostics.state("PATH_CALLBACK", values: "gate=\(self.instanceID) useCellular=\(IOSTransferNetworkPreferences.useCellularAccess()) path=\(path.status) wifiAvailable=\(path.usesInterfaceType(.wifi)) waiting=\(!self.isUsable())")
            self.waitingHandler?(!self.isUsable())
            self.resumeIfUsable()
        }
        monitor.start(queue: queue)
        preferenceObserver = NotificationCenter.default.addObserver(forName: IOSTransferNetworkPreferences.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            let path = self.monitor.currentPath
            IOSImportDiagnostics.state("POLICY_NOTIFICATION", values: "gate=\(self.instanceID) useCellular=\(IOSTransferNetworkPreferences.useCellularAccess()) path=\(path.status) wifiAvailable=\(path.usesInterfaceType(.wifi))")
            self.waitingHandler?(!self.isUsable())
            self.resumeIfUsable()
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
        return try await ImportTransientRequestRetry.run(
            maxRetries: ImportTransientRequestRetry.maxRetries(for: request),
            waitUntilUsable: { await gate.waitUntilUsable() },
            isCurrentlyUsable: { gate.isCurrentlyUsable }
        ) {
            try await base.send(request, file: file, kind: kind, progress: progress)
        }
    }

    static func isTransientConnectivityError(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
}

enum ImportTransientRequestRetry {
    static func maxRetries(for request: URLRequest) -> Int {
        let method = request.httpMethod?.uppercased()
        let path = request.url?.path ?? ""
        if method == "MKCOL" { return 2 }
        if method == "POST" && (path.hasSuffix("/uploads/prepare") || path.hasSuffix("/uploads/complete")) { return 2 }
        return 0
    }

    static func run<Value>(
        maxRetries: Int,
        waitUntilUsable: @Sendable () async -> Bool,
        isCurrentlyUsable: @Sendable () -> Bool,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var retries = 0
        while true {
            guard await waitUntilUsable() else { throw CancellationError() }
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as URLError where ImportNetworkTransport.isTransientConnectivityError(error) {
                guard retries < maxRetries else { throw UploadError.networkUnavailable }
                retries += 1
                IOSImportDiagnostics.log("import request transient connectivity error attempt=\(retries) code=\(error.code.rawValue)")
                if isCurrentlyUsable() {
                    try await Task.sleep(for: .milliseconds(250 * retries))
                }
            }
        }
    }
}

enum IOSImportTransportFactory {
    static func make(base: (any DAVTransport)? = nil, waitingHandler: (@Sendable (Bool) -> Void)? = nil) -> ImportNetworkTransport {
        let baseTransport = base ?? NetworkTransport(allowsCellularAccess: true, waitsForConnectivity: true, responseDiagnostics: { response in
            IOSImportDiagnostics.response(step: response.requestPath ?? "network", response: response)
        })
        return ImportNetworkTransport(base: baseTransport, waitingHandler: waitingHandler)
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

/// Background URLSession adapter for the existing WebDAV PUT contract.
/// Prepare and Complete remain on the existing DAVTransport path.
final class BackgroundTransferCoordinator: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private struct TaskKey: Hashable {
        let sessionIdentifier: String
        let taskIdentifier: Int
    }
    private struct PolicyMigration {
        let binding: BackgroundTaskBinding
        let request: URLRequest?
    }
    static let sessionIdentifier = "com.applephotosconnector.background-webdav-put.v1"
    static let wifiSessionIdentifier = "com.applephotosconnector.background-webdav-put.wifi.v1"
    static let cellularSessionIdentifier = "com.applephotosconnector.background-webdav-put.cellular.v1"
    static let shared = BackgroundTransferCoordinator()
    private let bindingStore: BackgroundTaskBindingStore
    private let fileStore: BackgroundTransferFileStore
    private let queueStore: ImportQueueStore?
    private let lock = NSLock()
    private var continuations: [TaskKey: CheckedContinuation<DAVResponse, Error>] = [:]
    private var responses: [TaskKey: (Data, HTTPURLResponse)] = [:]
    private var progressHandlers: [TaskKey: @Sendable (Int64, Int64) -> Void] = [:]
    private var policyMigrations: [TaskKey: PolicyMigration] = [:]
    private var cancelledRuns = Set<UUID>()
    private var policyObserver: NSObjectProtocol?
    private var completionInFlight = Set<UUID>()
    private var connectivityWaitingHandler: (@Sendable (Bool) -> Void)?
    private var putTaskStates = BackgroundPUTTaskStateAggregation()
    private let lifecycleLock = NSLock()
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var sessions: [String: URLSession] = [:]
    static func makeBackgroundConfiguration(identifier: String, allowsCellularAccess: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        let policy = BackgroundTransferNetworkPolicy(allowsCellularAccess: allowsCellularAccess)
        configuration.allowsCellularAccess = policy.allowsCellularAccess
        configuration.waitsForConnectivity = policy.waitsForConnectivity
        return configuration
    }
    private func sessionIdentifier(allowsCellular: Bool) -> String {
        allowsCellular ? Self.cellularSessionIdentifier : Self.wifiSessionIdentifier
    }
    private func session(allowsCellular: Bool) -> URLSession {
        let identifier = sessionIdentifier(allowsCellular: allowsCellular)
        if let existing = sessions[identifier] { return existing }
        IOSImportDiagnostics.log("background session create identifier=\(identifier)")
        let configuration = Self.makeBackgroundConfiguration(identifier: identifier, allowsCellularAccess: allowsCellular)
        let policy = BackgroundTransferNetworkPolicy(allowsCellularAccess: allowsCellular)
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
        let configuration = Self.makeBackgroundConfiguration(
            identifier: Self.sessionIdentifier,
            allowsCellularAccess: IOSTransferNetworkPreferences.useCellularAccess()
        )
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessions[Self.sessionIdentifier] = created
        return created
    }
    private func taskKey(sessionIdentifier: String, taskIdentifier: Int) -> String {
        "(sessionIdentifier):(taskIdentifier)"
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
    private func isRunCancelled(_ runID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledRuns.contains(runID)
    }
    private func markRunCancelled(_ runID: UUID) {
        lock.lock(); cancelledRuns.insert(runID); lock.unlock()
    }
    private func registerPolicyMigration(key: TaskKey, binding: BackgroundTaskBinding, request: URLRequest?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard policyMigrations[key] == nil else { return false }
        policyMigrations[key] = PolicyMigration(binding: binding, request: request)
        return true
    }
    private func installContinuation(_ continuation: CheckedContinuation<DAVResponse, Error>?, progress: (@Sendable (Int64, Int64) -> Void)?, for key: TaskKey) {
        lock.lock(); defer { lock.unlock() }
        if let continuation { continuations[key] = continuation }
        if let progress { progressHandlers[key] = progress }
    }
    init(bindingStore: BackgroundTaskBindingStore = BackgroundTaskBindingStore(), fileStore: BackgroundTransferFileStore = BackgroundTransferFileStore(), queueStore: ImportQueueStore? = nil) {
        self.bindingStore = bindingStore; self.fileStore = fileStore; self.queueStore = queueStore
        super.init()
        IOSImportDiagnostics.log("background session coordinator initialized/reconstructed identifier=\(Self.sessionIdentifier)")
        policyObserver = NotificationCenter.default.addObserver(forName: IOSTransferNetworkPreferences.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, !IOSTransferNetworkPreferences.useCellularAccess() else { return }
            Task { await self.enforceWiFiOnlyPolicy() }
        }
    }
    deinit { if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) } }
    func send(_ request: URLRequest, file: URL, queueAssetID: UUID, localRunID: UUID, uploadAttemptID: UUID, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard !isRunCancelled(localRunID) else { throw CancellationError() }
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw UploadError.invalidConfiguration }
        IOSImportDiagnostics.memory(phase: "transfer-file-prepare-start", asset: queueAssetID.uuidString)
        let prepared = try await fileStore.prepare(source: file, uploadAttemptID: uploadAttemptID)
        let allowsCellular = IOSTransferNetworkPreferences.useCellularAccess()
        let activeSession = session(allowsCellular: allowsCellular)
        IOSImportDiagnostics.log("transfer file prepared queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) bytes=\(try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber ?? 0)")
        IOSImportDiagnostics.memory(phase: "transfer-file-prepare-end", asset: queueAssetID.uuidString, job: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                IOSImportDiagnostics.memory(phase: "background-upload-task-create-start", asset: queueAssetID.uuidString)
                let task = activeSession.uploadTask(with: request, fromFile: prepared.url)
                IOSImportDiagnostics.memory(phase: "background-upload-task-create-end", asset: queueAssetID.uuidString)
                let sessionIdentifier = activeSession.configuration.identifier ?? Self.sessionIdentifier
                let callbackKey = TaskKey(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)
                installContinuation(continuation, progress: progress, for: callbackKey)
                task.taskDescription = uploadAttemptID.uuidString
                IOSImportDiagnostics.log("[BackgroundPUT] task=\(task.taskIdentifier) asset=\(queueAssetID.uuidString.prefix(8)) bytes=\(try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber ?? 0) policyCellular=\(IOSTransferNetworkPreferences.useCellularAccess())")
                let aggregateKey = taskKey(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)
                updatePUTTaskState { $0.started(aggregateKey) }
                IOSImportDiagnostics.log("background task start taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) session=\(sessionIdentifier)")
                let binding = BackgroundTaskBinding(queueAssetID: queueAssetID, localRunID: localRunID, uploadAttemptID: uploadAttemptID, sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier, relativeTransferPath: prepared.relativePath, expectedHost: host, targetPath: request.url?.path ?? "", createdAt: Date())
                Task {
                    try? await bindingStore.upsert(binding)
                    IOSImportDiagnostics.log("binding created taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString)")
                    if !IOSTransferNetworkPreferences.useCellularAccess(), sessionIdentifier != Self.wifiSessionIdentifier {
                        await self.migrateTaskToWiFi(task, binding: binding)
                    } else {
                        task.resume()
                    }
                }
                IOSImportDiagnostics.memory(phase: "background-upload-started", asset: queueAssetID.uuidString)
            }
        } onCancel: {
            IOSImportDiagnostics.log("asset-job swift-task cancellation handler queueAssetID=\(queueAssetID.uuidString.prefix(8)) runID=\(localRunID.uuidString.prefix(8)) phase=put")
            self.cancelAll(for: uploadAttemptID)
        }
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
            updatePUTTaskState { $0.started(taskKey(sessionIdentifier: binding.sessionIdentifier, taskIdentifier: binding.taskIdentifier)) }
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
            let allowsCellular = IOSTransferNetworkPreferences.useCellularAccess()
            if ImportConnectivityPolicy.shouldMigrateBackgroundTask(sessionIdentifier: binding.sessionIdentifier, wifiSessionIdentifier: Self.wifiSessionIdentifier, allowsCellular: allowsCellular) {
                await migrateTaskToWiFi(task, binding: binding)
                result.append(.networkPolicyChanged); continue
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
    private func enforceWiFiOnlyPolicy() async {
        guard !IOSTransferNetworkPreferences.useCellularAccess() else { return }
        let bindings = await bindingStore.all().filter {
            ImportConnectivityPolicy.shouldMigrateBackgroundTask(sessionIdentifier: $0.sessionIdentifier, wifiSessionIdentifier: Self.wifiSessionIdentifier, allowsCellular: false)
        }
        for binding in bindings {
            let sourceSession = binding.sessionIdentifier == Self.cellularSessionIdentifier ? session(allowsCellular: true) : legacySession()
            let tasks = await withCheckedContinuation { continuation in
                sourceSession.getAllTasks { continuation.resume(returning: $0) }
            }
            guard let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) else { continue }
            await migrateTaskToWiFi(task, binding: binding)
        }
    }

    private func migrateTaskToWiFi(_ task: URLSessionTask, binding: BackgroundTaskBinding) async {
        guard !IOSTransferNetworkPreferences.useCellularAccess() else { return }
        // Stop the less-restricted task even if URLSession cannot provide its
        // original request. In that exceptional case recovery will reconcile
        // the persisted asset instead of allowing a cellular PUT to continue.
        let request = task.originalRequest
        let oldKey = TaskKey(sessionIdentifier: binding.sessionIdentifier, taskIdentifier: binding.taskIdentifier)
        let firstRequest = registerPolicyMigration(key: oldKey, binding: binding, request: request)
        guard firstRequest else { return }
        try? await queueStore?.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "cellular-policy-revoked", targetPath: binding.targetPath)
        IOSImportDiagnostics.log("background-task policy migration requested queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))")
        task.suspend()
        task.cancel()
    }

    private func resumePolicyMigration(binding: BackgroundTaskBinding, request: URLRequest, oldKey: TaskKey, continuation: CheckedContinuation<DAVResponse, Error>?, progress: (@Sendable (Int64, Int64) -> Void)?) async {
        guard let url = request.url, url.scheme == "https", url.host != nil else {
            continuation?.resume(throwing: UploadError.networkUnavailable)
            return
        }
        let file = await fileStore.url(relativePath: binding.relativeTransferPath)
        let destination = session(allowsCellular: false)
        let replacement = destination.uploadTask(with: request, fromFile: file)
        replacement.taskDescription = binding.uploadAttemptID.uuidString
        let identifier = destination.configuration.identifier ?? Self.wifiSessionIdentifier
        let replacementKey = TaskKey(sessionIdentifier: identifier, taskIdentifier: replacement.taskIdentifier)
        let replacementBinding = BackgroundTaskBinding(queueAssetID: binding.queueAssetID, localRunID: binding.localRunID, uploadAttemptID: binding.uploadAttemptID, sessionIdentifier: identifier, taskIdentifier: replacement.taskIdentifier, relativeTransferPath: binding.relativeTransferPath, expectedHost: binding.expectedHost, targetPath: binding.targetPath, createdAt: binding.createdAt)
        installContinuation(continuation, progress: progress, for: replacementKey)
        try? await bindingStore.upsert(replacementBinding)
        guard !IOSTransferNetworkPreferences.useCellularAccess() else {
            // A preference change while replacing does not make this Wi-Fi
            // task unsafe; it remains on the restrictive session.
            IOSImportDiagnostics.log("background-task policy replacement remains wifi-only")
            let key = taskKey(sessionIdentifier: identifier, taskIdentifier: replacement.taskIdentifier)
            updatePUTTaskState { $0.started(key) }
            replacement.resume()
            return
        }
        let key = taskKey(sessionIdentifier: identifier, taskIdentifier: replacement.taskIdentifier)
        updatePUTTaskState { $0.started(key) }
        replacement.resume()
        _ = oldKey
        IOSImportDiagnostics.log("background-task migrated to wifi-only session queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))")
    }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        _ = allSessions()
        lifecycleLock.lock(); backgroundEventsCompletionHandler = handler; lifecycleLock.unlock()
        IOSImportDiagnostics.log("background events completion handler received")
    }
    func setConnectivityWaitingHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.lock(); connectivityWaitingHandler = handler; lock.unlock()
    }
    func activeBindings(queueStore: ImportQueueStore? = nil) async -> [BackgroundTaskBinding] {
        var activeTaskKeys = Set<String>()
        for (identifier, session) in allSessions() {
            let tasks = await withCheckedContinuation { continuation in session.getAllTasks { continuation.resume(returning: $0) } }
            for task in tasks { activeTaskKeys.insert("\(identifier):\(task.taskIdentifier)") }
        }
        let bindings = await bindingStore.all()
        let completing = completionInFlightSnapshot()
        var active: [BackgroundTaskBinding] = []
        for binding in bindings {
            let run = await (queueStore ?? self.queueStore)?.run(localRunID: binding.localRunID)
            let runIsOpen = run?.state.hasOpenImport == true
            let hasTechnicalActivity = activeTaskKeys.contains("\(binding.sessionIdentifier):\(binding.taskIdentifier)") || completing.contains(binding.uploadAttemptID)
            if runIsOpen && hasTechnicalActivity { active.append(binding) }
        }
        for binding in active { IOSImportDiagnostics.log("task reattached taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)") }
        return active
    }
    func cancelAll(for uploadAttemptID: UUID) { Task { for binding in await bindingStore.all() where binding.uploadAttemptID == uploadAttemptID { let session = binding.sessionIdentifier == Self.cellularSessionIdentifier ? self.session(allowsCellular: true) : binding.sessionIdentifier == Self.wifiSessionIdentifier ? self.session(allowsCellular: false) : self.legacySession(); session.getAllTasks { tasks in if let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) { IOSImportDiagnostics.log("background-task cancel requested reason=swift-task-cancellation session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))"); task.cancel() } } } } }
    func cancelAllForRun(_ localRunID: UUID) { Task { for binding in await bindingStore.all() where binding.localRunID == localRunID { let session = binding.sessionIdentifier == Self.cellularSessionIdentifier ? self.session(allowsCellular: true) : binding.sessionIdentifier == Self.wifiSessionIdentifier ? self.session(allowsCellular: false) : self.legacySession(); session.getAllTasks { tasks in if let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) { IOSImportDiagnostics.log("background-task cancel requested reason=user-cancel session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))"); task.cancel() } } } } }
    func cancelAllForRunAndRemoveBindings(_ localRunID: UUID) async {
        markRunCancelled(localRunID)
        let bindings = await bindingStore.all().filter { $0.localRunID == localRunID }
        for binding in bindings {
            let session = binding.sessionIdentifier == Self.cellularSessionIdentifier ? self.session(allowsCellular: true) : binding.sessionIdentifier == Self.wifiSessionIdentifier ? self.session(allowsCellular: false) : self.legacySession()
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            if let task = tasks.first(where: { $0.taskIdentifier == binding.taskIdentifier }) {
                IOSImportDiagnostics.log("background-task cancel requested reason=user-cancel session=\(binding.sessionIdentifier) taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) runID=\(binding.localRunID.uuidString.prefix(8))")
                task.cancel()
            }
            try? await bindingStore.remove(uploadAttemptID: binding.uploadAttemptID)
        }
    }
    func cancelAll() { for (identifier, session) in allSessions() { session.getAllTasks { tasks in tasks.forEach { task in IOSImportDiagnostics.log("background-task cancel requested reason=other session=\(identifier) taskIdentifier=\(task.taskIdentifier)"); task.cancel() } } } }
    func beginComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.insert(uploadAttemptID); lock.unlock() }
    func endComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.remove(uploadAttemptID); lock.unlock() }
    private func isCompleteInFlight(_ uploadAttemptID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return completionInFlight.contains(uploadAttemptID) }
    private func completionInFlightSnapshot() -> Set<UUID> { lock.lock(); defer { lock.unlock() }; return completionInFlight }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { let identifier = session.configuration.identifier ?? "unknown"; let key = TaskKey(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier); lock.lock(); let handler = progressHandlers[key]; let migrating = policyMigrations[key] != nil; lock.unlock(); guard !migrating else { return }; updatePUTTaskState { $0.sending(taskKey(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier)) }; IOSImportDiagnostics.log("[BackgroundPUT] task=\(task.taskIdentifier) didSendBodyData=\(bytesSent) totalBytesSent=\(totalBytesSent) expected=\(totalBytesExpectedToSend) state=sending"); handler?(totalBytesSent, totalBytesExpectedToSend) }
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
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { let identifier = session.configuration.identifier ?? "unknown"; updatePUTTaskState { $0.waiting(taskKey(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier)) }; IOSImportDiagnostics.log("background-task waitingForConnectivity session=\(identifier) taskIdentifier=\(task.taskIdentifier) state=waiting") }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { let key = TaskKey(sessionIdentifier: session.configuration.identifier ?? "unknown", taskIdentifier: dataTask.taskIdentifier); lock.lock(); if let current = responses[key] { responses[key] = (current.0 + data, current.1) }; lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sessionIdentifier = session.configuration.identifier ?? "unknown"
        updatePUTTaskState { $0.completed(taskKey(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)) }
        let taskKey = TaskKey(sessionIdentifier: sessionIdentifier, taskIdentifier: task.taskIdentifier)
        lock.lock(); let continuation = continuations.removeValue(forKey: taskKey); let response = responses.removeValue(forKey: taskKey); let progress = progressHandlers.removeValue(forKey: taskKey); let migration = policyMigrations.removeValue(forKey: taskKey); lock.unlock()
        if let error {
            let nsError = error as NSError
            IOSImportDiagnostics.log("background-task completed session=\(sessionIdentifier) taskIdentifier=\(task.taskIdentifier) errorDomain=\(nsError.domain) errorCode=\(nsError.code)")
            Task { if let binding = await bindingStore.all().first(where: { $0.taskIdentifier == task.taskIdentifier }) { IOSImportDiagnostics.log("background-task completed correlation session=\(binding.sessionIdentifier) taskIdentifier=\(task.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)") } }
            if migration != nil {
                let shouldDrop: Bool
                lock.lock(); shouldDrop = cancelledRuns.contains(migration!.binding.localRunID); lock.unlock()
                if shouldDrop {
                    continuation?.resume(throwing: CancellationError())
                } else if let request = migration?.request {
                    Task { await self.resumePolicyMigration(binding: migration!.binding, request: request, oldKey: taskKey, continuation: continuation, progress: progress) }
                } else {
                    Task {
                        try? await self.bindingStore.remove(uploadAttemptID: migration!.binding.uploadAttemptID)
                        continuation?.resume(throwing: UploadError.networkUnavailable)
                    }
                }
            } else if let urlError = error as? URLError,
               [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
                continuation?.resume(throwing: UploadError.networkUnavailable)
            } else {
                continuation?.resume(throwing: error)
            }
            return
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
            if http.statusCode == 201 || http.statusCode == 204, let binding = await bindingStore.all().first(where: { $0.taskIdentifier == task.taskIdentifier }) {
                try? await queueStore?.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "put-succeeded-needs-complete", targetPath: binding.targetPath)
                IOSImportDiagnostics.log("completed PUT recovered queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString) state=needsReconcile")
            }
            IOSImportDiagnostics.log("delegate completion taskIdentifier=\(task.taskIdentifier) status=\(http.statusCode)")
            continuation?.resume(returning: davResponse)
        }
    }
    private static func diagnosticHeaders(_ fields: [AnyHashable: Any]) -> String {
        let allowed = ["content-type", "content-length", "dav", "server", "retry-after", "x-request-id", "request-id"]
        return fields.compactMap { key, value in
            let name = String(describing: key)
            guard allowed.contains(name.lowercased()) else { return nil }
            return "\(name)=\(value)"
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

final class IOSBackgroundDAVTransport: DAVTransport, @unchecked Sendable {
    private let base: any DAVTransport
    private let background: BackgroundTransferCoordinator
    private let queueAssetID: UUID
    private let localRunID: UUID
    let uploadAttemptID = UUID()
    init(base: any DAVTransport, background: BackgroundTransferCoordinator, queueAssetID: UUID, localRunID: UUID) { self.base = base; self.background = background; self.queueAssetID = queueAssetID; self.localRunID = localRunID }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: nil) }
    func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse { try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: progress) }
    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard kind == .fileTransfer, let file else { return try await base.send(request, file: file, kind: kind, progress: progress) }
        return try await background.send(request, file: file, queueAssetID: queueAssetID, localRunID: localRunID, uploadAttemptID: uploadAttemptID, progress: progress)
    }
    func cleanup(deleteFile: Bool) async { await background.cleanup(uploadAttemptID: uploadAttemptID, deleteFile: deleteFile) }
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
    static func check(connection: ConnectorConnection, source: PhotoSource, assets: [AssetInventory], transport: (any DAVTransport)? = nil) async throws -> InventoryReply {
        guard !assets.isEmpty else { throw InventoryCheckError.invalidResponse }
        let json = try InventoryJSON.encode(assets, source: source)
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let phase = IOSImportDiagnostics.start("asset-inventory")
        let requestTransport = transport ?? IOSImportTransportFactory.make()
        let response: DAVResponse
        do { response = try await requestTransport.send(request, file: nil); IOSImportDiagnostics.response(step: "inventory", response: response, expected: "InventoryReply"); IOSImportDiagnostics.finish("asset-inventory", started: phase, detail: "status=\(response.status)") }
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
        Self.logInventoryResponse(response)
        guard (200..<300).contains(response.status) else { throw InventoryCheckError.invalidResponse }
        let decoded: InventoryReply
        do {
            decoded = try JSONDecoder().decode(InventoryReply.self, from: response.data)
        } catch let error as DecodingError {
            IOSImportDiagnostics.response(step: "inventory", response: response, expected: "InventoryReply", decodeError: error)
            IOSImportDiagnostics.log(Self.decodingDiagnostic(error))
            throw InventoryCheckError.invalidResponse
        } catch {
            IOSImportDiagnostics.response(step: "inventory", response: response, expected: "InventoryReply", decodeError: error)
            IOSImportDiagnostics.log("Inventory decoding failed error=\(String(describing: type(of: error)))")
            throw InventoryCheckError.invalidResponse
        }
        let responseNew = decoded.assets.filter { $0.state == .new }.count
        let responseKnown = decoded.assets.filter { $0.state == .known }.count
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
        IOSImportDiagnostics.log("Inventory HTTP \(response.status) Content-Type: \(contentType) Response bytes: \(response.data.count)")
        if !(200..<300).contains(response.status) { logServerError(response.data, contentType: contentType) }
    }

    private static func logServerError(_ data: Data, contentType: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            IOSImportDiagnostics.log("error body decoding failed Content-Type: \(contentType) Response bytes: \(data.count)")
            return
        }
        if let error = object["error"] as? String { IOSImportDiagnostics.log("Server error: \(error)") }
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
    static func inventoryAndSync(connection: ConnectorConnection, source: PhotoSource, albums: [AlbumInventory], selectedAssets: [AssetInventory], transport: any DAVTransport = IOSImportTransportFactory.make()) async throws {
        let document = AlbumInventoryDocument(source: source, albums: albums)
        IOSImportDiagnostics.log("album-inventory-build OK albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })")
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "albums", "inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(document)
        let inventoryPhase = IOSImportDiagnostics.start("albums/inventory")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.response(step: "albums/inventory", response: response); IOSImportDiagnostics.finish("albums/inventory", started: inventoryPhase, detail: "status=\(response.status)") }
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
        do { syncResponse = try await transport.send(sync, file: nil); IOSImportDiagnostics.response(step: "albums/sync", response: syncResponse); IOSImportDiagnostics.finish("albums/sync", started: syncPhase, detail: "status=\(syncResponse.status)") }
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
        let isTransientConnectivity: Bool
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
                        return CollectedResult(index: index, result: try await operation(index), errorDescription: nil, isTransientConnectivity: false)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let isTransient: Bool
                        if let uploadError = error as? UploadError, case .networkUnavailable = uploadError { isTransient = true }
                        else { isTransient = false }
                        return CollectedResult(index: index, result: nil, errorDescription: String(describing: error), isTransientConnectivity: isTransient)
                    }
                }
                running += 1
            }
            while next < count && running < maxConcurrent { launch(next); next += 1 }
            while running > 0 {
                try Task.checkCancellation()
                guard let result = try await group.next() else { break }
                results.append(result)
                running -= 1
                if next < count { launch(next); next += 1 }
            }
            return results.sorted { $0.index < $1.index }
        }
    }
}

/// Foreground-only iOS import.  It deliberately keeps orchestration in the
/// iOS target while reusing the shared WebDAV uploader and content identity.
@MainActor
final class IOSForegroundImportCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, inventory, exporting, hashing, preparing, uploading, completing, interrupted, cancelling, finished, failed, cancelled }
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
    @Published private(set) var hasActiveBackgroundTransfer = false
    @Published private(set) var isWaitingForWiFi = false
    private var task: Task<Void, Never>?
    private let queueStore: ImportQueueStore
    private let backgroundTransfer: BackgroundTransferCoordinator
    private var activeRunID: UUID?
    private var gateWaitingForWiFi = false
    private var backgroundWaitingForConnectivity = false
    private var stateGeneration = 0
    private let instanceID = String(UUID().uuidString.prefix(8))
    private let policyPathMonitor = NWPathMonitor()
    private let policyPathQueue = DispatchQueue(label: "de.applephotosconnector.import-policy-path")
    nonisolated(unsafe) private var policyPathObserver: NSObjectProtocol?
    private var currentWiFiAvailable: Bool?
    private var transferProgress = IOSImportProgressAggregation()
    private var pendingCompletion = Set<Int>()
    init(queueStore: ImportQueueStore? = nil) {
        let store = queueStore ?? ImportQueueStore()
        self.queueStore = store
        self.backgroundTransfer = queueStore == nil ? BackgroundTransferCoordinator.shared : BackgroundTransferCoordinator(queueStore: store)
        isWaitingForWiFi = !IOSTransferNetworkPreferences.useCellularAccess()
        policyPathMonitor.pathUpdateHandler = { [weak self] path in
            let wifiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.updatePolicyPath(wifiAvailable: wifiAvailable) }
        }
        policyPathMonitor.start(queue: policyPathQueue)
        policyPathObserver = NotificationCenter.default.addObserver(forName: IOSTransferNetworkPreferences.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeWaitingState()
            }
        }
        self.backgroundTransfer.setConnectivityWaitingHandler { [weak self] waiting in
            Task { @MainActor in
                guard let self else { return }
                IOSImportDiagnostics.state("BACKGROUND_CALLBACK", values: self.diagnosticValues(extra: "waiting=\(waiting)"))
                self.updateBackgroundWaiting(waiting)
            }
        }
        IOSImportDiagnostics.log("APC DIAGNOSTIC BUILD \(IOSImportDiagnostics.diagnosticBuildID)")
        IOSImportDiagnostics.state("COORDINATOR_INIT", values: diagnosticValues())
    }
    deinit {
        policyPathMonitor.cancel()
        if let policyPathObserver { NotificationCenter.default.removeObserver(policyPathObserver) }
    }
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
    var isCancelling: Bool { phase == .cancelling }
    var isRunning: Bool { hasActiveBackgroundTransfer || ![.idle, .interrupted, .finished, .failed, .cancelled].contains(phase) }
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
        guard !isCancelling else { return }
        IOSImportDiagnostics.memory(phase: "import-cancel-requested")
        IOSImportDiagnostics.log("cancel requested")
        phase = .cancelling
        stateGeneration &+= 1
        gateWaitingForWiFi = false
        backgroundWaitingForConnectivity = false
        let runID = activeRunID
        task?.cancel()
        task = nil
        guard let runID else {
            hasActiveBackgroundTransfer = false
            isWaitingForWiFi = false
            phase = .cancelled
            IOSImportDiagnostics.log("cancel completed without active run")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.backgroundTransfer.cancelAllForRunAndRemoveBindings(runID)
            try? await self.queueStore.markRun(runID: runID, state: .cancelled, albumSyncPending: false)
            self.hasActiveBackgroundTransfer = false
            self.isWaitingForWiFi = false
            self.activeRunID = nil
            self.phase = .cancelled
            IOSImportDiagnostics.log("cancel completed queue-state=cancelled")
        }
        IOSImportDiagnostics.log("cancel swift-task")
    }

    func recoverableRuns() async -> [PersistedImportRun] { await queueStore.recoverableRuns() }
    func reconcileBackgroundTasks() async {
        guard !isCancelling else { return }
        IOSImportDiagnostics.state("RECONCILE", values: diagnosticValues())
        let result = await backgroundTransfer.reconcileTasks(queueStore: queueStore)
        let active = await backgroundTransfer.activeBindings(queueStore: queueStore)
        if let binding = active.first,
           let run = await queueStore.run(localRunID: binding.localRunID) {
            activeRunID = run.localRunID
            restoreMetrics(from: run)
            if phase == .idle || phase == .cancelled || phase == .failed {
                phase = run.state == .assetsComplete || run.state == .albumSyncPending ? .completing : .uploading
            }
        }
        recomputeWaitingState()
        hasActiveBackgroundTransfer = !active.isEmpty
        if !active.isEmpty { IOSImportDiagnostics.log("run exposed as active count=\(active.count)") }
        else if !result.isEmpty { IOSImportDiagnostics.log("run exposed as recoverable") }
    }

    func restoreRecoverableRun(_ run: PersistedImportRun) {
        guard !isRunning, !isCancelling else { return }
        total = run.assets.count
        restoreMetrics(from: run)
        currentFilename = nil
        transferProgress = IOSImportProgressAggregation()
        transferSentBytes = 0
        transferTotalBytes = 0
        pendingCompletion.removeAll()
        if phase == .idle || phase == .failed || phase == .cancelled {
            phase = .interrupted
        }
        IOSImportDiagnostics.state("RECOVERABLE_RUN_RESTORED", values: diagnosticValues(extra: "completed=\(completed) total=\(total)"))
    }

    func start(selection: [GalleryAsset], library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: (any DAVTransport)? = nil, resumeRun: PersistedImportRun? = nil) {
        IOSImportDiagnostics.announceIfEnabled()
        IOSImportDiagnostics.memory(phase: "import-start")
        // The gate applies the current import policy before each request. The
        // underlying session remains able to use cellular data so AUS → EIN
        // can release a waiting import without recreating its task/session.
        stateGeneration &+= 1
        let generation = stateGeneration
        IOSImportDiagnostics.state("IMPORT_START", values: diagnosticValues(extra: "generation=\(generation)"))
        let importTransport = IOSImportTransportFactory.make(base: transport) { [weak self] waiting in
            Task { @MainActor in self?.updateGateWaiting(waiting, generation: generation) }
        }
        if task != nil || activeRunID != nil || hasActiveBackgroundTransfer { cancel() }
        if isCancelling { return }
        if resumeRun != nil { IOSImportDiagnostics.memory(phase: "resume-after-old-task-cancel") }; gateWaitingForWiFi = false; backgroundWaitingForConnectivity = false; isWaitingForWiFi = false; phase = .inventory; failure = nil; completed = resumeRun.map { Self.completedAssetCount(in: $0) } ?? 0; uploaded = 0; alreadyPresent = 0; reconciled = 0; transferProgress = IOSImportProgressAggregation(); pendingCompletion = []; transferSentBytes = 0; transferTotalBytes = 0; total = selection.count
        let targetRootSnapshot = IOSTargetDirectoryPreferences.normalize(targetRoot)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let folderCoordinator = WebDAVFolderCoordinator()
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
                    try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: importTransport)
                    try await queueStore.markRun(runID: runID, state: .completed, albumSyncPending: false)
                    self.finish()
                    return
                }
                let reply = try await InventoryCheckClient.check(connection: connection, source: source, assets: assets, transport: importTransport)
                try await queueStore.markRun(runID: runID, state: .assetProcessing, serverRunID: reply.runId)
                for (index, entry) in reply.assets.enumerated() where persistedAssets.indices.contains(index) {
                    guard let state = Self.resumeInventoryState(localState: persistedAssets[index].state, serverState: entry.state) else { continue }
                    try await queueStore.markAsset(runID: runID, assetID: persistedAssets[index].queueAssetID,
                        state: state,
                        lastConfirmedStep: entry.state == .known ? "inventory-known" : "inventory-ticket",
                        serverAssetID: entry.upload?.assetId, uploadID: entry.upload?.uploadId)
                }
                self.setPhase(.uploading)
                try await self.runAssetJobs(selection: selection, assets: assets, reply: reply, library: library, connection: connection, source: source, targetRoot: targetRootSnapshot, transport: importTransport, folderCoordinator: folderCoordinator, runID: runID, persistedAssets: persistedAssets)
                try await queueStore.markRun(runID: runID, state: .assetsComplete, albumSyncPending: true)
                self.setPhase(.completing)
                let albumBuild = IOSImportDiagnostics.start("album-inventory-build")
                let albums: [AlbumInventory]
                do { albums = try library.albumInventory(); IOSImportDiagnostics.finish("album-inventory-build", started: albumBuild, detail: "albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })") }
                catch { IOSImportDiagnostics.failure("album-inventory-build", started: albumBuild, error: error); throw error }
                try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: importTransport)
                try await queueStore.markRun(runID: runID, state: .completed, albumSyncPending: false)
                self.finish()
            } catch UploadError.networkUnavailable {
                self.failure = nil
                self.gateWaitingForWiFi = !IOSTransferNetworkPreferences.useCellularAccess()
                self.recomputeWaitingState()
                if let runID = self.activeRunID {
                    let savedRun = await self.queueStore.run(localRunID: runID)
                    let allAssetsComplete = savedRun?.assets.allSatisfy { $0.state == .completed } == true
                    try? await self.queueStore.markRun(runID: runID, state: allAssetsComplete ? .assetsComplete : .assetProcessing, albumSyncPending: allAssetsComplete)
                    if let refreshedRun = await self.queueStore.run(localRunID: runID) {
                        self.total = max(self.total, refreshedRun.assets.count)
                        self.restoreMetrics(from: refreshedRun)
                    }
                }
                self.transferProgress = IOSImportProgressAggregation()
                self.transferSentBytes = 0
                self.transferTotalBytes = 0
                self.pendingCompletion.removeAll()
                self.currentFilename = nil
                await self.reconcileBackgroundTasks()
                self.phase = .interrupted
                IOSImportDiagnostics.log("import connectivity lost; queue retained for recovery")
            } catch is CancellationError { IOSImportDiagnostics.memory(phase: "import-task-cancelled"); self.cancelled() }
            catch { self.failed(error.localizedDescription) }
        }
        if resumeRun != nil { IOSImportDiagnostics.memory(phase: "resume-new-task-created") }
    }

    private func runAssetJobs(selection: [GalleryAsset], assets: [AssetInventory], reply: InventoryReply, library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: any DAVTransport, folderCoordinator: WebDAVFolderCoordinator, runID: UUID, persistedAssets: [PersistedImportAsset]) async throws {
        let outcomes = try await IOSAssetJobScheduler.runCollectingFailures(count: selection.count, maxConcurrent: 2) { [weak self] index in
            guard let self else { throw CancellationError() }
        let selected = selection[index]
            let asset = assets[index]
            let entry = reply.assets[index]
            IOSImportDiagnostics.log("asset-job[\(index + 1)] START")
        let started = ContinuousClock.now
            IOSImportDiagnostics.memory(phase: "asset-job-start", asset: persistedAssets[index].queueAssetID.uuidString, job: index + 1)
            do {
                let outcome = try await self.runAssetJob(index: index, selected: selected, asset: asset, entry: entry, reply: reply, library: library, connection: connection, source: source, targetRoot: targetRoot, transport: transport, folderCoordinator: folderCoordinator, runID: runID, queueAsset: persistedAssets[index])
                IOSImportDiagnostics.memory(phase: "asset-job-end", asset: persistedAssets[index].queueAssetID.uuidString, job: index + 1)
                IOSImportDiagnostics.log("asset-job[\(index + 1)] OK elapsed=\(started.duration(to: .now))")
                return (index, outcome)
            } catch is CancellationError {
                IOSImportDiagnostics.memory(phase: "asset-job-cancelled", asset: persistedAssets[index].queueAssetID.uuidString, job: index + 1)
                throw CancellationError()
            } catch {
                IOSImportDiagnostics.memory(phase: "asset-job-error", asset: persistedAssets[index].queueAssetID.uuidString, job: index + 1)
                IOSImportDiagnostics.log("asset-job[\(index + 1)] ERROR elapsed=\(started.duration(to: .now)) error=\(String(describing: type(of: error)))")
                throw error
            }
        }
        var failures: [String] = []
        for outcome in outcomes {
            if let result = outcome.result {
                self.apply(result.1, job: outcome.index, filename: assets[outcome.index].filename ?? selection[outcome.index].asset.localIdentifier)
            } else {
                let message = outcome.errorDescription ?? "Asset-Import fehlgeschlagen."
                if outcome.isTransientConnectivity {
                    try await queueStore.markAsset(runID: runID, assetID: persistedAssets[outcome.index].queueAssetID, state: .needsReconcile, lastConfirmedStep: "connectivity-lost")
                } else {
                    failures.append(message)
                    try await queueStore.markAsset(runID: runID, assetID: persistedAssets[outcome.index].queueAssetID, state: .failed, lastConfirmedStep: "asset-failed")
                }
            }
        }
        await reconcileBackgroundTasks()
        if let savedRun = await queueStore.run(localRunID: runID) {
            total = max(total, savedRun.assets.count)
            restoreMetrics(from: savedRun)
        }
        if outcomes.contains(where: { $0.isTransientConnectivity }) {
            throw UploadError.networkUnavailable
        }
        if let firstFailure = failures.first {
            throw UploadError.diagnostic(firstFailure)
        }
    }

    private func runAssetJob(index: Int, selected: GalleryAsset, asset: AssetInventory, entry: InventoryAssetReply, reply: InventoryReply, library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, targetRoot: String, transport: any DAVTransport, folderCoordinator: WebDAVFolderCoordinator, runID: UUID, queueAsset: PersistedImportAsset) async throws -> AssetJobOutcome {
        try Task.checkCancellation()
        guard reply.assets.indices.contains(index) else { throw InventoryCheckError.invalidResponse }
        if queueAsset.state == .completed { return .completed }
        let queueAssetID = queueAsset.queueAssetID
        if entry.state == .known { try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "inventory-known"); self.markAlready(); return .known }
        guard let ticket = entry.upload else { throw InventoryCheckError.invalidResponse }
        IOSImportDiagnostics.memory(phase: "photo-export-start", asset: queueAssetID.uuidString, job: index + 1)
        let exportPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] photo-original-export")
        let exported: PhotoLibraryModel.ExportedOriginal
        do { exported = try await library.exportOriginal(for: selected, diagnosticAssetID: queueAssetID.uuidString, diagnosticJob: index + 1); IOSImportDiagnostics.memory(phase: "photo-export-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] photo-original-export", started: exportPhase, detail: "bytes=pending") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] photo-original-export", started: exportPhase, error: error); throw error }
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        let hashPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] sha256"); IOSImportDiagnostics.memory(phase: "sha256-start", asset: queueAssetID.uuidString, job: index + 1)
        let identity: ContentIdentity
        do {
            identity = try await Task.detached {
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
            }.value
            IOSImportDiagnostics.memory(phase: "sha256-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] sha256", started: hashPhase, detail: "bytes=\(identity.bytes)")
        }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] sha256", started: hashPhase, error: error); throw error }
        let date = selected.creationDate
        guard let uploadPath = IOSUploadPath.folder(base: targetRoot, date: date) else { throw UploadError.invalidConfiguration }
        let folder = uploadPath.folder
        let provider = IOSUploadTargets(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, folder: folder)
        IOSImportDiagnostics.memory(phase: "prepare-start", asset: queueAssetID.uuidString, job: index + 1)
        let putPhase = IOSImportDiagnostics.start("asset-job[\(index + 1)] webdav-transfer")
        try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .needsReconcile, lastConfirmedStep: "remote-state-unknown")
        let target: UploadTarget
        let backgroundTransport = IOSBackgroundDAVTransport(base: transport, background: backgroundTransfer, queueAssetID: queueAssetID, localRunID: runID)
        let backgroundUploader = WebDAVUploader(connection: connection, transport: backgroundTransport, debug: { message in IOSImportDiagnostics.log(message) }, folderCoordinator: folderCoordinator)
        do { target = try await backgroundUploader.uploadWithTarget(file: exported.url, filename: exported.filename, assetId: ticket.assetId, captureDate: date, targets: provider, targetRoot: uploadPath.root, progress: { [weak self] sent, total in
            Task { @MainActor in self?.updateTransferProgress(job: index, sent: sent, total: total) }
        }, contentIdentityDiagnostics: { event in
            switch event {
            case .begin: IOSImportDiagnostics.memory(phase: "sha256-read-begin", asset: queueAssetID.uuidString, job: index + 1)
            case .progress(let bytes): IOSImportDiagnostics.memory(phase: "sha256-progress", asset: queueAssetID.uuidString, job: index + 1, readMiB: Double(bytes) / (1024.0 * 1024.0))
            case .end: IOSImportDiagnostics.memory(phase: "sha256-read-end", asset: queueAssetID.uuidString, job: index + 1)
            }
        }, contentIdentity: identity); IOSImportDiagnostics.memory(phase: "prepare-end", asset: queueAssetID.uuidString, job: index + 1); IOSImportDiagnostics.finish("asset-job[\(index + 1)] webdav-transfer", started: putPhase, detail: "bytes=\(identity.bytes)") }
        catch { IOSImportDiagnostics.failure("asset-job[\(index + 1)] webdav-transfer", started: putPhase, error: error); throw error }
        if target.state == "contentAlreadyPresent" { try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "content-reconciled", targetPath: target.path); await backgroundTransport.cleanup(deleteFile: true); self.markReconciled(); return .reconciled }
        pendingCompletion.insert(index)
        transferProgress.remove(job: index)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
        try Task.checkCancellation()
        backgroundTransfer.beginComplete(uploadAttemptID: backgroundTransport.uploadAttemptID)
        do {
            try await IOSUploadHTTP.complete(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: target.path, queueAssetID: queueAssetID, uploadAttemptID: backgroundTransport.uploadAttemptID)
        } catch {
            backgroundTransfer.endComplete(uploadAttemptID: backgroundTransport.uploadAttemptID)
            pendingCompletion.remove(index)
            throw error
        }
        backgroundTransfer.endComplete(uploadAttemptID: backgroundTransport.uploadAttemptID)
        pendingCompletion.remove(index)
        try await queueStore.markAsset(runID: runID, assetID: queueAssetID, state: .completed, lastConfirmedStep: "complete-confirmed", targetPath: target.path)
        await backgroundTransport.cleanup(deleteFile: true)
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
        guard !isCancelling, phase != .cancelled else { return }
        transferProgress.update(job: job, sent: sent, total: total)
        transferSentBytes = transferProgress.sentBytes
        transferTotalBytes = transferProgress.totalBytes
    }

    private func updateGateWaiting(_ waiting: Bool, generation: Int) {
        IOSImportDiagnostics.state("GATE_CALLBACK", values: diagnosticValues(extra: "waiting=\(waiting) callbackGeneration=\(generation)"))
        guard ImportConnectivityPolicy.acceptsCallback(callbackGeneration: generation, currentGeneration: stateGeneration, cancelling: isCancelling) else { return }
        gateWaitingForWiFi = waiting
        recomputeWaitingState()
    }

    private func updateBackgroundWaiting(_ waiting: Bool) {
        guard !isCancelling else { return }
        backgroundWaitingForConnectivity = waiting
        recomputeWaitingState()
    }

    private func recomputeWaitingState() {
        guard !isCancelling else { return }
        // The gate is the authoritative policy-aware source. Background
        // activity is retained separately for UI/reconciliation diagnostics;
        // it must not clear a policy wait merely because a URLSession task is
        // technically still bound or reports waiting=false.
        isWaitingForWiFi = ImportConnectivityPolicy.shouldShowWiFiWait(
            allowsCellular: IOSTransferNetworkPreferences.useCellularAccess(),
            wifiAvailable: currentWiFiAvailable,
            gateWaiting: gateWaitingForWiFi,
            cancelling: isCancelling
        )
        IOSImportDiagnostics.state("RECOMPUTE_WAITING", values: diagnosticValues())
    }

    private func updatePolicyPath(wifiAvailable: Bool) {
        guard !isCancelling else { return }
        currentWiFiAvailable = wifiAvailable
        gateWaitingForWiFi = !IOSTransferNetworkPreferences.useCellularAccess() && !wifiAvailable
        recomputeWaitingState()
    }

    func diagnosticValues(extra: String = "") -> String {
        let run = activeRunID.map { String($0.uuidString.prefix(8)) } ?? "<none>"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        return "coordinator=\(instanceID) run=\(run) generation=\(stateGeneration) useCellular=\(IOSTransferNetworkPreferences.useCellularAccess()) gateWaiting=\(gateWaitingForWiFi) backgroundWaiting=\(backgroundWaitingForConnectivity) isWaiting=\(isWaitingForWiFi) activeBackground=\(hasActiveBackgroundTransfer) running=\(isRunning) phase=\(phase)\(suffix)"
    }

    func restoreMetrics(from run: PersistedImportRun) {
        guard !run.assets.isEmpty else { return }
        total = run.assets.count
        completed = Self.completedAssetCount(in: run)
        alreadyPresent = run.assets.filter { $0.state == .completed && ($0.lastConfirmedStep.contains("known") || $0.lastConfirmedStep.contains("reconciled")) }.count
        reconciled = run.assets.filter { $0.state == .completed && $0.lastConfirmedStep.contains("reconciled") }.count
        uploaded = max(0, completed - alreadyPresent)
    }

    private func setCurrent(_ asset: PHAsset, filename: String?) { currentFilename = filename ?? asset.localIdentifier }
    private func setProgress(_ _: Double) {}
    private func setPhase(_ value: Phase) { guard !isCancelling else { return }; phase = value }
    private func markAlready() { alreadyPresent += 1; completed += 1 }
    private func markUploaded() { uploaded += 1; completed += 1 }
    private func markReconciled() { reconciled += 1; alreadyPresent += 1; completed += 1 }
    private func finish() { guard !isCancelling else { return }; hasActiveBackgroundTransfer = false; phase = .finished }
    private func cancelled() { guard !isCancelling else { return }; phase = .cancelled; if let runID = activeRunID { Task { try? await queueStore.markRun(runID: runID, state: .cancelled, albumSyncPending: false) } } }
    private func failed(_ message: String) { guard !isCancelling else { return }; failure = message; phase = .failed; if let runID = activeRunID { Task { try? await queueStore.markRun(runID: runID, state: .failed) } } }
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
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.response(step: endpoint, response: response, expected: "UploadTarget"); IOSImportDiagnostics.finish(endpoint, started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure(endpoint, started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
        do { return try JSONDecoder().decode(UploadTarget.self, from: response.data) }
        catch { IOSImportDiagnostics.response(step: endpoint, response: response, expected: "UploadTarget", decodeError: error); throw error }
    }
    static func complete(connection: ConnectorConnection, transport: any DAVTransport, source: String, runId: String, uploadId: String, path: String, queueAssetID: UUID? = nil, uploadAttemptID: UUID? = nil) async throws {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "uploads", "complete"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sourceId": source, "runId": runId, "uploadId": uploadId, "status": "uploaded", "path": path])
        let correlation = [queueAssetID.map { "queueAssetID=\($0.uuidString.prefix(8))" }, uploadAttemptID.map { "uploadAttemptID=\($0.uuidString)" }].compactMap { $0 }.joined(separator: " ")
        let phase = IOSImportDiagnostics.start("uploads/complete \(correlation)")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil, kind: .longRunningVerification, progress: nil); IOSImportDiagnostics.response(step: "uploads/complete", response: response); IOSImportDiagnostics.finish("uploads/complete", started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure("uploads/complete", started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
    }
}
