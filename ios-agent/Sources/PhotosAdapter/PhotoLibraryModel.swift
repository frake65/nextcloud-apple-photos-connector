import Foundation
import Combine
import Photos
import UIKit

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var authorization: PhotoAuthorizationState
    @Published private(set) var assets: [GalleryAsset] = []
    @Published private(set) var albums: [GalleryAlbum] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let imageManager = PHCachingImageManager()
    private var refreshTask: Task<Void, Never>?

    init() {
        authorization = PhotoAuthorizationState(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() {
        guard authorization == .notDetermined else { refreshAuthorizationAndLoad(); return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = PhotoAuthorizationState(status: status)
                if self.authorization.canRead { self.loadLibrary() }
            }
        }
    }

    func refreshAuthorizationAndLoad() {
        authorization = PhotoAuthorizationState(status: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if authorization.canRead { loadLibrary() }
        else { assets = []; albums = [] }
    }

    func loadLibrary() {
        guard authorization.canRead else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            self.errorMessage = nil
            defer { self.isLoading = false }
            let fetched = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [GalleryAlbum]) in
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                var all: [PHAsset] = []
                result.enumerateObjects { asset, _, _ in
                    if asset.mediaType == .image || asset.mediaType == .video { all.append(asset) }
                }
                let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
                var albums: [GalleryAlbum] = []
                collections.enumerateObjects { collection, _, _ in
                    let albumOptions = PHFetchOptions()
                    albumOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    let members = PHAsset.fetchAssets(in: collection, options: albumOptions)
                    let count = members.countOfAssets(with: .image) + members.countOfAssets(with: .video)
                    guard count > 0 else { return }
                    albums.append(GalleryAlbum(collection: collection, count: count, cover: members.firstObject))
                }
                return (all, albums.sorted { ($0.collection.localizedTitle ?? "") < ($1.collection.localizedTitle ?? "") })
            }.value
            guard !Task.isCancelled else { return }
            self.assets = fetched.0.map(GalleryAsset.init).sorted { $0.creationDate > $1.creationDate }
            self.albums = fetched.1
        }
    }

    func assets(in album: GalleryAlbum) -> [GalleryAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album.collection, options: options)
        var assets: [GalleryAsset] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(GalleryAsset(asset: asset))
        }
        return assets.sorted { $0.creationDate > $1.creationDate }
    }

    func requestThumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in completion(image) }
    }

    func cancelThumbnail(_ requestID: PHImageRequestID) { imageManager.cancelImageRequest(requestID) }
}
