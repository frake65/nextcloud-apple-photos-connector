import XCTest
@testable import InventoryCore

final class DebugFileLoggerTests: XCTestCase {
    func testDebugEnabledCreatesLogAndLifecycleEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = DebugFileLogger(enabled: true, baseURL: root.appendingPathComponent("Library"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logger.fileURL.path))
        let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("debug.logger.initialized"))
        XCTAssertTrue(logger.fileURL.path.hasSuffix("Library/Logs/Apple Photos Connector/debug.log"))
    }

    func testDebugDisabledDoesNotCreatePersistentLog() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = DebugFileLogger(enabled: false, baseURL: root.appendingPathComponent("Library"))
        logger.log("ignored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.fileURL.path))
    }

    func testLifecycleLogContainsNoCredentialFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logger = DebugFileLogger(enabled: true, baseURL: root.appendingPathComponent("Library"))
        let contents = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("token"))
    }
}
