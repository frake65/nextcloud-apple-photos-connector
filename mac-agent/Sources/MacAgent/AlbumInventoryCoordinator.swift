import Foundation
import InventoryCore

actor AlbumInventoryCoordinator {
    struct SyncResult: Sendable { let albumsCreated: Int; let albumsReused: Int; let foldersSkipped: Int; let membershipsCreated: Int; let membershipsReused: Int; let membershipsSkippedNotImported: Int }
    struct Reply: Decodable { let count: Int?; let albums: [Int]? }
    struct SyncReply: Decodable { let status: String; let summary: Summary }
    struct Summary: Decodable { let albumsCreated: Int; let albumsReused: Int; let foldersSkipped: Int; let membershipsCreated: Int; let membershipsReused: Int; let membershipsSkippedNotImported: Int; let errors: [SyncError] }
    struct SyncError: Decodable { let type: String?; let message: String? }
    static func shouldSyncAfterUpload(selectedAlbumIDs: Set<String>, selectedAssetIDs: Set<String>) -> Bool {
        !selectedAlbumIDs.isEmpty || !selectedAssetIDs.isEmpty
    }
    static func interpret(status: Int, reply: SyncReply) throws -> SyncResult {
        guard status == 200 else {
            throw AlbumOperationFailure(stage: .sync, technicalDetail: "stage=album.sync HTTP \(status)")
        }
        guard reply.status == "completed", reply.summary.errors.isEmpty else {
            throw AlbumOperationFailure(stage: .sync, technicalDetail: "stage=album.sync status=\(reply.status) errors=\(reply.summary.errors.count)")
        }
        let s = reply.summary
        return SyncResult(albumsCreated: s.albumsCreated, albumsReused: s.albumsReused, foldersSkipped: s.foldersSkipped, membershipsCreated: s.membershipsCreated, membershipsReused: s.membershipsReused, membershipsSkippedNotImported: s.membershipsSkippedNotImported)
    }
    private let transport: any DAVTransport = NetworkTransport()
    func run(scanner: PhotoLibraryScanner, connection: ConnectorConnection) async throws -> String {
        try Task.checkCancellation()
        try await SettingsWorkGate.shared.checkpoint()
        let document: AlbumInventoryDocument
        do { document = try await scanner.scanAlbums() }
        catch is CancellationError { throw CancellationError() }
        catch { throw UploadError.diagnostic("PhotoKit-Albumscan fehlgeschlagen: \(error)") }
        GalleryDebug.log("album.inventory.scan source=\(document.source.sourceId.uuidString.lowercased()) albums=\(document.albums.count) memberships=\(document.albums.reduce(0) { $0 + $1.assetIdentities.count })")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
            _ = try JSONDecoder().decode(AlbumInventoryDocument.self, from: data)
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("apple-photos-album-inventory.json"), options: .atomic)
        } catch { throw UploadError.invalidResponse }
        var request = connection.request(path: ["index.php","apps","apple_photos_connector","api","v1","albums","inventory"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = data
        let response = try await transport.send(request, file: nil)
        GalleryDebug.log("album.inventory.response source=\(document.source.sourceId.uuidString.lowercased()) status=\(response.status) albums=\(document.albums.count)")
        try Task.checkCancellation()
        print("Album response HTTP \(response.status), headers=\(response.headers), bytes=\(response.data.count)")
        if let body = String(data: response.data, encoding: .utf8) { print("Album response body UTF-8: \(body)") } else { print("Album response body hex: \(response.data.prefix(128).map { String(format: "%02x", $0) }.joined())") }
        guard response.status == 200 else {
            let body = String(data: response.data, encoding: .utf8) ?? response.data.prefix(128).map { String(format: "%02x", $0) }.joined()
            throw UploadError.diagnostic("Album-POST HTTP \(response.status), Content-Type: \(response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "unbekannt"), Body: \(body)")
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: response.data) }
        catch let error as DecodingError { print("Album response decoding error: \(error)"); throw UploadError.diagnostic("Album-Response DecodingError: \(error)") }
        catch { print("Album response decode error: \(error)"); throw UploadError.diagnostic("Album-Response Decode-Fehler: \(error)") }
        let cloud = document.albums.filter { $0.cloudIdentifier != nil }.count
        let parents = document.albums.filter { $0.parentLocalIdentifier != nil }.count
        let memberships = document.albums.reduce(0) { $0 + $1.assetIdentities.count }
        return "Album-Inventar: \(document.albums.count) Collections, \(cloud) mit Cloud-Identifier, \(document.albums.count - cloud) ohne, \(parents) Parent-Beziehungen, \(memberships) Memberships; Server: \(reply.count ?? document.albums.count) gespeichert."
    }
    func sync(scanner: PhotoLibraryScanner, connection: ConnectorConnection, selectedAlbumIDs: Set<String> = [], selectedAssetIDs: Set<String> = []) async throws -> SyncResult {
        try Task.checkCancellation()
        try await SettingsWorkGate.shared.checkpoint()
        let sourceId = try await scanner.currentSourceId().uuidString.lowercased()
        GalleryDebug.log("album.sync.request source=\(sourceId) selectedAlbums=\(selectedAlbumIDs.count) selectedAssets=\(selectedAssetIDs.count)")
        let body = try JSONSerialization.data(withJSONObject: [
            "sourceId": sourceId,
            "selectedAlbumIDs": Array(selectedAlbumIDs).sorted(),
            "selectedAssetIDs": Array(selectedAssetIDs).sorted()
        ])
        var request = connection.request(path: ["index.php","apps","apple_photos_connector","api","v1","albums","sync"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        let response = try await transport.send(request, file: nil)
        GalleryDebug.log("album.sync.response source=\(sourceId) status=\(response.status)")
        try Task.checkCancellation()
        guard response.status == 200 else { throw AlbumOperationFailure(stage: .sync, technicalDetail: "stage=album.sync HTTP \(response.status)") }
        let decoded: SyncReply
        do { decoded = try JSONDecoder().decode(SyncReply.self, from: response.data) }
        catch { throw AlbumOperationFailure.capture(error, stage: .sync) }
        let s=decoded.summary
        let errorTypes = Set(s.errors.compactMap(\.type).filter { $0 == "album" || $0 == "membership" }).sorted().joined(separator: ",")
        GalleryDebug.log("album.sync.summary source=\(sourceId) albumsCreated=\(s.albumsCreated) albumsReused=\(s.albumsReused) membershipsCreated=\(s.membershipsCreated) membershipsReused=\(s.membershipsReused) skippedNotImported=\(s.membershipsSkippedNotImported) errors=\(s.errors.count) errorTypes=\(errorTypes)", category: s.errors.isEmpty ? "album" : "warning")
        do { return try Self.interpret(status: response.status, reply: decoded) }
        catch let failure as AlbumOperationFailure { throw failure }
        catch { throw AlbumOperationFailure.capture(error, stage: .sync) }
    }
}
