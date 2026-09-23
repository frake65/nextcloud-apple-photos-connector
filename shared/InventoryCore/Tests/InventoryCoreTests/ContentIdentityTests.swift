import CryptoKit
import Foundation
import XCTest
@testable import InventoryCore

final class ContentIdentityTests: XCTestCase {
    func testEmptyFileProducesEmptyIdentity() throws {
        let url = try temporaryFile(data: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try ContentIdentity.read(url), ContentIdentity(bytes: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }

    func testSmallFileProducesExpectedSHA256AndByteCount() throws {
        let data = Data("abc".utf8)
        let url = try temporaryFile(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let identity = try ContentIdentity.read(url)
        XCTAssertEqual(identity.bytes, 3)
        XCTAssertEqual(identity.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFileLargerThanOneChunkProducesExpectedIdentity() throws {
        let data = Data((0..<(1_048_576 + 17)).map { UInt8($0 % 251) })
        let url = try temporaryFile(data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let identity = try ContentIdentity.read(url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(identity.bytes, Int64(data.count))
        XCTAssertEqual(identity.sha256, expected)
    }

    private func temporaryFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return url
    }
}
