import Foundation
import Darwin

public struct PhotoSource: Codable, Sendable, Equatable {
    public let sourceId: UUID
    public let name: String
    public let createdAt: Date

    public init(sourceId: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.sourceId = sourceId
        self.name = name
        self.createdAt = createdAt
    }
}

/// Local Connector configuration, independent of Photos libraries and devices.
public struct PhotoSourceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func applicationStore() throws -> PhotoSourceStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Apple Photos Connector", isDirectory: true)
        return PhotoSourceStore(fileURL: directory.appendingPathComponent("source.json"))
    }

    public func loadOrCreate(name: String = "Apple Photos") throws -> PhotoSource {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Serialize first creation across processes; readers never see a partial file.
        let descriptor = open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PhotoSource.self, from: Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only absence permits creation. Invalid or unreadable configuration is an error.
            let source = PhotoSource(name: name)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(source)
            try data.write(to: fileURL, options: .atomic)
            // Return exactly the persisted representation, including date precision.
            return try decoder.decode(PhotoSource.self, from: data)
        }
    }
}
