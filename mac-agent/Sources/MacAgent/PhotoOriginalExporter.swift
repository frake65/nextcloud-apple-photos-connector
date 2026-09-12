import Foundation
import Photos
import InventoryCore

/// Exports only the primary original resource. Live Photo companions and edits are out of scope.
protocol PhotoOriginalExporting: Sendable {
    func export(localIdentifier: String) async throws -> PhotoOriginalExporter.Export
}

actor PhotoOriginalExporter: PhotoOriginalExporting {
    struct Export: Sendable {
        let url: URL
        let filename: String
    }

    func export(localIdentifier: String) async throws -> Export {
        try await SettingsWorkGate.shared.checkpoint()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetched.firstObject else { throw ExportError.unavailable }
        let type: PHAssetResourceType
        switch asset.mediaType {
        case .image: type = .photo
        case .video: type = .video
        case .audio: type = .audio
        default: throw ExportError.unavailable
        }
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == type }) else {
            throw ExportError.unavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("original")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return Export(url: url, filename: resource.originalFilename)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    enum ExportError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Originalressource nicht verfügbar." }
    }
}
