import Foundation
import Combine
import Photos

enum PhotoAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    init(status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .restricted
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }
}

struct GalleryAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    var creationDate: Date { asset.creationDate ?? .distantPast }
}

struct GalleryAlbum: Identifiable {
    let collection: PHAssetCollection
    let count: Int
    let cover: PHAsset?
    var id: String { collection.localIdentifier }
    var title: String { collection.localizedTitle ?? "Album" }
}

@MainActor
final class AssetSelectionModel: ObservableObject {
    @Published private(set) var selected: [String: GalleryAsset] = [:]
    private var identifiers = AssetSelectionIDs()
    private var dragVisited = Set<String>()
    private var dragMode: DragMode?

    enum DragMode { case select, deselect }
    var dragIsActive: Bool { dragMode != nil }

    var assets: [GalleryAsset] { Array(selected.values).sorted { $0.id < $1.id } }
    var count: Int { selected.count }
    func contains(_ asset: GalleryAsset) -> Bool { selected[asset.id] != nil }

    func toggle(_ asset: GalleryAsset) {
        if identifiers.contains(asset.id) {
            identifiers.remove(asset.id)
            selected.removeValue(forKey: asset.id)
        } else {
            identifiers.insert(asset.id)
            selected[asset.id] = asset
        }
    }

    func clear() { identifiers.removeAll(); selected.removeAll() }

    func allSelected(in context: [GalleryAsset]) -> Bool {
        identifiers.allSelected(in: context.map(\.id))
    }

    func selectAll(in context: [GalleryAsset]) {
        identifiers.insertAll(context.map(\.id))
        for asset in context {
            selected[asset.id] = asset
        }
    }

    func deselectAll(in context: [GalleryAsset]) {
        identifiers.removeAll(context.map(\.id))
        for asset in context {
            selected.removeValue(forKey: asset.id)
        }
    }

    func beginDrag(at asset: GalleryAsset) {
        dragVisited.removeAll()
        dragMode = identifiers.contains(asset.id) ? .deselect : .select
        applyDrag(to: asset)
    }

    func applyDrag(to asset: GalleryAsset) {
        guard let dragMode, dragVisited.insert(asset.id).inserted else { return }
        switch dragMode {
        case .select:
            identifiers.insert(asset.id); selected[asset.id] = asset
        case .deselect:
            identifiers.remove(asset.id); selected.removeValue(forKey: asset.id)
        }
    }

    func endDrag() { dragVisited.removeAll(); dragMode = nil }
}

struct AssetSelectionIDs: Equatable {
    private(set) var values: Set<String> = []
    func contains(_ identifier: String) -> Bool { values.contains(identifier) }
    mutating func insert(_ identifier: String) { values.insert(identifier) }
    mutating func remove(_ identifier: String) { values.remove(identifier) }
    func allSelected(in identifiers: [String]) -> Bool { !identifiers.isEmpty && identifiers.allSatisfy(values.contains) }
    mutating func insertAll(_ identifiers: [String]) { values.formUnion(identifiers) }
    mutating func removeAll(_ identifiers: [String]) { values.subtract(identifiers) }
    mutating func removeAll() { values.removeAll() }
}

enum GalleryAutoScroll {
    static func velocity(fingerY: CGFloat, viewportHeight: CGFloat, zone: CGFloat = 70) -> CGFloat? {
        guard viewportHeight > 0, zone > 0 else { return nil }
        if fingerY < zone {
            let factor = min(1, max(0, (zone - max(0, fingerY)) / zone))
            return -350 * pow(factor, 1.5)
        }
        if fingerY > viewportHeight - zone {
            let factor = min(1, max(0, (zone - max(0, viewportHeight - fingerY)) / zone))
            return 350 * pow(factor, 1.5)
        }
        return nil
    }
}
