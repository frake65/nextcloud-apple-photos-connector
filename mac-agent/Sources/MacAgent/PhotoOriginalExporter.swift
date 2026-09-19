import Foundation
import Photos
import InventoryCore
import MacAgentSupport

/// Exports only the primary original resource. Live Photo companions and edits are out of scope.
protocol PhotoOriginalExporting: Sendable {
    func export(localIdentifier: String) async throws -> PhotoOriginalExporter.Export
}

actor PhotoOriginalExporter: PhotoOriginalExporting {
    struct Export: Sendable {
        let url: URL
        let filename: String
        let resourceType: String

        init(url: URL, filename: String, resourceType: String = "unknown") {
            self.url = url
            self.filename = filename
            self.resourceType = resourceType
        }
    }

    func export(localIdentifier: String) async throws -> Export {
        try await export(localIdentifier: localIdentifier, progress: nil)
    }

    func export(localIdentifier: String, progress: (@Sendable (Double) -> Void)?) async throws -> Export {
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
        options.progressHandler = progress
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return Export(url: url, filename: resource.originalFilename, resourceType: Self.resourceTypeName(resource.type))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func resourceTypeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        default: String(describing: type)
        }
    }

    enum ExportError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Originalressource nicht verfügbar." }
    }
}
