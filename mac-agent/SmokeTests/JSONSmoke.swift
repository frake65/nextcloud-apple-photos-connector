import Foundation

@main
struct JSONSmoke {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Smoke test error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--source" {
            let store = PhotoSourceStore(fileURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            let source = try store.loadOrCreate()
            let reloaded = try store.loadOrCreate(name: "Ignored on reload")
            precondition(reloaded == source)
            print(try InventoryJSON.encode([], source: source))
            return
        }
        let source = PhotoSource(name: "Test Source")
        precondition(CloudIdentifierCodec.encode(nil) == nil)
        precondition(CloudIdentifierCodec.decode(nil) == nil)
        precondition(CloudIdentifierCodec.decode("") == nil)
        let name = "Urlaub \"Köln\"\n.heic"
        let asset = AssetInventory(localIdentifier: "ABC/L0/001", cloudIdentifier: "opaque-cloud-archive\"\n", mediaType: "image", creationDate: Date(timeIntervalSince1970: 0), filename: name)
        let encoded = try InventoryJSON.encode([asset], source: source)
        let document = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
        precondition(Set(document.keys) == Set(["source", "assets"]))
        let sourceJSON = document["source"] as! [String: Any]
        precondition(Set(sourceJSON.keys) == Set(["sourceId", "name"]))
        precondition(sourceJSON["sourceId"] as? String == source.sourceId.uuidString)
        precondition(sourceJSON["name"] as? String == source.name)
        let records = document["assets"] as! [[String: Any]]
        let record = records[0]
        precondition(Set(record.keys) == Set(["localIdentifier", "cloudIdentifier", "mediaType", "creationDate", "filename"]))
        precondition(record["localIdentifier"] as? String == "ABC/L0/001")
        precondition(record["cloudIdentifier"] as? String == asset.cloudIdentifier)
        precondition(record["mediaType"] as? String == "image")
        precondition(record["creationDate"] as? String == "1970-01-01T00:00:00Z")
        precondition(record["filename"] as? String == name)
        let missing = try InventoryJSON.encode([AssetInventory(localIdentifier: "id", mediaType: "unknown", creationDate: nil, filename: nil)], source: source)
        let nulls = (try JSONSerialization.jsonObject(with: Data(missing.utf8)) as! [String: Any])["assets"] as! [[String: Any]]
        precondition(nulls[0]["cloudIdentifier"] is NSNull)
        precondition(nulls[0]["creationDate"] is NSNull && nulls[0]["filename"] is NSNull)
        let empty = try InventoryJSON.encode([], source: source)
        let emptyRecords = (try JSONSerialization.jsonObject(with: Data(empty.utf8)) as! [String: Any])["assets"] as! [Any]
        precondition(emptyRecords.isEmpty)
        let summary = ScanSummary(assets: [asset,
            AssetInventory(localIdentifier: "video", mediaType: "video", creationDate: nil, filename: nil),
            AssetInventory(localIdentifier: "audio", mediaType: "audio", creationDate: nil, filename: nil),
            AssetInventory(localIdentifier: "unknown", mediaType: "unknown", creationDate: nil, filename: nil)])
        precondition(summary.totalAssets == 4 && summary.withCloudIdentifier == 1 && summary.withoutCloudIdentifier == 3)
        precondition(summary.images == 1 && summary.videos == 1)
        let emptySummary = ScanSummary(assets: [])
        precondition(emptySummary.totalAssets == 0 && emptySummary.withCloudIdentifier == 0 && emptySummary.withoutCloudIdentifier == 0)
        precondition(emptySummary.images == 0 && emptySummary.videos == 0)
        print("PASS: metadata round-trip, null metadata, empty inventory, scan summaries, codec nil/empty input")
    }
}
