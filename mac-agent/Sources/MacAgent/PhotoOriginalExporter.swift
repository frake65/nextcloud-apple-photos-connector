import Foundation
import Photos
import InventoryCore
import MacAgentSupport

private final class PhotoResourceRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var isCancelled = false

    func register(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }
}

private final class PhotoResourceFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var writeError: (any Error)?

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard writeError == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            writeError = error
        }
    }

    func finish() throws {
        lock.lock()
        let handle = handle
        self.handle = nil
        let writeError = writeError
        lock.unlock()
        try handle?.close()
        if let writeError { throw writeError }
    }
}

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
            let sink = try PhotoResourceFileSink(url: url)
            let cancellation = PhotoResourceRequestCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let requestID = PHAssetResourceManager.default().requestData(
                        for: resource,
                        options: options,
                        dataReceivedHandler: { sink.append($0) },
                        completionHandler: { error in
                            do {
                                try sink.finish()
                                if let error { throw error }
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    )
                    cancellation.register(requestID)
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            return Export(url: url, filename: resource.originalFilename, resourceType: Self.resourceTypeName(resource.type))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
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
