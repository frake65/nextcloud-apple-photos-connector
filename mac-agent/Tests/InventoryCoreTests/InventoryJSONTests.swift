import Foundation
import XCTest
@testable import InventoryCore

final class InventoryJSONTests: XCTestCase {
    private let source = PhotoSource(name: "Test Source")
    func testMetadataEncodingPreservesIdentifiersAndEscapesFilenames() throws {
        let asset = AssetInventory(localIdentifier: "ABC/L0/001", cloudIdentifier: "opaque-cloud-archive", mediaType: "image",
                                   creationDate: Date(timeIntervalSince1970: 0),
                                   filename: "Urlaub \"Köln\"\n.heic")
        let json = try InventoryJSON.encode([asset], source: source)
        let records = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["assets"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(Set(record.keys), Set(["localIdentifier", "cloudIdentifier", "mediaType", "creationDate", "filename"]))
        XCTAssertEqual(record["localIdentifier"] as? String, "ABC/L0/001")
        XCTAssertEqual(record["cloudIdentifier"] as? String, "opaque-cloud-archive")
        XCTAssertEqual(record["mediaType"] as? String, "image")
        XCTAssertEqual(record["creationDate"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(record["filename"] as? String, asset.filename)
    }

    func testUnavailableMetadataIsExplicitNull() throws {
        let asset = AssetInventory(localIdentifier: "id", mediaType: "unknown", creationDate: nil, filename: nil)
        let json = try InventoryJSON.encode([asset], source: source)
        let records = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["assets"] as? [[String: Any]])
        XCTAssertTrue(records[0]["cloudIdentifier"] is NSNull)
        XCTAssertTrue(records[0]["creationDate"] is NSNull)
        XCTAssertTrue(records[0]["filename"] is NSNull)
    }

    func testSummaryCountsAllMediaTypesAndMissingCloudIdentifiers() {
        let assets = [
            AssetInventory(localIdentifier: "1", cloudIdentifier: "cloud", mediaType: "image", creationDate: nil, filename: nil),
            AssetInventory(localIdentifier: "2", mediaType: "video", creationDate: nil, filename: nil),
            AssetInventory(localIdentifier: "3", mediaType: "audio", creationDate: nil, filename: nil),
            AssetInventory(localIdentifier: "4", mediaType: "unknown", creationDate: nil, filename: nil)
        ]
        let summary = ScanSummary(assets: assets)
        XCTAssertEqual(summary.totalAssets, 4)
        XCTAssertEqual(summary.withCloudIdentifier, 1)
        XCTAssertEqual(summary.withoutCloudIdentifier, 3)
        XCTAssertEqual(summary.images, 1)
        XCTAssertEqual(summary.videos, 1)
        let empty = ScanSummary(assets: [])
        XCTAssertEqual(empty.totalAssets, 0)
        XCTAssertEqual(empty.withCloudIdentifier, 0)
        XCTAssertEqual(empty.withoutCloudIdentifier, 0)
        XCTAssertEqual(empty.images, 0)
        XCTAssertEqual(empty.videos, 0)
    }

    func testEmptyLibraryProducesEmptyArray() throws {
        let json = try InventoryJSON.encode([], source: source)
        let records = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["assets"] as? [Any])
        XCTAssertTrue(records.isEmpty)
    }

    func testSelectedCloudIdentityMatchesScannerStableIdentity() throws {
        let source = PhotoSource(sourceId: UUID(), name: "Test")
        let asset = AssetInventory(localIdentifier: "local", cloudIdentifier: "cloud-id", mediaType: "image", creationDate: nil, filename: "test.jpg")
        let json = try InventoryJSON.encode([asset], source: source)
        let filtered = try InventoryJSON.filteringByStableIdentity(json, allowed: ["cloud:cloud-id"])
        XCTAssertEqual(filtered.summary.totalAssets, 1)
    }

    func testAlbumDocumentEncodeDecodeRoundTrip() throws {
        let album = AlbumInventory(localIdentifier: "folder/album", cloudIdentifier: nil, name: "Test", kind: "album", parentLocalIdentifier: "folder", assetIdentities: ["asset/1"])
        let document = AlbumInventoryDocument(source: source, albums: [album])
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(AlbumInventoryDocument.self, from: data), document)
    }

    func testAlbumResponseUsesIntegerIds() throws {
        struct Response: Decodable { let count: Int; let albums: [Int] }
        let response = try JSONDecoder().decode(Response.self, from: Data(#"{"count":1,"albums":[42]}"#.utf8))
        XCTAssertEqual(response.albums, [42])
    }
}
