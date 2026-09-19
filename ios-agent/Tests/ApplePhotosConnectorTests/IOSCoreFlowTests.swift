import Foundation
import XCTest
@testable import ApplePhotosConnector
import InventoryCore

final class IOSCoreFlowTests: XCTestCase {
    func testImportProgressAggregationIsMonotoneAndByteBased() {
        var progress = IOSImportProgressAggregation()
        progress.update(job: 0, sent: 40, total: 100)
        XCTAssertEqual(progress.sentBytes, 40)
        progress.update(job: 0, sent: 100, total: 100)
        progress.update(job: 1, sent: 25, total: 200)
        XCTAssertEqual(progress.sentBytes, 125)
        XCTAssertEqual(progress.totalBytes, 300)
        XCTAssertEqual(progress.fraction, 125.0 / 300.0, accuracy: 0.0001)
    }

    func testImportProgressAggregationRemovesCompletedJobs() {
        var progress = IOSImportProgressAggregation()
        progress.update(job: 0, sent: 50, total: 100)
        progress.update(job: 1, sent: 20, total: 100)
        XCTAssertEqual(progress.activeFraction, 0.7, accuracy: 0.0001)
        progress.remove(job: 0)
        XCTAssertEqual(progress.activeFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(progress.activeEntries.map(\.job), [1])
    }

    func testImportProgressKeepsParallelPutDenominatorsPerAsset() {
        var progress = IOSImportProgressAggregation()
        progress.update(job: 0, sent: 30, total: 100)
        progress.update(job: 1, sent: 200, total: 1000)
        XCTAssertEqual(progress.activeEntries.map(\.total), [100, 1000])
        XCTAssertEqual(progress.activeFraction, 0.5, accuracy: 0.0001)
    }

    @MainActor
    func testCompleteVerificationStatusDoesNotHideParallelPut() {
        XCTAssertTrue(IOSForegroundImportCoordinator.isVerifyingCompletedUpload(pendingCompletionCount: 1, activeTransferCount: 0))
        XCTAssertFalse(IOSForegroundImportCoordinator.isVerifyingCompletedUpload(pendingCompletionCount: 1, activeTransferCount: 1))
        XCTAssertFalse(IOSForegroundImportCoordinator.isVerifyingCompletedUpload(pendingCompletionCount: 0, activeTransferCount: 0))
    }

    #if DEBUG
    func testImportDiagnosticsUsesSharedDefaultsKey() {
        let defaults = UserDefaults.standard
        let key = IOSImportDiagnostics.defaultsKey
        let old = defaults.object(forKey: key)
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(false, forKey: key)
        XCTAssertFalse(IOSImportDiagnostics.enabled)
        defaults.set(true, forKey: key)
        XCTAssertTrue(IOSImportDiagnostics.enabled)
    }
    #endif

    func testAssetJobSchedulerCapsConcurrencyAndPreservesInputOrder() async throws {
        let probe = SchedulerProbe()
        let results = try await IOSAssetJobScheduler.run(count: 6, maxConcurrent: 2) { index in
            await probe.enter()
            await Task.yield()
            await probe.leave()
            return index
        }
        XCTAssertEqual(results, Array(0..<6))
        let maximum = await probe.maximum
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testAssetJobSchedulerFailsFastAndDoesNotReturnPartialResults() async {
        do {
            _ = try await IOSAssetJobScheduler.run(count: 3, maxConcurrent: 2) { index in
                if index == 0 { throw SchedulerTestError.failed }
                try Task.checkCancellation()
                return index
            }
            XCTFail("Expected the first job error")
        } catch is SchedulerTestError {
            // The throwing task group cancels sibling jobs and propagates the error.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAssetJobSchedulerDoesNotStartJobsAfterCancellation() async {
        let probe = SchedulerProbe()
        let task = Task {
            try await IOSAssetJobScheduler.run(count: 4, maxConcurrent: 2) { index in
                await probe.enter()
                return index
            }
        }
        task.cancel()
        do { _ = try await task.value } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        let started = await probe.started
        XCTAssertEqual(started, 0)
    }

    @MainActor
    func testConnectionPreferencesKeepPasswordOutOfUserDefaults() throws {
        let suite = "apc-ios-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = TestPasswordStore()
        let preferences = IOSConnectionPreferences(defaults: defaults, passwordStore: keychain)
        let source = UUID()

        try preferences.save(server: "https://cloud.example/nextcloud", username: "alice", password: "secret-app-password", sourceId: source)

        let savedData = try XCTUnwrap(defaults.data(forKey: "ios.connection.details.v1"))
        let persistedText = try XCTUnwrap(String(data: savedData, encoding: .utf8))
        XCTAssertFalse(persistedText.contains("secret-app-password"))
        XCTAssertEqual(try keychain.load(account: "https://cloud.example/nextcloud|alice"), "secret-app-password")
        XCTAssertEqual(preferences.load().details.sourceId, source)
    }

    func testAssetInventoryUsesCloudIdentityAndLocalFallback() {
        let macObservation = AssetInventory(localIdentifier: "mac-local", cloudIdentifier: "shared-cloud-id", mediaType: "image", creationDate: nil, filename: "image.jpg")
        let phoneObservation = AssetInventory(localIdentifier: "phone-local", cloudIdentifier: "shared-cloud-id", mediaType: "image", creationDate: nil, filename: "image.jpg")
        XCTAssertEqual(macObservation.stableIdentity, phoneObservation.stableIdentity)

        let localOnlyMac = AssetInventory(localIdentifier: "mac-local", mediaType: "image", creationDate: nil, filename: "image.jpg")
        let localOnlyPhone = AssetInventory(localIdentifier: "phone-local", mediaType: "image", creationDate: nil, filename: "image.jpg")
        XCTAssertNotEqual(localOnlyMac.stableIdentity, localOnlyPhone.stableIdentity)
    }

    func testSelectionIdentifiersDeduplicateAssetsReachedFromDifferentViews() {
        var selection = AssetSelectionIDs()
        selection.insert("photo-local-id")
        selection.insert("photo-local-id")
        XCTAssertEqual(selection.values, Set(["photo-local-id"]))
        selection.remove("photo-local-id")
        XCTAssertTrue(selection.values.isEmpty)
    }

    func testSelectionScopeSelectAllAndDeselectOnlyCurrentAlbum() {
        var selection = AssetSelectionIDs()
        selection.insert("outside")
        selection.insertAll(["album-a", "album-b"])
        XCTAssertTrue(selection.allSelected(in: ["album-a", "album-b"]))
        selection.removeAll(["album-a", "album-b"])
        XCTAssertEqual(selection.values, Set(["outside"]))
        XCTAssertFalse(selection.allSelected(in: ["album-a", "album-b"]))
    }

    func testSelectionScopeSelectAllDecisionForEmptyAndPartialContexts() {
        var selection = AssetSelectionIDs()
        XCTAssertFalse(selection.allSelected(in: []))
        XCTAssertFalse(selection.allSelected(in: ["a", "b"]))
        selection.insertAll(["a", "b"])
        XCTAssertTrue(selection.allSelected(in: ["a", "b"]))
    }

    func testAutoScrollVelocityIsNegativeAtTop() {
        XCTAssertLessThan(GalleryAutoScroll.velocity(fingerY: 10, viewportHeight: 800) ?? 0, 0)
    }

    func testAutoScrollVelocityIsNilInMiddle() {
        XCTAssertNil(GalleryAutoScroll.velocity(fingerY: 400, viewportHeight: 800))
    }

    func testAutoScrollVelocityIsPositiveAtBottom() {
        XCTAssertGreaterThan(GalleryAutoScroll.velocity(fingerY: 790, viewportHeight: 800) ?? 0, 0)
    }

    func testPhotoKitMetadataMapsToSharedAssetInventory() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = PhotoKitInventoryMapper.make(localIdentifier: "device-local", cloudIdentifier: "icloud-asset", mediaType: "video", creationDate: date, filename: "clip.mov")
        XCTAssertEqual(item.stableIdentity, "cloud:icloud-asset")
        XCTAssertEqual(item.mediaType, "video")
        XCTAssertEqual(item.creationDate, date)
        XCTAssertEqual(item.filename, "clip.mov")
        let json = try InventoryJSON.encode([item], source: PhotoSource(sourceId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, name: "Apple Photos"))
        XCTAssertTrue(json.contains("icloud-asset"))
    }

    func testInventoryResponseMapsNewAndKnownEntries() throws {
        let data = Data(#"{"runId":"550e8400-e29b-41d4-a716-446655440000","summary":{"seen":2,"new":1,"known":1},"assets":[{"cloudIdentifier":"cloud-a","state":"known","upload":null},{"cloudIdentifier":"cloud-b","state":"new","upload":{"uploadId":"550e8400-e29b-41d4-a716-446655440001","assetId":"42"}}]}"#.utf8)
        let reply = try JSONDecoder().decode(InventoryReply.self, from: data)
        XCTAssertEqual(reply.summary.known, 1)
        XCTAssertEqual(reply.summary.new, 1)
        XCTAssertEqual(reply.assets.map(\.state), [.known, .new])
        XCTAssertNotNil(reply.assets[1].upload)
    }

    func testConnectionStateMapsConfigurationErrors() {
        XCTAssertEqual(IOSConnectionState.notTested.title, "Konfiguriert – noch nicht geprüft")
        XCTAssertEqual(IOSConnectionState(validation: .authenticationFailed), .authenticationFailed)
        XCTAssertEqual(IOSConnectionState(validation: .appMissing), .appMissing)
        XCTAssertEqual(IOSConnectionState(validation: .tlsOrNetworkError), .networkError)
        XCTAssertEqual(IOSConnectionState(validation: .unavailable), .serverUnavailable)
    }

    @MainActor
    func testSavedConnectionStartsInNotTestedState() throws {
        let suite = "apc-ios-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IOSConnectionPreferences(defaults: defaults, passwordStore: TestPasswordStore())
        try preferences.save(server: "https://cloud.example", username: "alice", password: "app-password", sourceId: UUID())
        XCTAssertEqual(IOSConnectionModel(preferences: preferences).state, .notTested)
    }

    func testInventoryCheckOnlyPostsMetadataAndNeverProvidesAFile() async throws {
        let source = PhotoSource(sourceId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!, name: "Apple Photos")
        let asset = AssetInventory(localIdentifier: "device-local", cloudIdentifier: "icloud-asset", mediaType: "image", creationDate: nil, filename: "photo.jpg")
        let response = Data(#"{"runId":"550e8400-e29b-41d4-a716-446655440001","summary":{"seen":1,"new":1,"known":0},"assets":[{"cloudIdentifier":"icloud-asset","state":"new","upload":{"uploadId":"550e8400-e29b-41d4-a716-446655440002","assetId":"7"}}]}"#.utf8)
        let transport = RecordingInventoryTransport(response: response)
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")

        let result = try await InventoryCheckClient.check(connection: connection, source: source, assets: [asset], transport: transport)
        let request = await transport.requestSummary()

        XCTAssertEqual(result.summary.new, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.path.hasSuffix("/index.php/apps/apple_photos_connector/api/v1/inventory"))
        XCTAssertFalse(request.providedFile)
        XCTAssertTrue(request.body.contains("icloud-asset"))
    }

    func testAlbumInventoryPreservesMembershipAndStableIdentities() throws {
        let source = PhotoSource(sourceId: UUID(), name: "Apple Photos")
        let cloud = AssetInventory(localIdentifier: "phone-local", cloudIdentifier: "shared-cloud", mediaType: "image", creationDate: nil, filename: "a.heic")
        let local = AssetInventory(localIdentifier: "local-only", mediaType: "image", creationDate: nil, filename: "b.heic")
        let album = AlbumInventory(localIdentifier: "album-1", name: "Favorites", assetIdentities: [cloud.stableIdentity, local.stableIdentity])
        let document = AlbumInventoryDocument(source: source, albums: [album])
        let decoded = try JSONDecoder().decode(AlbumInventoryDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.albums.first?.assetIdentities, ["cloud:shared-cloud", "local:local-only"])
    }

    func testSameAssetCanBelongToMultipleAlbumsIncludingEmptyAlbum() {
        let identity = "cloud:shared-cloud"
        let albums = [
            AlbumInventory(localIdentifier: "one", name: "One", assetIdentities: [identity]),
            AlbumInventory(localIdentifier: "two", name: "Two", assetIdentities: [identity]),
            AlbumInventory(localIdentifier: "empty", name: "Empty")
        ]
        XCTAssertEqual(albums.filter { $0.assetIdentities.contains(identity) }.count, 2)
        XCTAssertTrue(albums.contains { $0.localIdentifier == "empty" && $0.assetIdentities.isEmpty })
    }

    func testAlbumSyncClientSendsInventoryAndSyncWithoutFiles() async throws {
        let source = PhotoSource(sourceId: UUID(), name: "Apple Photos")
        let asset = AssetInventory(localIdentifier: "local", cloudIdentifier: "cloud", mediaType: "image", creationDate: nil, filename: "a.heic")
        let album = AlbumInventory(localIdentifier: "album", name: "Album", assetIdentities: [asset.stableIdentity])
        let transport = RecordingAlbumTransport()
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "password")
        try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: [album], selectedAssets: [asset], transport: transport)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].path.hasSuffix("/albums/inventory"))
        XCTAssertTrue(requests[1].path.hasSuffix("/albums/sync"))
        XCTAssertTrue(requests.allSatisfy { !$0.file })
        XCTAssertTrue(requests[1].body.contains("cloud:cloud"))
    }

