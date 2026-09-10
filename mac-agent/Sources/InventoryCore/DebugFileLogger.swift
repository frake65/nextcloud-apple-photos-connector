import Foundation

/// Small, release-safe persistent logger used only when the user enables DEBUG.
/// The default location is ~/Library/Logs/Apple Photos Connector/debug.log.
public final class DebugFileLogger: @unchecked Sendable {
    public let fileURL: URL
    private let enabled: Bool
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(enabled: Bool, fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.enabled = enabled
        self.fileManager = fileManager
        let library = baseURL ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.fileURL = library.appendingPathComponent("Logs/Apple Photos Connector/debug.log")
        guard enabled else { return }
        ensureFile()
        log("debug.logger.initialized")
    }

    public func log(_ event: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        ensureFile()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        guard let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func ensureFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }
}
