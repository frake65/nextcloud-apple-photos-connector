import Foundation

public struct AlbumInventory: Codable, Sendable, Equatable {
    public var localIdentifier: String
    public var cloudIdentifier: String?
    public var name: String
    public var kind: String
    public var parentLocalIdentifier: String?
    public var assetIdentities: [String]
    public init(localIdentifier: String, cloudIdentifier: String? = nil, name: String, kind: String = "album", parentLocalIdentifier: String? = nil, assetIdentities: [String] = []) { self.localIdentifier=localIdentifier; self.cloudIdentifier=cloudIdentifier; self.name=name; self.kind=kind; self.parentLocalIdentifier=parentLocalIdentifier; self.assetIdentities=assetIdentities }
    private enum CodingKeys: String, CodingKey { case localIdentifier, cloudIdentifier, name, kind, parentLocalIdentifier, assetIdentities, assets }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localIdentifier = try c.decode(String.self, forKey: .localIdentifier)
        cloudIdentifier = try c.decodeIfPresent(String.self, forKey: .cloudIdentifier)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        parentLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .parentLocalIdentifier)
        assetIdentities = try c.decodeIfPresent([String].self, forKey: .assetIdentities)
            ?? c.decodeIfPresent([String].self, forKey: .assets) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(localIdentifier, forKey: .localIdentifier)
        try c.encodeIfPresent(cloudIdentifier, forKey: .cloudIdentifier)
        try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(parentLocalIdentifier, forKey: .parentLocalIdentifier)
        try c.encode(assetIdentities, forKey: .assetIdentities)
        // Preserve the historical server field as an additive compatibility
        // alias. Older deployed app versions use `assets` for memberships.
        try c.encode(assetIdentities, forKey: .assets)
    }
}

public struct AlbumInventoryDocument: Codable, Sendable, Equatable {
    public let version: Int
    public let source: PhotoSource
    public let albums: [AlbumInventory]
    public init(source: PhotoSource, albums: [AlbumInventory], version: Int = 1) { self.version=version; self.source=source; self.albums=albums }
}
