import XCTest
import AppKit
@testable import MacAgent
@testable import InventoryCore

private actor SimulatedGallery: GalleryLibraryProviding {
    let count: Int
    let gate: SettingsWorkGate
    private(set) var opens = 0
    private(set) var cells: [Int] = []
    private(set) var allRequests = 0
    private(set) var selectionRequests = 0
    private(set) var catalogRequests = 0
    init(count: Int = 100_000, gate: SettingsWorkGate = SettingsWorkGate()) {
        self.count = count; self.gate = gate
    }
    func open() async throws -> Int { try await gate.checkpoint(); opens += 1; return count }
    func cell(at index: Int) async throws -> GalleryAsset {
        try await gate.checkpoint()
        cells.append(index)
        return GalleryAsset(localIdentifier: "local-\(index)", isVideo: false, duration: 0, identity: "cloud:\(index)")
    }
    func resolveAll() async throws -> GallerySelection {
        try await gate.checkpoint(); allRequests += 1
        return GallerySelection(identities: Set((0..<count).map { "cloud:\($0)" }), photos: count)
    }
    func resolveSelection(_ identities: Set<String>) async throws -> GallerySelection {
        try await gate.checkpoint(); selectionRequests += 1
        let resolved = Set(identities.map { $0.hasPrefix("local:local-") ? "cloud:\($0.dropFirst(12))" : $0 })
        return GallerySelection(identities: resolved, photos: resolved.count)
    }
    func albumCatalog() async throws -> [GalleryAlbum] {
        try await gate.checkpoint(); catalogRequests += 1
        return [GalleryAlbum(inventory: AlbumInventory(localIdentifier: "album", cloudIdentifier: "album-cloud", name: "Test"), photos: 2, videos: 0, cover: "local-1")]
    }
    func albumAssets(_ local: String) async throws -> GallerySelection {
        try await gate.checkpoint()
        return GallerySelection(identities: ["cloud:1", "cloud:99999"], photos: 2)
    }
    func asset(local: String) async throws -> GalleryAsset? { try await cell(at: 1) }
}

private actor ControlledThumbnails: GalleryThumbnailProviding {
    private var pending: [String: CheckedContinuation<GalleryImage?, Error>] = [:]
    private(set) var starts: [String] = []
    private(set) var cancellations: [String] = []
    let cooperative: Bool
    init(cooperative: Bool = true) { self.cooperative = cooperative }
    func image(local: String, targetSize: CGSize) async throws -> GalleryImage? {
        try Task.checkCancellation()
        starts.append(local)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[local] = $0 }
        } onCancel: { Task { await self.cancel(local) } }
    }
    private func cancel(_ local: String) {
        cancellations.append(local)
        if cooperative { pending.removeValue(forKey: local)?.resume(throwing: CancellationError()) }
    }
    func finish(_ local: String, value: GalleryImage? = nil) { pending.removeValue(forKey: local)?.resume(returning: value) }
}

