import Foundation
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