    func testAlbumSyncCanBeRepeatedWithoutFileTransfer() async throws {
        let source = PhotoSource(sourceId: UUID(), name: "Apple Photos")
        let asset = AssetInventory(localIdentifier: "local", mediaType: "image", creationDate: nil, filename: "a.heic")
        let album = AlbumInventory(localIdentifier: "album", name: "Album", assetIdentities: [asset.stableIdentity])
        let transport = RecordingAlbumTransport()
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "password")
        try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: [album], selectedAssets: [asset], transport: transport)
        try await IOSAlbumSyncClient.inventoryAndSync(connection: connection, source: source, albums: [album], selectedAssets: [asset], transport: transport)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { !$0.file })
    }
}

private actor SchedulerProbe {
    private var active = 0
    private(set) var started = 0
    private(set) var maximum = 0
    func enter() { active += 1; started += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

private enum SchedulerTestError: Error { case failed }

private final class TestPasswordStore: IOSPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]
    func save(_ password: String, account: String) throws { lock.lock(); defer { lock.unlock() }; passwords[account] = password }
    func load(account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return passwords[account] }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; passwords.removeValue(forKey: account) }
}

private actor RecordingInventoryTransport: DAVTransport {
    private let response: Data
    private var captured: (method: String, path: String, providedFile: Bool, body: String) = ("", "", false, "")

    init(response: Data) { self.response = response }

    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        captured = (request.httpMethod ?? "", request.url?.path ?? "", file != nil, String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
        return DAVResponse(status: 200, data: response)
    }

    func requestSummary() -> (method: String, path: String, providedFile: Bool, body: String) { captured }
}

private actor RecordingAlbumTransport: DAVTransport {
    struct Request { let path: String; let body: String; let file: Bool }
    private(set) var requests: [Request] = []
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        requests.append(Request(path: request.url?.path ?? "", body: String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "", file: file != nil))
        return DAVResponse(status: 200, data: Data(#"{"albums":[],"count":0}"#.utf8))
    }
}
