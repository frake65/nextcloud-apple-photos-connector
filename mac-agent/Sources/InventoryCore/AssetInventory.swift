import Foundation

public struct AssetInventory: Codable, Sendable {
    public let localIdentifier: String
    public var cloudIdentifier: String?
    public let mediaType: String
    public let creationDate: Date?
    public let filename: String?

    public init(localIdentifier: String, cloudIdentifier: String? = nil, mediaType: String, creationDate: Date?, filename: String?) {
        self.localIdentifier = localIdentifier
        self.cloudIdentifier = cloudIdentifier
        self.mediaType = mediaType
        self.creationDate = creationDate
        self.filename = filename
    }

    /// Canonical asset identity used for deduplication. Cloud identifiers are
    /// stable across local PhotoKit identifier changes; localIdentifier is the
    /// deterministic fallback when PhotoKit cannot provide one.
    public var stableIdentity: String {
        cloudIdentifier.map { "cloud:\($0)" } ?? "local:\(localIdentifier)"
    }

    private enum CodingKeys: String, CodingKey {
        case localIdentifier, cloudIdentifier, mediaType, creationDate, filename
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localIdentifier, forKey: .localIdentifier)
        try container.encode(cloudIdentifier, forKey: .cloudIdentifier)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(filename, forKey: .filename)
    }
}

public enum InventoryJSON {
    private struct SourceReference: Codable {
        let sourceId: UUID
        let name: String
    }

    private struct ScanDocument: Codable {
        let source: SourceReference
        let assets: [AssetInventory]
    }

    public static func encode(_ assets: [AssetInventory], source: PhotoSource) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(ScanDocument(source: .init(sourceId: source.sourceId, name: source.name), assets: assets)), as: UTF8.self)
    }

    public static func filtering(_ json: String, allowedLocalIdentifiers: Set<String>) throws -> (json: String, summary: ScanSummary) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScanDocument.self, from: Data(json.utf8))
        var seen = Set<String>()
        let assets = document.assets.filter {
            guard allowedLocalIdentifiers.contains($0.localIdentifier) else { return false }
            return seen.insert($0.stableIdentity).inserted
        }
        return (try encode(assets, source: PhotoSource(sourceId: document.source.sourceId, name: document.source.name)), ScanSummary(assets: assets))
    }

    public static func filteringByStableIdentity(_ json: String, allowed: Set<String>) throws -> (json: String, summary: ScanSummary) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScanDocument.self, from: Data(json.utf8))
        var seen = Set<String>()
        let assets = document.assets.filter { allowed.contains($0.stableIdentity) && seen.insert($0.stableIdentity).inserted }
        return (try encode(assets, source: PhotoSource(sourceId: document.source.sourceId, name: document.source.name)), ScanSummary(assets: assets))
    }
}

public struct ScanSummary: Sendable {
    public let totalAssets: Int
    public let withCloudIdentifier: Int
    public let withoutCloudIdentifier: Int
    public let images: Int
    public let videos: Int

    public init(assets: [AssetInventory]) {
        totalAssets = assets.count
        withCloudIdentifier = assets.filter { $0.cloudIdentifier != nil }.count
        withoutCloudIdentifier = totalAssets - withCloudIdentifier
        images = assets.filter { $0.mediaType == "image" }.count
        videos = assets.filter { $0.mediaType == "video" }.count
    }
}
