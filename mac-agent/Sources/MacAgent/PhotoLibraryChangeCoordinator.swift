import Foundation
import Photos

struct PhotoLibraryChangeState: Sendable, Equatable {
    var revision: UInt64 = 0
    var galleryIsStale = false
    var albumsAreStale = false
    var requiresFullRefresh = false
    var changedAssetIDs: Set<String> = []
    var removedAssetIDs: Set<String> = []
    var albumRevision: UInt64 = 0
    var insertedAlbumIDs: Set<String> = []
    var removedAlbumIDs: Set<String> = []
    var changedAlbumIDs: Set<String> = []

    static func applying(_ change: GalleryChangeResult, to previous: PhotoLibraryChangeState) -> PhotoLibraryChangeState {
        PhotoLibraryChangeState(revision: previous.revision &+ 1,
                                galleryIsStale: true,
                                albumsAreStale: true,
                                requiresFullRefresh: change.requiresFullRefresh,
                                changedAssetIDs: change.changedAssetIDs,
                                removedAssetIDs: change.removedAssetIDs)
    }

    static func applying(_ change: GalleryChangeResult, album: AlbumChangeDelta, to previous: PhotoLibraryChangeState) -> PhotoLibraryChangeState {
        var state = applying(change, to: previous)
        state.albumRevision = previous.albumRevision &+ 1
        state.insertedAlbumIDs = album.insertedAlbumIDs
        state.removedAlbumIDs = album.removedAlbumIDs
        state.changedAlbumIDs = album.changedAlbumIDs
        return state
    }
}

final class PhotoLibraryChangeCoordinator: NSObject, PHPhotoLibraryChangeObserver {
    private let library: any GalleryLibraryProviding
    private let onChange: @MainActor (GalleryChangeResult, AlbumChangeDelta) -> Void

    init(library: any GalleryLibraryProviding,
         onChange: @escaping @MainActor (GalleryChangeResult, AlbumChangeDelta) -> Void) {
        self.library = library
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let library = library
        let onChange = onChange
        Task { @MainActor in
            let gallery = await library.apply(change: changeInstance)
            let albums = await library.applyAlbumChange(change: changeInstance)
            onChange(gallery, albums)
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}
