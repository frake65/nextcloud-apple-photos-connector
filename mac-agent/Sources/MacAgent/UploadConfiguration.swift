import Foundation
import InventoryCore

struct UploadConfiguration: Codable, Sendable {
    var baseFolder: String = TargetDirectoryPreferences.defaultPath
    static let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Apple Photos Connector/UploadConfiguration.json")
    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { let value = Self(); try value.save(); return value }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: storeURL))
    }
    func save() throws {
        guard !baseFolder.isEmpty, !baseFolder.hasPrefix("/"), !baseFolder.contains(".."), !baseFolder.contains("\\") else { throw CocoaError(.validationMissingMandatoryProperty) }
        try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.storeURL, options: .atomic)
    }
}
