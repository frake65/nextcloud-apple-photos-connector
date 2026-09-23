import Foundation
import CryptoKit

public struct ContentIdentity: Codable, Sendable, Equatable {
    public enum ReadDiagnosticEvent: Sendable {
        case begin
        case progress(bytes: Int64)
        case end
    }

    public let bytes: Int64
    public let sha256: String

    /// Bounded memory even for large original videos; counts the actual hashed bytes.
    public static func read(_ url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            hash.update(data: chunk)
            bytes += Int64(chunk.count)
            return true
        }) {}
        return Self(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    #if DEBUG
    public static func read(_ url: URL, diagnostics: (@Sendable (ReadDiagnosticEvent) -> Void)?) throws -> Self {
        diagnostics?(.begin)
        defer { diagnostics?(.end) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        var nextProgress = Int64(64 * 1024 * 1024)
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            hash.update(data: chunk)
            bytes += Int64(chunk.count)
            if bytes >= nextProgress {
                diagnostics?(.progress(bytes: bytes))
                repeat { nextProgress += Int64(64 * 1024 * 1024) } while nextProgress <= bytes
            }
            return true
        }) {}
        return Self(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    #endif
}

public struct UploadTarget: Decodable, Sendable {
    public let assetId: String
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let state: String
    public init(assetId: String, path: String, identity: ContentIdentity, state: String) {
        self.assetId = assetId; self.path = path; self.bytes = identity.bytes; self.sha256 = identity.sha256; self.state = state
    }
}

public protocol UploadTargetProvider: Sendable {
    /// Must persist the path before returning missing, and verify all bytes before returning present.
    func prepare(identity: ContentIdentity) async throws -> UploadTarget
}