@MainActor
final class GalleryLoadingTests: XCTestCase {
    private final class CancelledIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int32] = []
        func append(_ id: Int32) { lock.withLock { ids.append(id) } }
        var values: [Int32] { lock.withLock { ids } }
    }
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    func testLargeInitialLoadDoesNotResolveAssetsAlbumsOrRequestThumbnails() async throws {
        let source = SimulatedGallery()
        let provider = ControlledThumbnails()
        let model = VisualLibraryModel(library: source, thumbnails: GalleryThumbnailLoader(provider: provider))
        try await model.openSource(persisted: PhotoSelectionState())
        XCTAssertEqual(model.assetCount, 100_000)
        let cells = await source.cells
        let all = await source.allRequests
        let selection = await source.selectionRequests
        let albums = await source.catalogRequests
        let images = await provider.starts
        XCTAssertTrue(cells.isEmpty)
        XCTAssertEqual(all, 0); XCTAssertEqual(selection, 0); XCTAssertEqual(albums, 0)
        XCTAssertTrue(images.isEmpty)
    }

    func testPartialCellsNeverRemovePersistedSelectionAndSnapshotIncludesOffscreen() async throws {
        let source = SimulatedGallery()
        let model = VisualLibraryModel(library: source)
        let persisted = PhotoSelectionState(manuallySelectedAssetIDs: ["cloud:1", "cloud:99999", "cloud:unavailable"])
        try await model.openSource(persisted: persisted)
        await eventually { !model.selectionBusy }
        _ = try await source.cell(at: 1)
        _ = try await source.cell(at: 50000)
        _ = try await source.cell(at: 1)
        XCTAssertEqual(model.uploadSnapshot(), persisted.assetIdentities)
        XCTAssertEqual(model.selectedPhotos, 3)
        let all = await source.allRequests
        XCTAssertEqual(all, 0)
    }

    func testSelectionSurvivesCellReleaseReturnAndExplicitSelectAllUsesWholeSource() async throws {
        let source = SimulatedGallery()
        let model = VisualLibraryModel(library: source)
        try await model.openSource(persisted: PhotoSelectionState())
        model.toggleAsset(try await source.cell(at: 99999))
        await eventually { !model.selectionBusy }
        _ = try await source.cell(at: 1)
        let returning = try await source.cell(at: 99999)
        XCTAssertTrue(model.uploadSnapshot().contains(returning.identity))
        model.selectAll()
        await eventually { !model.selectionBusy }
        XCTAssertEqual(model.uploadSnapshot().count, 100_000)
        XCTAssertEqual(model.selectedPhotos, 100_000)
        XCTAssertTrue(model.uploadSnapshot().contains("cloud:99999"))
        XCTAssertTrue(model.selectedAlbums.isEmpty)
        model.clearSelection()
        XCTAssertTrue(model.uploadSnapshot().isEmpty)
    }

    func testSelectAllPreservesExplicitAlbumSelection() async throws {
        let source = SimulatedGallery()
        let model = VisualLibraryModel(library: source)
        try await model.openSource(persisted: PhotoSelectionState(selectedAlbumIDs: ["cloud:album-cloud"]))
        await eventually { !model.selectionBusy }
        XCTAssertEqual(model.selectedAlbumIDs, ["cloud:album-cloud"])
        model.selectAll()
        await eventually { !model.selectionBusy }
        XCTAssertEqual(model.selectedAlbumIDs, ["cloud:album-cloud"])
        XCTAssertEqual(model.uploadSnapshot().count, 100_000)
    }

    func testPersistedAlbumRestoresOffscreenMembersWithoutEnumeratingGallery() async throws {
        let source = SimulatedGallery()
        let model = VisualLibraryModel(library: source)
        try await model.openSource(persisted: PhotoSelectionState(selectedAlbumIDs: ["cloud:album-cloud"]))
        await eventually { !model.selectionBusy }
        XCTAssertEqual(model.uploadSnapshot(), ["cloud:1", "cloud:99999"])
        XCTAssertEqual(model.selectedMembershipCount, 2)
        model.toggleAlbum(model.selectedAlbums[0])
        await eventually { !model.selectionBusy }
        XCTAssertTrue(model.uploadSnapshot().isEmpty)
        let cells = await source.cells
        XCTAssertTrue(cells.isEmpty)
    }

    func testVisibilityRequestsAreBoundedCancelledAndCanReturn() async throws {
        let provider = ControlledThumbnails()
        let loader = GalleryThumbnailLoader(provider: provider, limit: 2)
        let a = Task { try await loader.image(local: "a") }
        let b = Task { try await loader.image(local: "b") }
        await eventually { await provider.starts.count == 2 }
        let c = Task { try await loader.image(local: "c") }
        await eventually { loader.queuedCount == 1 }
        XCTAssertEqual(loader.activeCount, 2)
        a.cancel()
        await eventually { await provider.starts.contains("c") }
        let cancellations = await provider.cancellations
        XCTAssertTrue(cancellations.contains("a"))
        await provider.finish("b"); await provider.finish("c")
        _ = try await b.value; _ = try await c.value
        do { _ = try await a.value; XCTFail("Cancelled cell returned") } catch is CancellationError { }
        let returned = Task { try await loader.image(local: "a") }
        await eventually { await provider.starts.filter { $0 == "a" }.count == 2 }
        await provider.finish("a")
        _ = try await returned.value
        await eventually { loader.activeCount == 0 }
    }

    func testLateCompletionAfterCancellationCannotDeliverOrCacheWrongImage() async throws {
        let provider = ControlledThumbnails(cooperative: false)
        let loader = GalleryThumbnailLoader(provider: provider, limit: 1)
        let old = Task { try await loader.image(local: "old") }
        await eventually { await provider.starts.count == 1 }
        old.cancel()
        do { _ = try await old.value; XCTFail("Cancelled request returned") } catch is CancellationError { }
        await provider.finish("old", value: GalleryImage(NSImage(size: NSSize(width: 180, height: 180))))
        await eventually { loader.activeCount == 0 }
        let retry = Task { try await loader.image(local: "old") }
        await eventually { await provider.starts.count == 2 }
        await provider.finish("old")
        _ = try await retry.value
    }

    func testCompletedImageIsReusedWithoutAnotherRequest() async throws {
        let provider = ControlledThumbnails()
        let loader = GalleryThumbnailLoader(provider: provider)
        let first = Task { try await loader.image(local: "a") }
        await eventually { await provider.starts.count == 1 }
        let image = GalleryImage(NSImage(size: NSSize(width: 180, height: 180)))
        await provider.finish("a", value: image)
        let initial = try await first.value
        XCTAssertTrue(initial === image)
        let cached = try await loader.image(local: "a")
        XCTAssertTrue(cached === image)
        let starts = await provider.starts
        XCTAssertEqual(starts, ["a"])
    }

    func testSettingsPauseHoldsThumbnailWorkAndDropsInvisibleQueuedCells() async throws {
        let gate = SettingsWorkGate()
        gate.setPaused(true)
        let provider = ControlledThumbnails()
        let loader = GalleryThumbnailLoader(provider: provider, gate: gate, limit: 1)
        let visible = Task { try await loader.image(local: "visible") }
        await eventually { loader.activeCount == 1 }
        let gone = Task { try await loader.image(local: "gone") }
        await eventually { loader.queuedCount == 1 }
        gone.cancel()
        do { _ = try await gone.value; XCTFail("Cancelled queue item returned") } catch is CancellationError { }
        let before = await provider.starts
        XCTAssertTrue(before.isEmpty)
        gate.setPaused(false)
        await eventually { await provider.starts == ["visible"] }
        await provider.finish("visible")
        _ = try await visible.value
        gate.setPaused(true); gate.setPaused(false)
        let after = await provider.starts
        XCTAssertEqual(after, ["visible"])
    }

    func testSettingsPauseHoldsSelectionResolutionThenResumesOnce() async throws {
        let gate = SettingsWorkGate()
        let source = SimulatedGallery(gate: gate)
        let model = VisualLibraryModel(library: source, gate: gate)
        try await model.openSource(persisted: PhotoSelectionState())
        gate.setPaused(true)
        model.selectAll()
        model.selectAll()
        await Task.yield()
        let before = await source.allRequests
        XCTAssertEqual(before, 0)
        XCTAssertTrue(model.uploadSnapshot().isEmpty)
        gate.setPaused(false)
        await eventually { !model.selectionBusy }
        let after = await source.allRequests
        XCTAssertEqual(after, 1)
        XCTAssertEqual(model.uploadSnapshot().count, 100_000)
    }

    func testPhotoKitCallbackBridgeCancelsLateHandleAndIgnoresDuplicateCallback() async throws {
        let ids = CancelledIDs()
        let request = PhotoKitImageRequest { ids.append($0) }
        let task = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GalleryImage?, Error>) in
                XCTAssertTrue(request.install(continuation))
                request.cancel()
                request.setID(42)
                request.update(nil, isDegraded: false)
                request.update(nil, isDegraded: false)
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled callback returned") } catch is CancellationError { }
        XCTAssertEqual(ids.values, [42])

        let completed = PhotoKitImageRequest { _ in XCTFail("Completed request was cancelled") }
        let image: GalleryImage? = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(completed.install(continuation))
            completed.setID(43)
            completed.update(nil, isDegraded: false)
            completed.update(nil, isDegraded: false)
        }
        XCTAssertNil(image)
    }

    func testUploadResolutionUsesFrozenMembershipAndPromotesLocalFallback() async throws {
        let source = SimulatedGallery()
        let model = VisualLibraryModel(library: source)
        model.restore(PhotoSelectionState(manuallySelectedAssetIDs: ["local:local-99999", "cloud:1"]))
        let frozen = model.uploadSnapshot()
        model.clearSelection()
        let resolved = try await model.resolveUploadSnapshot(frozen)
        XCTAssertEqual(resolved, ["cloud:99999", "cloud:1"])
        XCTAssertTrue(model.uploadSnapshot().isEmpty)
    }

    func testPhotoKitCallbackBridgeCancelledBeforeInstallation() async throws {
        let request = PhotoKitImageRequest { _ in XCTFail("No request should start") }
        request.cancel()
        do {
            let _: GalleryImage? = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(request.install(continuation))
            }
            XCTFail("Pre-cancelled request returned")
        } catch is CancellationError { }
    }

    func testThumbnailPixelTargetUsesDisplayScale() {
        XCTAssertEqual(GalleryThumbnailSizing.pixelTargetSize(points: CGSize(width: 98, height: 92), scale: 1), CGSize(width: 98, height: 92))
        XCTAssertEqual(GalleryThumbnailSizing.pixelTargetSize(points: CGSize(width: 98, height: 92), scale: 2), CGSize(width: 196, height: 184))
    }

    func testAlbumRequestsDuringPauseAreCoalescedWithoutLoadingMembers() async throws {
        let gate = SettingsWorkGate()
        let source = SimulatedGallery(gate: gate)
        let model = VisualLibraryModel(library: source, gate: gate)
        try await model.openSource(persisted: PhotoSelectionState())
        gate.setPaused(true)
        for _ in 0..<20 { model.requestAlbums() }
        await Task.yield()
        let before = await source.catalogRequests
        XCTAssertEqual(before, 0)
        gate.setPaused(false)
        await eventually { model.loadedAlbums }
        let after = await source.catalogRequests
        XCTAssertEqual(after, 1)
        XCTAssertTrue(model.uploadSnapshot().isEmpty)
    }

    func testGalleryChangeDeltaTracksInsertedAsset() {
        let delta = GalleryChangeDelta(insertedIndexes: IndexSet(integer: 3), removedAssetIDs: [], changedAssetIDs: [], isIncremental: true, newCount: 11)
        XCTAssertTrue(delta.insertedIndexes.contains(3))
        XCTAssertTrue(delta.isIncremental)
        XCTAssertEqual(delta.newCount, 11)
    }

    func testGalleryChangeDeltaTracksRemovedAsset() {
        let delta = GalleryChangeDelta(insertedIndexes: [], removedAssetIDs: ["asset-2"], changedAssetIDs: [], isIncremental: true, newCount: 9)
        XCTAssertEqual(delta.removedAssetIDs, ["asset-2"])
    }

    func testGalleryChangeDeltaTracksChangedAsset() {
        let delta = GalleryChangeDelta(insertedIndexes: [], removedAssetIDs: [], changedAssetIDs: ["asset-4"], isIncremental: true, newCount: 10)
        XCTAssertEqual(delta.changedAssetIDs, ["asset-4"])
    }

    func testNonIncrementalGalleryChangeIsMarkedForFullRefresh() {
        let delta = GalleryChangeDelta(insertedIndexes: [], removedAssetIDs: [], changedAssetIDs: [], isIncremental: false, newCount: 100_000)
        XCTAssertFalse(delta.isIncremental)
        XCTAssertEqual(delta.newCount, 100_000)
    }

    func testOnlyAffectedGalleryCacheEntriesAreInvalidated() {
        let remaining = GalleryChangeDelta.invalidatedCacheKeys(["asset-1", "asset-2", "asset-3"], removed: ["asset-2"], changed: ["asset-3"])
        XCTAssertEqual(remaining, ["asset-1"])
    }

    func testGalleryChangeStateRevisionIncrements() {
        let first = PhotoLibraryChangeState()
        let change = GalleryChangeResult(requiresFullRefresh: false, changedAssetIDs: ["asset-1"], removedAssetIDs: [])
        let second = PhotoLibraryChangeState.applying(change, to: first)
        let third = PhotoLibraryChangeState.applying(change, to: second)
        XCTAssertEqual(second.revision, 1)
        XCTAssertEqual(third.revision, 2)
    }

    func testGalleryChangeStateDoesNotAlterSelectionState() {
        let selection = PhotoSelectionState(manuallySelectedAssetIDs: ["cloud:asset-1"], selectedAlbumIDs: ["cloud:album-1"])
        let change = GalleryChangeResult(requiresFullRefresh: true, changedAssetIDs: [], removedAssetIDs: ["asset-1"])
        _ = PhotoLibraryChangeState.applying(change, to: PhotoLibraryChangeState())
        XCTAssertEqual(selection.manuallySelectedAssetIDs, ["cloud:asset-1"])
        XCTAssertEqual(selection.selectedAlbumIDs, ["cloud:album-1"])
    }

    func testFrozenUploadSnapshotIsIndependentOfGalleryChanges() {
        let snapshot: Set<String> = ["cloud:asset-1", "cloud:asset-2"]
        let change = GalleryChangeResult(requiresFullRefresh: false, changedAssetIDs: [], removedAssetIDs: ["asset-1"])
        _ = PhotoLibraryChangeState.applying(change, to: PhotoLibraryChangeState())
        XCTAssertEqual(snapshot, ["cloud:asset-1", "cloud:asset-2"])
    }
}
