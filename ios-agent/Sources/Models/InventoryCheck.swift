import Foundation
#if canImport(UIKit)
import UIKit
#endif
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
enum BackgroundTaskReconciliation: Equatable, Sendable { case attached, missingTask, orphanTask, conflictingBinding }

/// Background URLSession adapter for the existing WebDAV PUT contract.
/// Prepare and Complete remain on the existing DAVTransport path.
final class BackgroundTransferCoordinator: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.applephotosconnector.background-webdav-put.v1"
    static let shared = BackgroundTransferCoordinator()
    private let bindingStore: BackgroundTaskBindingStore
    private let fileStore: BackgroundTransferFileStore
    private let queueStore: ImportQueueStore?
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<DAVResponse, Error>] = [:]
    private var responses: [Int: (Data, HTTPURLResponse)] = [:]
    private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
    private var completionInFlight = Set<UUID>()
    private let lifecycleLock = NSLock()
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        IOSImportDiagnostics.log("background session create identifier=\(Self.sessionIdentifier)")
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    init(bindingStore: BackgroundTaskBindingStore = BackgroundTaskBindingStore(), fileStore: BackgroundTransferFileStore = BackgroundTransferFileStore(), queueStore: ImportQueueStore? = nil) {
        self.bindingStore = bindingStore; self.fileStore = fileStore; self.queueStore = queueStore
        IOSImportDiagnostics.log("background session coordinator initialized/reconstructed identifier=\(Self.sessionIdentifier)")
    }
    func send(_ request: URLRequest, file: URL, queueAssetID: UUID, localRunID: UUID, uploadAttemptID: UUID, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host else { throw UploadError.invalidConfiguration }
        let prepared = try await fileStore.prepare(source: file, uploadAttemptID: uploadAttemptID)
        IOSImportDiagnostics.log("transfer file prepared queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) bytes=\(try? FileManager.default.attributesOfItem(atPath: prepared.url.path)[.size] as? NSNumber ?? 0)")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: prepared.url)
                lock.lock(); continuations[task.taskIdentifier] = continuation; progressHandlers[task.taskIdentifier] = progress; lock.unlock()
                task.taskDescription = uploadAttemptID.uuidString
                IOSImportDiagnostics.log("background task start taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString) session=\(Self.sessionIdentifier)")
                Task { let binding = BackgroundTaskBinding(queueAssetID: queueAssetID, localRunID: localRunID, uploadAttemptID: uploadAttemptID, sessionIdentifier: Self.sessionIdentifier, taskIdentifier: task.taskIdentifier, relativeTransferPath: prepared.relativePath, expectedHost: host, targetPath: request.url?.path ?? "", createdAt: Date()); try? await bindingStore.upsert(binding); IOSImportDiagnostics.log("binding created taskIdentifier=\(task.taskIdentifier) queueAssetID=\(queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(uploadAttemptID.uuidString)") }
                task.resume()
            }
        } onCancel: {
            self.cancelAll(for: uploadAttemptID)
        }
    }
    func reconcileTasks(queueStore: ImportQueueStore? = nil) async -> [BackgroundTaskReconciliation] {
        IOSImportDiagnostics.log("reconciliation started session=\(Self.sessionIdentifier)")
        let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in session.getAllTasks { continuation.resume(returning: $0) } }
        let persisted = await bindingStore.all()
        IOSImportDiagnostics.log("startup reconciliation tasks=\(tasks.count) bindings=\(persisted.count)")
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskIdentifier, $0) })
        var result: [BackgroundTaskReconciliation] = []
        for binding in persisted {
            guard let task = byID[binding.taskIdentifier] else {
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
            guard task.taskDescription == binding.uploadAttemptID.uuidString,
                  task.originalRequest?.url?.host == binding.expectedHost else {
                IOSImportDiagnostics.log("conflicting binding taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
                task.cancel()
                if let queueStore { try? await queueStore.markAsset(runID: binding.localRunID, assetID: binding.queueAssetID, state: .needsReconcile, lastConfirmedStep: "background-binding-conflict") }
                try? await bindingStore.remove(uploadAttemptID: binding.uploadAttemptID)
                IOSImportDiagnostics.log("asset -> needsReconcile queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) reason=background-binding-conflict; binding removed")
                result.append(.conflictingBinding); continue
            }
            IOSImportDiagnostics.log("task + binding taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)")
            result.append(.attached)
        }
        let boundIDs = Set(persisted.map(\.taskIdentifier))
        for task in tasks where !boundIDs.contains(task.taskIdentifier) { IOSImportDiagnostics.log("task without binding taskIdentifier=\(task.taskIdentifier)"); task.cancel(); result.append(.orphanTask) }
        return result
    }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        _ = session
        lifecycleLock.lock(); backgroundEventsCompletionHandler = handler; lifecycleLock.unlock()
        IOSImportDiagnostics.log("background events completion handler received")
    }
    func activeBindings() async -> [BackgroundTaskBinding] {
        let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in session.getAllTasks { continuation.resume(returning: $0) } }
        let bindings = await bindingStore.all()
        let taskIDs = Set(tasks.map(\.taskIdentifier))
        let completing = completionInFlightSnapshot()
        let active = bindings.filter { taskIDs.contains($0.taskIdentifier) || completing.contains($0.uploadAttemptID) }
        for binding in active { IOSImportDiagnostics.log("task reattached taskIdentifier=\(binding.taskIdentifier) queueAssetID=\(binding.queueAssetID.uuidString.prefix(8)) uploadAttemptID=\(binding.uploadAttemptID.uuidString)") }
        return active
    }
    func cancelAll(for uploadAttemptID: UUID) { Task { for binding in await bindingStore.all() where binding.uploadAttemptID == uploadAttemptID { session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == binding.taskIdentifier }?.cancel() } } } }
    func cancelAll() { session.getAllTasks { $0.forEach { $0.cancel() } } }
    func beginComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.insert(uploadAttemptID); lock.unlock() }
    func endComplete(uploadAttemptID: UUID) { lock.lock(); completionInFlight.remove(uploadAttemptID); lock.unlock() }
    private func isCompleteInFlight(_ uploadAttemptID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return completionInFlight.contains(uploadAttemptID) }
    private func completionInFlightSnapshot() -> Set<UUID> { lock.lock(); defer { lock.unlock() }; return completionInFlight }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { lock.lock(); let handler = progressHandlers[task.taskIdentifier]; lock.unlock(); IOSImportDiagnostics.log("background progress taskIdentifier=\(task.taskIdentifier) sent=\(totalBytesSent) total=\(totalBytesExpectedToSend)"); handler?(totalBytesSent, totalBytesExpectedToSend) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { lock.lock(); if let current = responses[dataTask.taskIdentifier] { responses[dataTask.taskIdentifier] = (current.0 + data, current.1) }; lock.unlock() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuations.removeValue(forKey: task.taskIdentifier); let response = responses.removeValue(forKey: task.taskIdentifier); progressHandlers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if let error { IOSImportDiagnostics.log("delegate completion taskIdentifier=\(task.taskIdentifier) error=\((error as NSError).code)"); continuation?.resume(throwing: error); return }
        guard let http = (task.response as? HTTPURLResponse) else { IOSImportDiagnostics.log("delegate completion taskIdentifier=\(task.taskIdentifier) error=invalid-response"); continuation?.resume(throwing: UploadError.invalidResponse); return }
        IOSImportDiagnostics.log("HTTP response taskIdentifier=\(task.taskIdentifier) status=\(http.statusCode)")
        guard http.statusCode < 400 else { continuation?.resume(throwing: UploadError.http(http.statusCode)); return }
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
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        IOSImportDiagnostics.log("urlSessionDidFinishEvents identifier=\(Self.sessionIdentifier)")
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
    @Published private(set) var hasActiveBackgroundTransfer = false
    private var task: Task<Void, Never>?
    private let queueStore: ImportQueueStore
    private let backgroundTransfer: BackgroundTransferCoordinator
    private var activeRunID: UUID?
    private var transferProgress = IOSImportProgressAggregation()
    private var pendingCompletion = Set<Int>()
    init(queueStore: ImportQueueStore? = nil) {
        let store = queueStore ?? ImportQueueStore()
        self.queueStore = store
        self.backgroundTransfer = queueStore == nil ? BackgroundTransferCoordinator.shared : BackgroundTransferCoordinator(queueStore: store)
    }
    var overallProgress: Double {
        guard total > 0 else { return 0 }
        if completed >= total { return 1 }
        return min(0.999, (Double(completed + pendingCompletion.count) + transferProgress.activeFraction) / Double(total))
    }
    var isRunning: Bool { hasActiveBackgroundTransfer || ![.idle, .finished, .failed, .cancelled].contains(phase) }
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
    func reconcileBackgroundTasks() async {
        let result = await backgroundTransfer.reconcileTasks(queueStore: queueStore)
        let active = await backgroundTransfer.activeBindings()
        hasActiveBackgroundTransfer = !active.isEmpty
        if !active.isEmpty { IOSImportDiagnostics.log("run exposed as active count=\(active.count)") }
        else if !result.isEmpty { IOSImportDiagnostics.log("run exposed as recoverable") }
    }

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
        let backgroundTransport = IOSBackgroundDAVTransport(base: transport, background: backgroundTransfer, queueAssetID: queueAssetID, localRunID: runID)
        let backgroundUploader = WebDAVUploader(connection: connection, transport: backgroundTransport, debug: { message in IOSImportDiagnostics.log(message) })
        do { target = try await backgroundUploader.uploadWithTarget(file: exported.url, filename: exported.filename, assetId: ticket.assetId, captureDate: date, targets: provider, targetRoot: "Photos/Apple Photos Connector", progress: { [weak self] sent, total in
            Task { @MainActor in self?.updateTransferProgress(job: index, sent: sent, total: total) }
        }); IOSImportDiagnostics.finish("asset-job[\(index + 1)] webdav-transfer", started: putPhase, detail: "bytes=\(identity.bytes)") }
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
    static func complete(connection: ConnectorConnection, transport: any DAVTransport, source: String, runId: String, uploadId: String, path: String, queueAssetID: UUID? = nil, uploadAttemptID: UUID? = nil) async throws {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1", "uploads", "complete"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sourceId": source, "runId": runId, "uploadId": uploadId, "status": "uploaded", "path": path])
        let correlation = [queueAssetID.map { "queueAssetID=\($0.uuidString.prefix(8))" }, uploadAttemptID.map { "uploadAttemptID=\($0.uuidString)" }].compactMap { $0 }.joined(separator: " ")
        let phase = IOSImportDiagnostics.start("uploads/complete \(correlation)")
        let response: DAVResponse
        do { response = try await transport.send(request, file: nil, kind: .longRunningVerification, progress: nil); IOSImportDiagnostics.finish("uploads/complete", started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure("uploads/complete", started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
    }
}
