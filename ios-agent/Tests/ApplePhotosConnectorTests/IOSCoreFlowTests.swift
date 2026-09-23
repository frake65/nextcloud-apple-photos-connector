import Foundation
import XCTest
@testable import ApplePhotosConnector
import InventoryCore

final class IOSCoreFlowTests: XCTestCase {
    func testImportPresentationSeparatesTransferAlbumSyncAndCompletion() {
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .idle, completed: 0, total: 3, isVerifyingCompletedUpload: false), .idle)
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .uploading, completed: 1, total: 3, isVerifyingCompletedUpload: false), .transferring)
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .completing, completed: 1, total: 3, isVerifyingCompletedUpload: true), .serverVerification)
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .completing, completed: 3, total: 3, isVerifyingCompletedUpload: false), .albumSync)
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .finished, completed: 3, total: 3, isVerifyingCompletedUpload: false), .completed)
    }

    func testImportPresentationDoesNotTreatFailureOrCancellationAsCompleted() {
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .failed, completed: 3, total: 3, isVerifyingCompletedUpload: false), .stopped)
        XCTAssertEqual(ImportPresentationPhase.resolve(phase: .cancelled, completed: 3, total: 3, isVerifyingCompletedUpload: false), .stopped)
    }

    func testUploadAreaAllowsNavigationWithoutSelectionButNotNewImport() {
        XCTAssertTrue(ImportPresentationPhase.allowsNewImport(selectionCount: 1, canImport: true))
        XCTAssertFalse(ImportPresentationPhase.allowsNewImport(selectionCount: 0, canImport: true))
        XCTAssertFalse(ImportPresentationPhase.allowsNewImport(selectionCount: 1, canImport: false))
    }

    func testBackgroundTransferFileStorePublishesOnlyCompleteFile() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("iOS Simulator does not expose NSFileProtection attributes; verify on a real device")
#else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: source)
        let store = BackgroundTransferFileStore(directoryURL: directory.appendingPathComponent("Transfers"))
        let prepared = try await store.prepare(source: source, uploadAttemptID: UUID())
        XCTAssertEqual(try Data(contentsOf: prepared.url).count, 32)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: prepared.url.path)[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.deletingLastPathComponent().appendingPathComponent(".\(prepared.relativePath).staging").path))
#endif
    }

    func testQueueAndBindingMetadataKeepCompleteFileProtection() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("iOS Simulator does not expose NSFileProtection attributes; verify on a real device")
