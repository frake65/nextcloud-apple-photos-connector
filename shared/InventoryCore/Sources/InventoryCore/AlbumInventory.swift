import Foundation

public struct AlbumInventory: Codable, Sendable, Equatable {
    public var localIdentifier: String
    public var cloudIdentifier: String?
    public var name: String
    public var kind: String
    public var parentLocalIdentifier: String?
    public var assetIdentities: [String]
    public init(localIdentifier: String, cloudIdentifier: String? = nil, name: String, kind: String = "album", parentLocalIdentifier: String? = nil, assetIdentities: [String] = []) { self.localIdentifier=localIdentifier; self.cloudIdentifier=cloudIdentifier; self.name=name; self.kind=kind; self.parentLocalIdentifier=parentLocalIdentifier; self.assetIdentities=assetIdentities }
}

public struct AlbumInventoryDocument: Codable, Sendable, Equatable {
    public let version: Int
    public let source: PhotoSource
    public let albums: [AlbumInventory]
    public init(source: PhotoSource, albums: [AlbumInventory], version: Int = 1) { self.version=version; self.source=source; self.albums=albums }
}
