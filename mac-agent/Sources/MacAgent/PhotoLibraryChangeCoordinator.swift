import Foundation
import Photos

struct PhotoLibraryChangeState: Sendable, Equatable {
    var revision: UInt64 = 0
    var galleryIsStale = false
    var albumsAreStale = false
    var requiresFullRefresh = false
    var changedAssetIDs: Set<String> = []
    var removedAssetIDs: Set<String> = []

    static func applying(_ change: GalleryChangeResult, to previous: PhotoLibraryChangeState) -> PhotoLibraryChangeState {
        PhotoLibraryChangeState(revision: previous.revision &+ 1,
                                galleryIsStale: true,
                                albumsAreStale: true,
                                requiresFullRefresh: change.requiresFullRefresh,
                                changedAssetIDs: change.changedAssetIDs,
                                removedAssetIDs: change.removedAssetIDs)
    }
}

final class PhotoLibraryChangeCoordinator: NSObject, PHPhotoLibraryChangeObserver {
    private let library: any GalleryLibraryProviding
    private let onChange: @MainActor (GalleryChangeResult) -> Void

    init(library: any GalleryLibraryProviding,
         onChange: @escaping @MainActor (GalleryChangeResult) -> Void) {
        self.library = library
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let library = library
        let onChange = onChange
        Task { @MainActor in
            onChange(await library.apply(change: changeInstance))
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}
