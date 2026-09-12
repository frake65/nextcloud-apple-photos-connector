import AppKit
import Photos
import InventoryCore

/// The PhotoKit-produced image is handed to the UI without mutation. Only the
/// MainActor reads/draws it; this box is the narrow callback transfer boundary.
final class GalleryImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

protocol GalleryThumbnailProviding: Sendable {
    func image(local: String) async throws -> GalleryImage?
}

/// One request's callback/cancellation race, including cancellation before
/// PhotoKit returns its ID. The continuation is consumed exactly once.
final class PhotoKitImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GalleryImage?, Error>?
    private var finished = false
    private var cancelled = false
    private var requestID: PHImageRequestID?
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void

    init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void) { self.cancelRequest = cancelRequest }
    func install(_ continuation: CheckedContinuation<GalleryImage?, Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func setID(_ id: PHImageRequestID) {
        let shouldCancel = lock.withLock { requestID = id; return cancelled }
        if shouldCancel { cancelRequest(id) }
    }
    func complete(_ value: GalleryImage?) {
        let callback = lock.withLock {
            guard !finished else { return Optional<CheckedContinuation<GalleryImage?, Error>>.none }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        callback?.resume(returning: value)
    }
    func cancel() {
        let (callback, id) = lock.withLock {
            cancelled = true
            finished = true
            defer { continuation = nil }
            return (continuation, requestID)
        }
        if let id { cancelRequest(id) }
        callback?.resume(throwing: CancellationError())
    }
}

actor PhotoKitGalleryThumbnails: GalleryThumbnailProviding {
    private let manager = PHCachingImageManager()
    private let gate: SettingsWorkGate
    init(gate: SettingsWorkGate = .shared) { self.gate = gate }

    func image(local: String) async throws -> GalleryImage? {
        try await gate.checkpoint()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject else { return nil }
        let request = PhotoKitImageRequest { [manager] id in manager.cancelImageRequest(id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .fastFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                request.setID(manager.requestImage(for: asset, targetSize: CGSize(width: 180, height: 180), contentMode: .aspectFill, options: options) { image, _ in
                    request.complete(image.map(GalleryImage.init))
                })
            }
        } onCancel: { request.cancel() }
    }
}

/// Only visible cell tasks enqueue work. At most eight workers can be admitted;
/// disappearing cells leave the queue or cancel their active PhotoKit request.
@MainActor
final class GalleryThumbnailLoader {
    private struct Job {
        let id: UUID
        let local: String
        let continuation: CheckedContinuation<GalleryImage?, Error>
    }
    private let provider: any GalleryThumbnailProviding
    private let gate: SettingsWorkGate
    private let limit: Int
    private var queue: [Job] = []
    private var active: [UUID: Task<Void, Never>] = [:]
    private var continuations: [UUID: CheckedContinuation<GalleryImage?, Error>] = [:]
    private let cache = NSCache<NSString, GalleryImage>()
    private var cacheGeneration = UUID()
    var activeCount: Int { active.count }
    var queuedCount: Int { queue.count }

    init(provider: any GalleryThumbnailProviding = PhotoKitGalleryThumbnails(), gate: SettingsWorkGate = .shared, limit: Int = 8) {
        self.provider = provider; self.gate = gate; self.limit = max(1, limit)
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func clearCache() { cacheGeneration = UUID(); cache.removeAllObjects() }

    func image(local: String) async throws -> GalleryImage? {
        try Task.checkCancellation()
        if let cached = cache.object(forKey: local as NSString) { return cached }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Job(id: id, local: local, continuation: continuation))
                pump()
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            active[id]?.cancel()
            continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
        GalleryDebug.log("gallery.thumbnail.cancelled active=\(active.count)")
    }

    private func pump() {
        while active.count < limit, !queue.isEmpty {
            let job = queue.removeFirst()
            let generation = cacheGeneration
            continuations[job.id] = job.continuation
            active[job.id] = Task {
                do {
                    try await gate.checkpoint()
                    GalleryDebug.log("gallery.thumbnail.start active=\(active.count)")
                    let value = try await provider.image(local: job.local)
                    try Task.checkCancellation()
                    if let value, generation == cacheGeneration { cache.setObject(value, forKey: job.local as NSString, cost: 180 * 180 * 4) }
                    continuations.removeValue(forKey: job.id)?.resume(returning: value)
                } catch {
                    continuations.removeValue(forKey: job.id)?.resume(throwing: error)
                }
                active.removeValue(forKey: job.id)
                GalleryDebug.log("gallery.thumbnail.complete active=\(active.count)")
                pump()
            }
        }
    }
}
