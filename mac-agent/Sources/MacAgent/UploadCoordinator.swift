import Foundation
import InventoryCore

actor UploadCoordinator {
    struct RunSummary: Sendable {
        let uploadedImages: Int; let uploadedVideos: Int; let uploadedOther: Int
        let alreadyInCloudImages: Int; let alreadyInCloudVideos: Int; let alreadyInCloudOther: Int
    }
    struct Progress: Sendable { let completed: Int; let total: Int; let filename: String?; let failed: Bool }
    static let maxConcurrentUploads = 3
    private struct UploadJob: Sendable { let index: Int; let entry: InventoryReply.Entry }
    private struct UploadOutcome: Sendable { let job: UploadJob; let result: SingleUploadResult }
    enum SingleUploadResult: Sendable {
        case success(path: String, filename: String)
        case failed(filename: String?, error: String)
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
            let data = try await owner.post(["sourceId": sourceId, "runId": runId, "uploadId": uploadId,
                                            "bytes": identity.bytes, "sha256": identity.sha256, "folder": folder], endpoint: "uploads/prepare", connection: connection)
            debug?("Response uploads/prepare · responseBytes=\(data.count)")
            return try JSONDecoder().decode(UploadTarget.self, from: data)
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
    private let receiptURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Apple Photos Connector/upload-receipts.json")

    private func debugLog(_ message: String) { debugSink?(message) }
    private var debugSink: (@Sendable (String) -> Void)?
    init(exporter: any PhotoOriginalExporting = PhotoOriginalExporter(), transport: any DAVTransport = NetworkTransport(), gate: SettingsWorkGate = .shared) {
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
            response = try await transport.send(request, file: nil)
        } catch let error as CancellationError {
            if endpoint == "inventory" { debugLog("inventory.request.cancelled") }
            throw error
        } catch {
            if endpoint == "inventory" {
                let nsError = error as NSError
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
                             connection: ConnectorConnection, targetRoot: String, runId: String, debug: (@Sendable (String) -> Void)?) async -> SingleUploadResult {
        var currentFilename: String?
        do {
            guard let assets = try JSONSerialization.jsonObject(with: assetsData) as? [[String: Any]],
                  let local = assets[index]["localIdentifier"] as? String,
                  let filename = assets[index]["filename"] as? String else { throw UploadError.invalidFilename }
            currentFilename = filename
            try await gate.checkpoint()
            debug?("upload.export.start")
            let resource = try await exporter.export(localIdentifier: local)
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
            let path = try await WebDAVUploader(connection: connection, transport: transport, debug: debug)
                .upload(file: resource.url, filename: filename, assetId: entry.upload!.assetId, captureDate: resolution.date, targets: targets, targetRoot: baseFolder)
            debug?("upload.put.success")
            return .success(path: path, filename: filename)
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
            return .failed(filename: currentFilename, error: error.localizedDescription)
        }
    }

    func run(json: String, connection: ConnectorConnection, targetRoot: String? = nil, retransferMissing: Bool? = nil, progress: (@Sendable (Progress) -> Void)? = nil, debug: (@Sendable (String) -> Void)? = nil) async throws -> RunSummary {
        guard !running else { throw RunError.alreadyRunning }
        running = true
        defer { running = false }
        try await gate.checkpoint()
        let targetRoot = targetRoot ?? TargetDirectoryPreferences().path
        let retransferMissing = retransferMissing ?? (UserDefaults(suiteName: ConnectionPreferences.preferencesSuite)?.bool(forKey: UploadPreferences.retransferMissingKey) ?? false)
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
        var inventoryDocument = document
        debug?("inventory.payload.assets=\(assets.count)")
        guard !assets.isEmpty else {
            debug?("upload.outcome=failed reason=empty-inventory")
            throw UploadError.invalidResponse
        }
        inventoryDocument["retransferMissing"] = retransferMissing
        debug?("reinventory.enabled=\(retransferMissing)")
        let requestData = try JSONSerialization.data(withJSONObject: inventoryDocument)
        debug?("inventory.request.start")
        debug?("POST inventory · payloadBytes=\(requestData.count) · retransferMissing=\(retransferMissing)")
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
        let totalUploads = jobs.count
        var completedUploads = 0
        var uploaded = 0
        var uploadedImages = 0
        var uploadedVideos = 0
        var uploadedOther = 0
        var alreadyInCloudImages = 0
        var alreadyInCloudVideos = 0
        var alreadyInCloudOther = 0
        var failed = 0
        progress?(Progress(completed: 0, total: totalUploads, filename: nil, failed: false))

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
                        sourceId: sourceId, connection: connection, targetRoot: targetRoot, runId: reply.runId, debug: debug)
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
                case let .success(path, filename):
                    let receipt = Receipt(server: connection.base.absoluteString, user: connection.user,
                        sourceId: sourceId.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: path)
                    do {
                        debug?("upload.complete.request.status=success")
                        receipts.append(receipt)
                        try save(receipts)
                        try await confirm(receipt, connection: connection)
                        receipts.removeAll { $0.uploadId == ticket.uploadId }
                        try save(receipts)
                        uploaded += 1
                        let mediaType = assets[outcome.job.index]["mediaType"] as? String
                        if mediaType == "image" { uploadedImages += 1 }
                        else if mediaType == "video" { uploadedVideos += 1 }
                        else { uploadedOther += 1 }
                        completedUploads += 1
                        progress?(Progress(completed: completedUploads, total: totalUploads, filename: filename, failed: false))
                    } catch {
                        failed += 1
                        completedUploads += 1
                        debug?("Upload completion failed · error=\(error.localizedDescription)")
                        progress?(Progress(completed: completedUploads, total: totalUploads, filename: filename, failed: true))
                    }
                case let .failed(filename, error):
                    do {
                        debug?("upload.complete.request.status=failed")
                        _ = try await post(["sourceId": sourceId.lowercased(), "runId": reply.runId,
                            "uploadId": ticket.uploadId, "status": "failed"], endpoint: "uploads/complete", connection: connection)
                    } catch { debug?("Upload failure acknowledgement failed · error=\(error.localizedDescription)") }
                    failed += 1
                    completedUploads += 1
                    debug?("Upload failed · error=\(error)")
                    progress?(Progress(completed: completedUploads, total: totalUploads, filename: filename, failed: true))
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
            alreadyInCloudImages: alreadyInCloudImages, alreadyInCloudVideos: alreadyInCloudVideos, alreadyInCloudOther: alreadyInCloudOther)
    }
}