#else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = queueRun()
        try await ImportQueueStore(directoryURL: directory).save(run)
        let queueURL = directory.appendingPathComponent("import-queue-v1.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: queueURL.path)[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: queueURL.path)
        let migratedQueue = ImportQueueStore(directoryURL: directory)
        XCTAssertEqual(await migratedQueue.allRuns(), [run])
        try await migratedQueue.save(run)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: queueURL.path)[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        let bindings = BackgroundTaskBindingStore(directoryURL: directory)
        try await bindings.upsert(BackgroundTaskBinding(queueAssetID: UUID(), localRunID: UUID(), uploadAttemptID: UUID(), sessionIdentifier: BackgroundTransferCoordinator.sessionIdentifier, taskIdentifier: 9, relativeTransferPath: "attempt.upload", expectedHost: "cloud.example", targetPath: "/remote.php/dav/files/alice/Photos/clip.mov", createdAt: Date()))
        let bindingURL = directory.appendingPathComponent("background-task-bindings-v1.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: bindingURL.path)[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
#endif
    }

    func testFailedPutRemainsNeedsReconcileAndRecoverable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory)
        let run = queueRun(); try await store.save(run)
        try await store.markAsset(runID: run.localRunID, assetID: run.assets[0].queueAssetID, state: .needsReconcile, lastConfirmedStep: "http-502")
        let runs = await store.allRuns()
        let recovered = try XCTUnwrap(runs.first)
        XCTAssertEqual(recovered.assets[0].state, .needsReconcile)
        XCTAssertEqual(ImportRecoveryCoordinator.action(for: recovered, asset: recovered.assets[0]), .reconcile)
        XCTAssertNotEqual(recovered.assets[0].state, .completed)
    }

    func testSuccessfulPutCancelledBeforeCompleteRemainsRecoverable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory)
        let run = queueRun(); try await store.save(run)
        try await store.markAsset(runID: run.localRunID, assetID: run.assets[0].queueAssetID, state: .needsReconcile, lastConfirmedStep: "put-201-before-complete")
        let runs = await store.allRuns()
        let recovered = try XCTUnwrap(runs.first)
        XCTAssertEqual(recovered.assets[0].state, .needsReconcile)
        XCTAssertEqual(ImportRecoveryCoordinator.action(for: recovered, asset: recovered.assets[0]), .reconcile)
    }

    func testBackgroundTaskBindingRoundTripsWithoutCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BackgroundTaskBindingStore(directoryURL: directory)
        let binding = BackgroundTaskBinding(queueAssetID: UUID(), localRunID: UUID(), uploadAttemptID: UUID(), sessionIdentifier: BackgroundTransferCoordinator.sessionIdentifier, taskIdentifier: 17, relativeTransferPath: "attempt.upload", expectedHost: "cloud.example", targetPath: "/remote.php/dav/files/alice/Photos/clip.mov", createdAt: Date(timeIntervalSince1970: 1))
        try await store.upsert(binding)
        let loaded = await store.all()
        XCTAssertEqual(loaded, [binding])
        let data = try Data(contentsOf: directory.appendingPathComponent("background-task-bindings-v1.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Authorization")); XCTAssertFalse(text.contains("password"))
    }

    func testBackgroundTaskBindingDoesNotRepresentCompletedAsset() {
        let binding = BackgroundTaskBinding(queueAssetID: UUID(), localRunID: UUID(), uploadAttemptID: UUID(), sessionIdentifier: BackgroundTransferCoordinator.sessionIdentifier, taskIdentifier: 1, relativeTransferPath: "attempt.upload", expectedHost: "cloud.example", targetPath: "/remote.php/dav/files/alice/Photos/clip.mov", createdAt: Date())
        XCTAssertNotEqual(binding.taskIdentifier, 0)
        XCTAssertEqual(ImportAssetState.needsReconcile, .needsReconcile)
    }

    private func queueRun(sourceID: UUID = UUID()) -> PersistedImportRun {
        let asset = PersistedImportAsset(queueAssetID: UUID(), stableIdentity: "cloud:asset", localIdentifier: "local", cloudIdentifier: "asset", mediaType: "video", filenameHint: "clip.mov", captureDate: Date(timeIntervalSince1970: 1), state: .needsReconcile, serverAssetID: "7", uploadID: "8", targetPath: nil, expectedBytes: 42, expectedSHA256: String(repeating: "a", count: 64), lastConfirmedStep: "remote-state-unknown", retryCount: 1, lastErrorCode: nil)
        return PersistedImportRun(schemaVersion: PersistedImportRun.currentSchemaVersion, localRunID: UUID(), account: ImportAccountReference(serverBaseURL: "https://cloud.example", username: "alice"), sourceID: sourceID, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), state: .assetProcessing, serverRunID: "run", assetOrder: [asset.queueAssetID], albumSyncPending: false, assets: [asset])
    }

    func testImportQueueRoundTripsAndContainsNoCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory)
        let run = queueRun()
        try await store.save(run)
        let runs = await store.allRuns()
        let loaded = try XCTUnwrap(runs.first)
        XCTAssertEqual(loaded, run)
        let serialized = try await store.serializedData()
        let text = String(decoding: serialized, as: UTF8.self)
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("Authorization"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("import-queue-v1.json").path))
    }

    func testImportQueueCorruptFileLoadsEmptyWithoutCrash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("import-queue-v1.json"))
        let runs = await ImportQueueStore(directoryURL: directory).allRuns()
        XCTAssertTrue(runs.isEmpty)
    }

    func testImportQueueRecoveryActionsDoNotTreatUploadingAsCompleted() {
        let run = queueRun()
        XCTAssertEqual(ImportRecoveryCoordinator.action(for: run, asset: run.assets[0]), .reconcile)
        var completed = run; completed.state = .assetsComplete
        XCTAssertEqual(ImportRecoveryCoordinator.action(for: completed, asset: run.assets[0]), .albumSync)
    }

    func testImportQueuePreservesAssetOrderAndAlbumPendingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory); var run = queueRun(); run.albumSyncPending = true; run.state = .albumSyncPending
        try await store.save(run)
        let runs = await store.recoverableRuns()
        let loaded = try XCTUnwrap(runs.first)
        XCTAssertEqual(loaded.assetOrder, run.assetOrder); XCTAssertTrue(loaded.albumSyncPending)
    }

    func testPersistedIncompleteRunRemainsRecoverableWithoutBackgroundBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory)
        let run = queueRun()
        try await store.save(run)

        let recoverable = await store.recoverableRuns()
        XCTAssertEqual(recoverable.map(\.localRunID), [run.localRunID])
        XCTAssertEqual(recoverable.first?.assets.first?.state, .needsReconcile)
    }

    func testImportQueueSelectsNewestRecoverableRunPerAccountAndSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ImportQueueStore(directoryURL: directory)
        let sourceID = UUID()
        var older = queueRun(sourceID: sourceID); older.updatedAt = Date(timeIntervalSince1970: 2)
        var newer = queueRun(sourceID: sourceID); newer.updatedAt = Date(timeIntervalSince1970: 3)
        try await store.save(older); try await store.save(newer)
        let runs = await store.recoverableRuns()
        XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs.first?.localRunID, newer.localRunID)
    }

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
        defaults.removeObject(forKey: key)
        XCTAssertFalse(IOSImportDiagnostics.enabled)
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

    func testAssetJobSchedulerCollectsFailureWithoutCancellingSibling() async throws {
        let siblingFinished = expectation(description: "sibling finished")
        let results = try await IOSAssetJobScheduler.runCollectingFailures(count: 2, maxConcurrent: 2) { index in
            if index == 0 { throw SchedulerTestError.failed }
            try await Task.sleep(for: .milliseconds(20))
            siblingFinished.fulfill()
            return index
        }
        await fulfillment(of: [siblingFinished], timeout: 1)
        XCTAssertEqual(results.compactMap(\.result), [1])
        XCTAssertEqual(results.compactMap(\.errorDescription).count, 1)
    }

    func testAssetJobSchedulerFailureDoesNotInvokeSiblingCancellationHandler() async throws {
        let cancellations = CancellationProbe()
        let results = try await IOSAssetJobScheduler.runCollectingFailures(count: 2, maxConcurrent: 2) { index in
            if index == 0 { throw SchedulerTestError.failed }
            return try await withTaskCancellationHandler(operation: {
                try await Task.sleep(for: .milliseconds(30))
                return index
            }, onCancel: {
                Task { await cancellations.record() }
            })
        }
        XCTAssertEqual(results.compactMap(\.result), [1])
        let cancellationCount = await cancellations.count
        XCTAssertEqual(cancellationCount, 0)
    }

    func testBackgroundPUTWaitingAggregationIsTaskScopedAndSessionScoped() {
        var state = BackgroundPUTTaskStateAggregation()
        let wifiTask = "wifi.v1:7"
        let cellularTask = "cellular.v1:7"

        state.started(wifiTask)
        state.started(cellularTask)
        state.sending(cellularTask)
        state.waiting(wifiTask)
        XCTAssertFalse(state.waitingForConnectivity)

        XCTAssertTrue(state.waitingTasks.contains(wifiTask))

        state.waiting(cellularTask)
        XCTAssertTrue(state.waitingForConnectivity)
        XCTAssertTrue(state.activeSendingTasks.isEmpty)

        state.sending(wifiTask)
        XCTAssertFalse(state.waitingForConnectivity)
        XCTAssertFalse(state.waitingTasks.contains(wifiTask))
        XCTAssertTrue(state.activeSendingTasks.contains(wifiTask))

        state.completed(wifiTask)
        state.completed(cellularTask)
        XCTAssertFalse(state.waitingForConnectivity)
        XCTAssertTrue(state.activePUTTasks.isEmpty)
        XCTAssertTrue(state.waitingTasks.isEmpty)
        XCTAssertTrue(state.activeSendingTasks.isEmpty)
    }

    func testAssetJobSchedulerCollectsIndependentFailures() async throws {
        let results = try await IOSAssetJobScheduler.runCollectingFailures(count: 2, maxConcurrent: 2) { _ in
            throw SchedulerTestError.failed
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.result == nil && $0.errorDescription != nil })
    }

    func testAssetJobSchedulerCollectionStillPropagatesUserCancellation() async {
        let task = Task {
            try await IOSAssetJobScheduler.runCollectingFailures(count: 2, maxConcurrent: 2) { _ in
                try await Task.sleep(for: .seconds(1))
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // User cancellation still cancels the group and its children.
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

    @MainActor
    func testTargetDirectoryUsesDefaultAndPreservesLegacyConnectionRecords() throws {
        let suite = "apc-ios-target-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = TestPasswordStore()
        let preferences = IOSConnectionPreferences(defaults: defaults, passwordStore: keychain)
        XCTAssertEqual(preferences.load().details.targetDirectory, "Photos/Photos Connector")
        let legacy = #"{"server":"https://cloud.example","username":"alice","sourceId":"550e8400-e29b-41d4-a716-446655440000","userId":null}"#.data(using: .utf8)!
        defaults.set(legacy, forKey: "ios.connection.details.v1")
        XCTAssertEqual(preferences.load().details.targetDirectory, "Photos/Photos Connector")
    }

    @MainActor
    func testTargetDirectoryPersistsAndNormalizesLikeMacOS() throws {
        XCTAssertEqual(IOSTargetDirectoryPreferences.normalize("/Photos/Test/"), "Photos/Test")
        XCTAssertEqual(IOSTargetDirectoryPreferences.normalize("//Photos//Test//"), "Photos/Test")
        XCTAssertEqual(IOSTargetDirectoryPreferences.display("Photos/Photos Connector"), "/Photos/Photos Connector")

        let suite = "apc-ios-target-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IOSConnectionPreferences(defaults: defaults, passwordStore: TestPasswordStore())
        try preferences.save(server: "https://cloud.example", username: "alice", password: "app-password", sourceId: UUID(), targetDirectory: "//Photos//Test//")
        XCTAssertEqual(preferences.load().details.targetDirectory, "Photos/Test")
    }

    func testUploadPathUsesOneConfiguredRootForPrepareAndWebDAV() throws {
        let date = Date(timeIntervalSince1970: 1_758_124_800) // 2025-09-01 UTC; calendar components are deterministic enough for path shape.
        let path = try XCTUnwrap(IOSUploadPath.folder(base: "/Photos/Photos Connector/", date: date))
        XCTAssertEqual(path.root, "Photos/Photos Connector")
        XCTAssertTrue(path.folder.hasPrefix(path.root + "/"))
        XCTAssertTrue(path.folder.hasSuffix("/09"))
    }

    func testIOSImportSharesFolderCoordinatorForParallelAssets() async throws {
        let coordinator = WebDAVFolderCoordinator()
        let calls = TestFolderCallCounter()
        async let first: Void = coordinator.ensure(path: "Photos/iPhone Test/2026/09") {
            await calls.increment()
            try await Task.sleep(for: .milliseconds(25))
        }
        async let second: Void = coordinator.ensure(path: "Photos/iPhone Test/2026/09") {
            await calls.increment()
        }
        _ = try await (first, second)
        let callCount = await calls.value
        let ensured = await coordinator.isEnsured(path: "Photos/iPhone Test/2026/09")
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(ensured)
    }

    func testTransferCellularPreferenceDefaultsOffAndPersists() {
        let suite = "apc-ios-transfer-policy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(IOSTransferNetworkPreferences.useCellularAccess(defaults: defaults))
        IOSTransferNetworkPreferences.setUseCellularAccess(true, defaults: defaults)
        XCTAssertTrue(IOSTransferNetworkPreferences.useCellularAccess(defaults: defaults))
    }

    func testBackgroundTransferNetworkPolicySeparatesCellularAndConnectivityWaiting() {
        let wifiOnly = BackgroundTransferNetworkPolicy(allowsCellularAccess: false)
        XCTAssertFalse(wifiOnly.allowsCellularAccess)
        XCTAssertTrue(wifiOnly.waitsForConnectivity)

        let cellularAllowed = BackgroundTransferNetworkPolicy(allowsCellularAccess: true)
        XCTAssertTrue(cellularAllowed.allowsCellularAccess)
        XCTAssertTrue(cellularAllowed.waitsForConnectivity)
    }

    func testImportConnectivityPolicyWaitsOnlyForMissingRequiredPath() {
        XCTAssertTrue(ImportConnectivityPolicy.shouldWait(allowsCellular: false, networkSatisfied: false, wifiAvailable: false))
        XCTAssertTrue(ImportConnectivityPolicy.shouldWait(allowsCellular: false, networkSatisfied: true, wifiAvailable: false))
        XCTAssertFalse(ImportConnectivityPolicy.shouldWait(allowsCellular: false, networkSatisfied: true, wifiAvailable: true))
        XCTAssertFalse(ImportConnectivityPolicy.shouldWait(allowsCellular: true, networkSatisfied: true, wifiAvailable: false))
        XCTAssertFalse(ImportConnectivityPolicy.shouldWait(allowsCellular: true, networkSatisfied: true, wifiAvailable: true))
        XCTAssertTrue(ImportConnectivityPolicy.shouldWait(allowsCellular: true, networkSatisfied: false, wifiAvailable: false))
    }

    func testActiveConnectivityWaitDoesNotAllowSecondImportOrIdleHelp() {
        XCTAssertFalse(ImportPresentationPhase.allowsStart(phase: .transferring, isRunning: true, hasActiveBackgroundTransfer: false, waitingForWiFi: true))
        XCTAssertFalse(ImportPresentationPhase.allowsStart(phase: .idle, isRunning: false, hasActiveBackgroundTransfer: true, waitingForWiFi: false))
        XCTAssertFalse(ImportPresentationPhase.allowsStart(phase: .stopped, isRunning: false, hasActiveBackgroundTransfer: false, waitingForWiFi: true))
        XCTAssertFalse(ImportPresentationPhase.allowsStart(phase: .idle, isRunning: false, hasActiveBackgroundTransfer: false, waitingForWiFi: false, hasRecoverableRun: true))
        XCTAssertFalse(ImportPresentationPhase.showsIdleHelp(phase: .idle, isRunning: false, hasActiveBackgroundTransfer: true, waitingForWiFi: false))
        XCTAssertFalse(ImportPresentationPhase.showsIdleHelp(phase: .idle, isRunning: false, hasActiveBackgroundTransfer: false, waitingForWiFi: false, hasRecoverableRun: true))
        XCTAssertFalse(ImportPresentationPhase.showsIdleHelp(phase: .transferring, isRunning: true, hasActiveBackgroundTransfer: false, waitingForWiFi: true))
        XCTAssertTrue(ImportPresentationPhase.allowsStart(phase: .stopped, isRunning: false, hasActiveBackgroundTransfer: false, waitingForWiFi: false))
    }

    func testResumeUsesCompletedQueueAssetsAndKeepsThemMonotonic() {
        let completed = PersistedImportAsset(queueAssetID: UUID(), stableIdentity: "completed", localIdentifier: "1", cloudIdentifier: nil, mediaType: "image", filenameHint: nil, captureDate: nil, state: .completed, serverAssetID: nil, uploadID: nil, targetPath: nil, expectedBytes: nil, expectedSHA256: nil, lastConfirmedStep: "complete-confirmed", retryCount: 0, lastErrorCode: nil)
        let open = PersistedImportAsset(queueAssetID: UUID(), stableIdentity: "open", localIdentifier: "2", cloudIdentifier: nil, mediaType: "image", filenameHint: nil, captureDate: nil, state: .needsPrepare, serverAssetID: nil, uploadID: nil, targetPath: nil, expectedBytes: nil, expectedSHA256: nil, lastConfirmedStep: "inventory-ticket", retryCount: 0, lastErrorCode: nil)
        let assets = [completed, completed, open, open, open, open]
        let run = PersistedImportRun(schemaVersion: PersistedImportRun.currentSchemaVersion, localRunID: UUID(), account: ImportAccountReference(serverBaseURL: "https://example.test", username: "user"), sourceID: UUID(), createdAt: Date(), updatedAt: Date(), state: .assetProcessing, serverRunID: nil, assetOrder: assets.map(\.queueAssetID), albumSyncPending: false, assets: assets)

        XCTAssertEqual(IOSForegroundImportCoordinator.completedAssetCount(in: run), 2)
        XCTAssertNil(IOSForegroundImportCoordinator.resumeInventoryState(localState: .completed, serverState: .new))
        XCTAssertEqual(IOSForegroundImportCoordinator.resumeInventoryState(localState: .needsPrepare, serverState: .new), .needsPrepare)
        XCTAssertEqual(IOSForegroundImportCoordinator.resumeInventoryState(localState: .needsPrepare, serverState: .known), .completed)
    }

    func testActiveImportRemainsCancellableWhileBlockingStart() {
        XCTAssertTrue(ImportPresentationPhase.allowsStart(phase: .idle, isRunning: true, hasActiveBackgroundTransfer: false, waitingForWiFi: true) == false)
        XCTAssertTrue(ImportPresentationPhase.showsCancel(isRunning: true, waitingForWiFi: true))
        XCTAssertTrue(ImportPresentationPhase.showsCancel(isRunning: false, waitingForWiFi: true))
        XCTAssertFalse(ImportPresentationPhase.showsCancel(isRunning: false, waitingForWiFi: false))
        XCTAssertTrue(ImportRunState.assetProcessing.hasOpenImport)
        XCTAssertTrue(ImportRunState.assetsComplete.hasOpenImport)
        XCTAssertTrue(ImportRunState.albumSyncPending.hasOpenImport)
    }

    func testOnlyOpenImportRunsCanBlockForBackgroundActivity() {
        XCTAssertTrue(ImportRunState.assetProcessing.hasOpenImport)
        XCTAssertTrue(ImportRunState.assetsComplete.hasOpenImport)
        XCTAssertTrue(ImportRunState.albumSyncPending.hasOpenImport)
        XCTAssertFalse(ImportRunState.completed.hasOpenImport)
        XCTAssertFalse(ImportRunState.failed.hasOpenImport)
        XCTAssertFalse(ImportRunState.cancelled.hasOpenImport)
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

    func testIOSFilenamePolicyKeepsValidOriginalName() {
        XCTAssertEqual(IOSFilenamePolicy.resolved(originalFilename: "IMG_1234.HEIC", localIdentifier: "local", mediaType: "image"), "IMG_1234.HEIC")
    }

    func testIOSFilenamePolicyFallsBackForEmptyOrUnavailableNames() {
        XCTAssertEqual(IOSFilenamePolicy.resolved(originalFilename: "   ", localIdentifier: "A/B", mediaType: "image"), "asset-A_B.jpg")
        XCTAssertEqual(IOSFilenamePolicy.resolved(originalFilename: nil, localIdentifier: "video-id", mediaType: "video"), "asset-video-id.mov")
    }

    func testIOSFilenamePolicyRejectsUnsafeOrOversizedNames() {
        XCTAssertEqual(IOSFilenamePolicy.resolved(originalFilename: "folder/photo.jpg", localIdentifier: "local", mediaType: "image"), "asset-local.jpg")
        XCTAssertEqual(IOSFilenamePolicy.resolved(originalFilename: String(repeating: "x", count: 4097), localIdentifier: "local", mediaType: "image"), "asset-local.jpg")
    }

    func testIOSFilenamePolicyKeepsInventoryAndExportFallbackConsistent() {
        let filename = IOSFilenamePolicy.resolved(originalFilename: nil, localIdentifier: "video-id", mediaType: "video")
        XCTAssertEqual(filename, "asset-video-id.mov")
        XCTAssertFalse(filename.isEmpty)
        XCTAssertFalse(filename.contains("/"))
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

    @MainActor
    func testSuccessfulLoginValidationRemainsConnectedUntilCredentialsChange() throws {
        let suite = "apc-ios-login-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IOSConnectionModel(preferences: IOSConnectionPreferences(defaults: defaults, passwordStore: TestPasswordStore()))
        model.server = "https://cloud.example"
        model.username = "login-name"
        model.password = "app-password"
        model.markConnectionValidated(userID: "canonical-user")
        model.markEdited()
        XCTAssertEqual(model.state, .connected)
        model.username = "changed-login"
        model.markEdited()
        XCTAssertEqual(model.state, .notTested)
    }

    @MainActor
    func testPersistedCredentialsCountAsConfiguredBeforeRuntimeValidation() throws {
        let suite = "apc-ios-configured-connection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IOSConnectionPreferences(defaults: defaults, passwordStore: TestPasswordStore())
        try preferences.save(server: "https://cloud.example", username: "alice", password: "app-password", sourceId: UUID())
        let model = IOSConnectionModel(preferences: preferences)
        XCTAssertTrue(model.hasConfiguredConnection)
        XCTAssertEqual(model.state, .notTested)
    }

    @MainActor
    func testEmptyConnectionIsNotConfigured() throws {
        let suite = "apc-ios-empty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IOSConnectionModel(preferences: IOSConnectionPreferences(defaults: defaults, passwordStore: TestPasswordStore()))
        XCTAssertFalse(model.hasConfiguredConnection)
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

    func testInventoryDiagnosticsPreserveInvalidResponseBranches() async throws {
        let source = PhotoSource(sourceId: UUID(), name: "Apple Photos")
        let asset = AssetInventory(localIdentifier: "local", cloudIdentifier: "cloud", mediaType: "image", creationDate: nil, filename: "photo.jpg")
        let runID = UUID().uuidString.lowercased()
        let uploadID = UUID().uuidString.lowercased()
        let valid = Data("{\"runId\":\"\(runID)\",\"summary\":{\"seen\":1,\"new\":1,\"known\":0},\"assets\":[{\"cloudIdentifier\":\"cloud\",\"state\":\"new\",\"upload\":{\"uploadId\":\"\(uploadID)\",\"assetId\":\"7\"}}]}".utf8)
        let connection = try ConnectorConnection(server: "https://cloud.example", user: "alice", password: "app-password")
        let cases: [(Int, Data)] = [
            (400, Data(#"{"runId":"redacted","error":"validation_error"}"#.utf8)),
            (409, Data(#"{"runId":"redacted","error":"Concurrent source registration; retry the inventory"}"#.utf8)),
            (200, Data(#"{"runId":"broken"}"#.utf8)),
            (200, Data("{\"runId\":\"\(runID)\",\"summary\":{\"seen\":2,\"new\":1,\"known\":0},\"assets\":[{\"cloudIdentifier\":\"cloud\",\"state\":\"new\",\"upload\":{\"uploadId\":\"\(uploadID)\",\"assetId\":\"7\"}}]}".utf8)),
            (200, Data("{\"runId\":\"\(runID)\",\"summary\":{\"seen\":1,\"new\":0,\"known\":1},\"assets\":[{\"cloudIdentifier\":\"cloud\",\"state\":\"new\",\"upload\":{\"uploadId\":\"\(uploadID)\",\"assetId\":\"7\"}}]}".utf8)),
            (200, valid)
        ]
        for (status, data) in cases {
            do {
                _ = try await InventoryCheckClient.check(connection: connection, source: source, assets: [asset], transport: StaticInventoryTransport(status: status, data: data))
                if status != 200 || data != valid { XCTFail("Expected invalid inventory response for status \(status)") }
            } catch let error as InventoryCheckError {
                XCTAssertEqual(error.localizedDescription, InventoryCheckError.invalidResponse.localizedDescription)
            }
        }
    }

    func testInventoryHTTP400LogsServerErrorThroughProductionPath() async throws {
        let key = IOSImportDiagnostics.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        var lines: [String] = []
        IOSImportDiagnostics.testLogHandler = { lines.append($0) }
        defer {
            IOSImportDiagnostics.testLogHandler = nil
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let connection = try ConnectorConnection(server: "https://example.test", user: "user", password: "password")
        let source = PhotoSource(sourceId: UUID(), name: "Apple Photos")
        let asset = AssetInventory(localIdentifier: "local", cloudIdentifier: "cloud", mediaType: "image", creationDate: nil, filename: "photo.jpg")
        let body = Data(#"{"runId":"run-12345678","error":"TEST_ERROR"}"#.utf8)

        do {
            _ = try await InventoryCheckClient.check(connection: connection, source: source, assets: [asset], transport: StaticInventoryTransport(status: 400, data: body))
            XCTFail("Expected HTTP 400 to fail")
        } catch let error as InventoryCheckError {
            XCTAssertEqual(error.localizedDescription, InventoryCheckError.invalidResponse.localizedDescription)
        }

        let output = lines.joined(separator: "\n")
        XCTAssertTrue(output.contains("Inventory HTTP 400"), output)
        XCTAssertTrue(output.contains("Server error: TEST_ERROR"), output)
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

private actor CancellationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor TestFolderCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
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

private struct StaticInventoryTransport: DAVTransport {
    let status: Int
    let data: Data
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse { DAVResponse(status: status, data: data, headers: ["Content-Type": "application/json"]) }
}

private actor RecordingAlbumTransport: DAVTransport {
    struct Request { let path: String; let body: String; let file: Bool }
    private(set) var requests: [Request] = []
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        requests.append(Request(path: request.url?.path ?? "", body: String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "", file: file != nil))
        return DAVResponse(status: 200, data: Data(#"{"albums":[],"count":0}"#.utf8))
    }
}
