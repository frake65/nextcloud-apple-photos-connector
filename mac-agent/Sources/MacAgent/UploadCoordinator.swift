import Foundation
import InventoryCore
import MacAgentSupport

actor UploadCoordinator {
    enum DisplayStatus: String, Sendable {
        case uploading, uploaded, alreadyInCloud, failed, open
        var label: String {
            switch self {
            case .uploading: L10n.text("uploadRunning")
            case .uploaded: L10n.text("assetUploaded")
            case .alreadyInCloud: L10n.text("assetAlreadyInCloud")
            case .failed: L10n.text("failed")
            case .open: L10n.text("assetOpen")
            }
        }
    }
    struct DisplayItem: Identifiable, Sendable {
        let id: String
        let filename: String
        let source: String
        let target: String?
        let status: DisplayStatus
        let error: UploadFailure?
    }
    struct RunSummary: Sendable {
        let uploadedImages: Int; let uploadedVideos: Int; let uploadedOther: Int
        let alreadyInCloudImages: Int; let alreadyInCloudVideos: Int; let alreadyInCloudOther: Int
        let failed: Int
        let finalProgress: Progress
        var shouldCloseProgressSheet: Bool { failed == 0 }
    }
    struct Progress: Sendable {
        let completed: Int; let total: Int; let filename: String?; let failed: Bool
        let cancelled: Bool
        let items: [DisplayItem]
        var finished: Bool { completed >= total }
        var summaryText: String {
            let uploaded = items.filter { $0.status == .uploaded }.count
            let known = items.filter { $0.status == .alreadyInCloud }.count
            let failed = items.filter { $0.status == .failed }.count
            let summary = L10n.format("importRunSummary", uploaded, total, known, failed)
            guard cancelled else { return summary }
            let notProcessed = max(0, total - uploaded - known - failed)
            return "\(summary) \(L10n.format("notProcessedCount", notProcessed))"
        }
        func markingCancelled() -> Progress {
            Progress(completed: completed, total: total, filename: filename, failed: false, cancelled: true,
                items: items.map { item in
                    guard item.status == .uploading else { return item }
                    return DisplayItem(id: item.id, filename: item.filename, source: item.source,
                        target: item.target, status: .open, error: nil)
                })
        }
    }
    static let maxConcurrentUploads = 3
    private struct UploadJob: Sendable { let index: Int; let entry: InventoryReply.Entry }
    private struct UploadOutcome: Sendable { let job: UploadJob; let result: SingleUploadResult }
    private actor DisplayProgressState {
        var items: [DisplayItem]; var completed: Int; let total: Int
        init(items: [DisplayItem], completed: Int, total: Int) { self.items = items; self.completed = completed; self.total = total }
        func updateStatus(index: Int, status: DisplayStatus, target: String? = nil, error: UploadFailure? = nil) {
            let old = items[index]
            items[index] = DisplayItem(id: old.id, filename: old.filename, source: old.source,
                target: target ?? old.target, status: status, error: error)
        }
        func complete() { completed += 1 }
        func snapshot(filename: String? = nil, failed: Bool = false) -> Progress {
            Progress(completed: completed, total: total, filename: filename, failed: failed || items.contains { $0.status == .failed }, cancelled: false, items: items)
        }
    }
    enum SingleUploadResult: Sendable {
        case success(path: String, filename: String)
        case failed(filename: String?, error: UploadFailure)
        case cancelled
    }
    private struct Targets: UploadTargetProvider {
        let owner: UploadCoordinator
        let sourceId: String
        let runId: String
        let uploadId: String
        let folder: String
        let connection: ConnectorConnection
        let debug: (@Sendable (String) -> Void)?
        func prepare(identity: ContentIdentity) async throws -> UploadTarget {
            debug?("upload.prepare.start")
            do {
                let data = try await owner.post(["sourceId": sourceId, "runId": runId, "uploadId": uploadId,
                                            "bytes": identity.bytes, "sha256": identity.sha256, "folder": folder], endpoint: "uploads/prepare", connection: connection)
                debug?("Response uploads/prepare · responseBytes=\(data.count)")
                return try JSONDecoder().decode(UploadTarget.self, from: data)
            } catch is CancellationError { throw CancellationError() }
            catch { throw UploadFailure.capture(error, stage: .target) }
        }
    }
    struct InventoryReply: Decodable {
        struct Entry: Decodable, Sendable {
            struct Ticket: Decodable, Sendable { let uploadId: String; let assetId: String }
            let state: String
            let upload: Ticket?
        }
        let runId: String
        let assets: [Entry]
    }
    struct Receipt: Codable {
        let server: String
        let user: String
        let sourceId: String
        let runId: String
        let uploadId: String
        let path: String
    }
    enum RunError: Error { case alreadyRunning }
    private var running = false
    private let gate: SettingsWorkGate
    private let exporter: any PhotoOriginalExporting
    private let transport: any DAVTransport
    private let receiptURL: URL

    private func debugLog(_ message: String) { debugSink?(message) }
    private var debugSink: (@Sendable (String) -> Void)?
    init(exporter: any PhotoOriginalExporting = PhotoOriginalExporter(), transport: any DAVTransport = NetworkTransport(), gate: SettingsWorkGate = .shared, receiptURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Apple Photos Connector/upload-receipts.json")) {
        self.receiptURL = receiptURL
        self.gate = gate
        self.exporter = exporter
        self.transport = transport
    }
    private func post(_ body: [String: Any], endpoint: String, connection: ConnectorConnection) async throws -> Data {
        var request = connection.request(path: ["index.php", "apps", "apple_photos_connector", "api", "v1"] + endpoint.split(separator: "/").map(String.init), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        debugLog("Request POST · endpoint=/\(endpoint) · payloadBytes=\(request.httpBody?.count ?? 0)")
        if endpoint == "inventory" { debugLog("inventory.request.sent") }
        let response: DAVResponse
        do {
            debugLog("NETWORK_REQUEST_BEGIN kind=\(endpoint) url=/\(endpoint)")
            response = try await transport.send(request, file: nil)
            debugLog("NETWORK_REQUEST_END kind=\(endpoint) status=\(response.status)")
        } catch let error as CancellationError {
            if endpoint == "inventory" { debugLog("inventory.request.cancelled") }
            throw error
        } catch {
            let nsError = error as NSError
            if case let UploadError.http(status) = error {
                debugLog("NETWORK_HTTP_ERROR kind=\(endpoint) status=\(status)")
            } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                debugLog("NETWORK_TIMEOUT kind=\(endpoint)")
            } else {
                debugLog("NETWORK_ERROR kind=\(endpoint) error=\(nsError.domain):\(nsError.code)")
            }
            if endpoint == "inventory" {
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    debugLog("inventory.request.timeout")
                }
                debugLog("inventory.request.error category=network")
            }
            throw error
        }
        debugLog("Response POST · endpoint=/\(endpoint) · status=\(response.status) · responseBytes=\(response.data.count)")
        if endpoint == "inventory" {
            debugLog("inventory.response.received")
            debugLog("inventory.request.status=\(response.status)")
        }
        if endpoint == "uploads/prepare" { debugLog("upload.prepare.status=\(response.status)") }
        if endpoint == "uploads/complete" { debugLog("upload.complete.status=\(response.status)") }
        if response.status != 200 {
            if endpoint == "inventory" { debugLog("inventory.request.error category=http") }
            if endpoint == "uploads/prepare", let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let code = object["code"] as? String,
               ["invalid_folder", "content_changed", "invalid_ticket", "target_conflict", "invalid_request", "unknown"].contains(code) {
                debugLog("upload.prepare.error=\(code)")
            }
            let detail = String(data: response.data, encoding: .utf8) ?? "<non-UTF8 response>"
            debugLog("Response error · endpoint=/\(endpoint) · body=\(detail)")
            if endpoint == "uploads/complete" { debugLog("upload.complete.error category=http") }
            throw UploadError.http(response.status)
        }
        if endpoint == "uploads/complete" { debugLog("upload.complete.http.success") }
        return response.data
    }
    private func save(_ receipts: [Receipt]) throws {
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }
    private func confirm(_ receipt: Receipt, connection: ConnectorConnection) async throws {
        _ = try await post(["sourceId": receipt.sourceId, "runId": receipt.runId, "uploadId": receipt.uploadId,
                           "status": "uploaded", "path": receipt.path], endpoint: "uploads/complete", connection: connection)
    }

    private func uploadAsset(index: Int, entry: InventoryReply.Entry, assetsData: Data, sourceId: String,
                             connection: ConnectorConnection, targetRoot: String, runId: String, debug: (@Sendable (String) -> Void)?,
                             displayState: DisplayProgressState, folderCoordinator: WebDAVFolderCoordinator, progress: (@Sendable (Progress) -> Void)?) async -> SingleUploadResult {
        var currentFilename: String?
        var stage: UploadFailure.Stage = .preparation
        do {
            try Task.checkCancellation()
            guard let assets = try JSONSerialization.jsonObject(with: assetsData) as? [[String: Any]],
                  let local = assets[index]["localIdentifier"] as? String,
                  let filename = assets[index]["filename"] as? String else { throw UploadError.invalidFilename }
            currentFilename = filename
            debug?("PREPARE_START assetID=\(local) file=\(filename)")
            try await gate.checkpoint()
            try Task.checkCancellation()
            debug?("upload.export.start")
            stage = .export
            let resource = try await exporter.export(localIdentifier: local)
            try Task.checkCancellation()
            stage = .preparation
            debug?("upload.export.success")
            defer { try? FileManager.default.removeItem(at: resource.url.deletingLastPathComponent()) }
            guard resource.filename == filename else { throw UploadError.invalidFilename }
            let assetDate = (assets[index]["creationDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let resolution = await CaptureDateResolver().resolve(file: resource.url, assetDate: assetDate)
            let calendar = Calendar(identifier: .gregorian)
            let year = calendar.component(.year, from: resolution.date)
            let month = calendar.component(.month, from: resolution.date)
            let baseFolder = targetRoot
            let targets = Targets(owner: self, sourceId: sourceId.lowercased(), runId: runId, uploadId: entry.upload!.uploadId,
                                  folder: "\(baseFolder)/\(String(format: "%04d", year))/\(String(format: "%02d", month))",
                                  connection: connection, debug: debug)
            try await gate.checkpoint()
            try Task.checkCancellation()
            let path = try await WebDAVUploader(connection: connection, transport: UploadDisplayTransport(base: transport), debug: debug)
                .upload(file: resource.url, filename: filename, assetId: entry.upload!.assetId, captureDate: resolution.date, targets: targets, targetRoot: baseFolder, folderCoordinator: folderCoordinator)
            debug?("upload.put.success")
            return .success(path: path, filename: filename)
        } catch is CancellationError {
            debug?("upload.put.cancelled")
            return .cancelled
        } catch {
            let ns = error as NSError
            let category: String
            if case UploadError.http = error { category = "http" }
            else if ns.domain == NSURLErrorDomain { category = "transport" }
            else if error is UploadError { category = "unexpected-response" }
            else { category = "filesystem" }
            debug?("upload.put.failed category=\(category)")
            if case let UploadError.http(status) = error { debug?("upload.put.http.status=\(status)") }
            debug?("upload.put.error.domain=\(ns.domain)")
            debug?("upload.put.error.code=\(ns.code)")
            return .failed(filename: currentFilename, error: UploadFailure.capture(error, stage: stage))
        }
    }

    func run(json: String, connection: ConnectorConnection, targetRoot: String? = nil, progress: (@Sendable (Progress) -> Void)? = nil, debug: (@Sendable (String) -> Void)? = nil, onUploaded: (@Sendable (String) -> Void)? = nil) async throws -> RunSummary {
        guard !running else { throw RunError.alreadyRunning }
        do {
            return try await performRun(json: json, connection: connection, targetRoot: targetRoot, progress: progress, debug: debug, onUploaded: onUploaded)
            } catch is CancellationError { throw CancellationError() }
        catch {
            // Inventory/receipt failures happen before per-asset jobs exist.
            // Keep every selected medium visible even when that early stage fails.
            if let document = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let assets = document["assets"] as? [[String: Any]] {
                let failure = UploadFailure.capture(error, stage: .inventory)
                let items = assets.enumerated().map { index, asset in
                    let filename = asset["filename"] as? String ?? L10n.text("file")
                    return DisplayItem(id: String(index), filename: filename, source: filename, target: nil, status: .failed, error: failure)
                }
                progress?(Progress(completed: items.count, total: items.count, filename: nil, failed: true, cancelled: false, items: items))
            }
            throw error
        }
    }

    private func performRun(json: String, connection: ConnectorConnection, targetRoot: String?, progress: (@Sendable (Progress) -> Void)?, debug: (@Sendable (String) -> Void)?, onUploaded: (@Sendable (String) -> Void)?) async throws -> RunSummary {
        guard !running else { throw RunError.alreadyRunning }
        running = true
        defer { running = false }
        try await gate.checkpoint()
        let targetRoot = targetRoot ?? TargetDirectoryPreferences().path
        debugSink = debug
        debug?("upload.coordinator.entered")
        var receipts = FileManager.default.fileExists(atPath: receiptURL.path)
            ? try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: receiptURL)) : []
        // Reconcile successful PUTs before asking for new work; no second upload after a lost ACK response.
        for receipt in receipts where receipt.server == connection.base.absoluteString && receipt.user == connection.user {
            try await confirm(receipt, connection: connection)
            receipts.removeAll { $0.uploadId == receipt.uploadId }
            try save(receipts)
        }
        guard let document = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let source = document["source"] as? [String: Any], let sourceId = source["sourceId"] as? String,
              let assets = document["assets"] as? [[String: Any]] else { throw UploadError.invalidResponse }
        let inventoryDocument = document
        debug?("inventory.payload.assets=\(assets.count)")
        guard !assets.isEmpty else {
            debug?("upload.outcome=failed reason=empty-inventory")
            throw UploadError.invalidResponse
        }
        let requestData = try JSONSerialization.data(withJSONObject: inventoryDocument)
        debug?("inventory.request.start")
        debug?("POST inventory · payloadBytes=\(requestData.count)")
        try await gate.checkpoint()
        let inventoryData = try await post(inventoryDocument, endpoint: "inventory", connection: connection)
        debug?("Response inventory · status=200 · responseBytes=\(inventoryData.count)")
        debug?("inventory.response.decode.start")
        let reply: InventoryReply
        do {
            reply = try JSONDecoder().decode(InventoryReply.self, from: inventoryData)
        } catch {
            debug?("inventory.response.decode.error")
            throw error
        }
        debug?("inventory.response.decode.success")
        guard reply.assets.count == assets.count else {
            debug?("inventory.response.validation.error reason=count")
            throw UploadError.invalidResponse
        }
        guard reply.assets.allSatisfy({ ($0.state == "new" && $0.upload != nil) || ($0.state == "known" && $0.upload == nil) }) else {
            debug?("inventory.response.validation.error reason=state_ticket")
            debug?("upload.queue.skipped reason=invalid_response")
            throw UploadError.invalidResponse
        }
        let jobs: [UploadJob] = reply.assets.enumerated().compactMap { index, entry in
            debug?("inventory.response.state=\(entry.state)")
            debug?("inventory.response.ticket=\(entry.upload != nil)")
            guard entry.state == "new", entry.upload != nil else {
                debug?("upload.queue.skipped reason=\(entry.state == "known" ? "known" : "no_ticket")")
                return nil
            }
            debug?("upload.queue.added")
            return UploadJob(index: index, entry: entry)
        }
        let totalUploads = assets.count
        var completedUploads = reply.assets.filter { $0.state == "known" }.count
        var uploaded = 0
        var uploadedImages = 0
        var uploadedVideos = 0
        var uploadedOther = 0
        var alreadyInCloudImages = 0
        var alreadyInCloudVideos = 0
        var alreadyInCloudOther = 0
        var failed = 0
        let displayItems: [DisplayItem] = reply.assets.enumerated().map { index, entry in
            let filename = assets[index]["filename"] as? String ?? L10n.text("file")
            if entry.state == "known" {
                return DisplayItem(id: String(index), filename: filename,
                    source: filename, target: nil, status: .alreadyInCloud, error: nil)
            }
            return DisplayItem(id: String(index), filename: filename,
                source: filename, target: nil, status: .uploading, error: nil)
        }
        let displayState = DisplayProgressState(items: displayItems, completed: completedUploads, total: totalUploads)
        let folderCoordinator = WebDAVFolderCoordinator()
        progress?(await displayState.snapshot())

        var nextJob = 0
        let assetsData = try JSONSerialization.data(withJSONObject: assets)
        await withTaskGroup(of: UploadOutcome.self) { group in
            var active = 0
            func scheduleNext() {
                guard nextJob < jobs.count else { return }
                let job = jobs[nextJob]
                nextJob += 1
                active += 1
                group.addTask { [self] in
                    let outcome = await uploadAsset(index: job.index, entry: job.entry, assetsData: assetsData,
                        sourceId: sourceId, connection: connection, targetRoot: targetRoot, runId: reply.runId, debug: debug,
                        displayState: displayState, folderCoordinator: folderCoordinator, progress: progress)
                    return UploadOutcome(job: job, result: outcome)
                }
            }
            while nextJob < jobs.count || active > 0 {
                // Drain completed jobs (and persist receipts) even while paused.
                // Only an empty group waits for resumption, then refills once.
                if active == 0 {
                    do { try await gate.checkpoint() }
                    catch { group.cancelAll(); break }
                }
                while active < Self.maxConcurrentUploads && nextJob < jobs.count
                    && !gate.isPaused && !Task.isCancelled {
                    scheduleNext()
                }
                guard active > 0 else {
                    if Task.isCancelled { break }
                    continue
                }
                guard let outcome = await group.next() else { break }
                active -= 1
                let ticket = outcome.job.entry.upload!
                switch outcome.result {
                case .cancelled:
                    group.cancelAll()
                    break
                case let .success(path, filename):
                    let receipt = Receipt(server: connection.base.absoluteString, user: connection.user,
                        sourceId: sourceId.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: path)
                    var completionStage: UploadFailure.Stage = .receipt
                    do {
                        debug?("upload.complete.request.status=success")
                        receipts.append(receipt)
                        try save(receipts)
                        completionStage = .completion
                        try await confirm(receipt, connection: connection)
                        completionStage = .receipt
                        receipts.removeAll { $0.uploadId == ticket.uploadId }
                        try save(receipts)
                        uploaded += 1
                        if let identity = assets[outcome.job.index]["cloudIdentifier"] as? String {
                            onUploaded?(identity)
                        } else if let identity = assets[outcome.job.index]["localIdentifier"] as? String {
                            onUploaded?("local:\(identity)")
                        }
                        let mediaType = assets[outcome.job.index]["mediaType"] as? String
                        if mediaType == "image" { uploadedImages += 1 }
                        else if mediaType == "video" { uploadedVideos += 1 }
                        else { uploadedOther += 1 }
                        completedUploads += 1
                        await displayState.updateStatus(index: outcome.job.index, status: .uploaded, target: path)
                        await displayState.complete()
                        progress?(await displayState.snapshot(filename: filename))
                    } catch is CancellationError {
                        group.cancelAll()
                        break
                    } catch {
                        failed += 1
                        completedUploads += 1
                        let failure = UploadFailure.capture(error, stage: completionStage)
                        await displayState.updateStatus(index: outcome.job.index, status: .failed, target: path, error: failure)
                        await displayState.complete()
                        debug?("Upload completion failed · \(failure.technicalDetail)")
                        progress?(await displayState.snapshot(filename: filename, failed: true))
                    }
                case let .failed(filename, error):
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    do {
                        debug?("upload.complete.request.status=failed")
                        _ = try await post(["sourceId": sourceId.lowercased(), "runId": reply.runId,
                            "uploadId": ticket.uploadId, "status": "failed"], endpoint: "uploads/complete", connection: connection)
                    } catch is CancellationError {
                        group.cancelAll()
                        break
                    } catch { debug?("Upload failure acknowledgement failed · error=\(error.localizedDescription)") }
                    failed += 1
                    completedUploads += 1
                    await displayState.updateStatus(index: outcome.job.index, status: .failed, error: error)
                    await displayState.complete()
                    debug?("Upload failed · error=\(error)")
                    progress?(await displayState.snapshot(filename: filename, failed: true))
                }
            }
        }
        try Task.checkCancellation()
        let newCount = reply.assets.filter { $0.state == "new" }.count
        let knownCount = reply.assets.filter { $0.state == "known" }.count
        for (index, entry) in reply.assets.enumerated() where entry.state == "known" {
            switch assets[index]["mediaType"] as? String {
            case "image": alreadyInCloudImages += 1
            case "video": alreadyInCloudVideos += 1
            default: alreadyInCloudOther += 1
            }
        }
        debug?("Inventory decoded · assets=\(reply.assets.count) · new=\(newCount) · known=\(knownCount) · uploadTickets=\(totalUploads)")
        debug?("upload.counter.uploaded=\(uploaded)")
        debug?("upload.outcome=\(failed > 0 ? "failed" : (uploaded > 0 ? "success" : "nothingToDo"))")
        return RunSummary(uploadedImages: uploadedImages, uploadedVideos: uploadedVideos, uploadedOther: uploadedOther,
            alreadyInCloudImages: alreadyInCloudImages, alreadyInCloudVideos: alreadyInCloudVideos, alreadyInCloudOther: alreadyInCloudOther, failed: failed, finalProgress: await displayState.snapshot())
    }
}
