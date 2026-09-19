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
    @Published private(set) var failure: String?
    private var task: Task<Void, Never>?

    func cancel() { phase = .cancelled; task?.cancel() }

    func start(selection: [GalleryAsset], library: PhotoLibraryModel, connection: ConnectorConnection, source: PhotoSource, transport: any DAVTransport = NetworkTransport()) {
        IOSImportDiagnostics.announceIfEnabled()
        cancel(); phase = .inventory; failure = nil; completed = 0; uploaded = 0; alreadyPresent = 0; reconciled = 0; total = selection.count
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let uploader = WebDAVUploader(connection: connection, transport: transport, debug: { message in IOSImportDiagnostics.log(message) })
                let inventoryPhase = IOSImportDiagnostics.start("asset-inventory-build")
                let assets: [AssetInventory]
                do { assets = try library.inventory(for: selection); IOSImportDiagnostics.finish("asset-inventory-build", started: inventoryPhase, detail: "assets=\(assets.count)") }
                catch { IOSImportDiagnostics.failure("asset-inventory-build", started: inventoryPhase, error: error); throw error }
                let reply = try await InventoryCheckClient.check(connection: connection, source: source, assets: assets, transport: transport)
                for (index, selected) in selection.enumerated() {
                    try Task.checkCancellation()
                    guard reply.assets.indices.contains(index) else { throw InventoryCheckError.invalidResponse }
                    let entry = reply.assets[index]
                    await self.setCurrent(selected.asset, filename: assets[index].filename)
                    if entry.state == .known { await self.markAlready(); continue }
                    guard let ticket = entry.upload else { throw InventoryCheckError.invalidResponse }
                    await self.setPhase(.exporting)
                    let exportPhase = IOSImportDiagnostics.start("photo-original-export")
                    let exported: PhotoLibraryModel.ExportedOriginal
                    do { exported = try await library.exportOriginal(for: selected) { [weak self] value in Task { @MainActor in self?.setProgress(value) } }; IOSImportDiagnostics.finish("photo-original-export", started: exportPhase, detail: "bytes=pending") }
                    catch { IOSImportDiagnostics.failure("photo-original-export", started: exportPhase, error: error); throw error }
                    defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
                    await self.setPhase(.hashing)
                    let hashPhase = IOSImportDiagnostics.start("sha256")
                    let identity: ContentIdentity
                    do { identity = try await Task.detached { try ContentIdentity.read(exported.url) }.value; IOSImportDiagnostics.finish("sha256", started: hashPhase, detail: "bytes=\(identity.bytes)") }
                    catch { IOSImportDiagnostics.failure("sha256", started: hashPhase, error: error); throw error }
                    let calendar = Calendar(identifier: .gregorian)
                    let date = selected.creationDate
                    let folder = "Photos/Apple Photos Connector/\(calendar.component(.year, from: date))/\(String(format: "%02d", calendar.component(.month, from: date)))"
                    let provider = IOSUploadTargets(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, folder: folder)
                    await self.setPhase(.preparing)
                    await self.setPhase(.uploading)
                    let putPhase = IOSImportDiagnostics.start("webdav-transfer")
                    let target: UploadTarget
                    do { target = try await uploader.uploadWithTarget(file: exported.url, filename: exported.filename, assetId: ticket.assetId, captureDate: date, targets: provider, targetRoot: "Photos/Apple Photos Connector"); IOSImportDiagnostics.finish("webdav-transfer", started: putPhase, detail: "bytes=\(identity.bytes)") }
                    catch { IOSImportDiagnostics.failure("webdav-transfer", started: putPhase, error: error); throw error }
                    if target.state == "contentAlreadyPresent" { await self.markReconciled() }
                    else if target.state == "missing" { await self.markUploaded() }
                    else { await self.markUploaded() }
                    if target.state != "contentAlreadyPresent" {
                        await self.setPhase(.completing)
                        try await IOSUploadHTTP.complete(connection: connection, transport: transport, source: source.sourceId.uuidString.lowercased(), runId: reply.runId, uploadId: ticket.uploadId, path: target.path)
                    }
                }
                await self.setPhase(.completing)
                let albumBuild = IOSImportDiagnostics.start("album-inventory-build")
                let albums: [AlbumInventory]
                do { albums = try library.albumInventory(); IOSImportDiagnostics.finish("album-inventory-build", started: albumBuild, detail: "albums=\(albums.count) memberships=\(albums.reduce(0) { $0 + $1.assetIdentities.count })") }
                catch { IOSImportDiagnostics.failure("album-inventory-build", started: albumBuild, error: error); throw error }
                try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: albums, selectedAssets: assets, transport: transport)
                await self.finish()
            } catch is CancellationError { await self.cancelled() }
            catch { await self.failed(error.localizedDescription) }
        }
    }

    private func setCurrent(_ asset: PHAsset, filename: String?) { currentFilename = filename ?? asset.localIdentifier }
    private func setProgress(_ _: Double) {}
    private func setPhase(_ value: Phase) { phase = value }
    private func markAlready() { alreadyPresent += 1; completed += 1 }
    private func markUploaded() { uploaded += 1; completed += 1 }
    private func markReconciled() { reconciled += 1; alreadyPresent += 1; completed += 1 }
    private func finish() { phase = .finished }
    private func cancelled() { phase = .cancelled }
    private func failed(_ message: String) { failure = message; phase = .failed }
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
        do { response = try await transport.send(request, file: nil); IOSImportDiagnostics.finish("uploads/complete", started: phase, detail: "status=\(response.status)") }
        catch { IOSImportDiagnostics.failure("uploads/complete", started: phase, error: error); throw error }
        guard (200..<300).contains(response.status) else { throw UploadError.http(response.status) }
    }
}
