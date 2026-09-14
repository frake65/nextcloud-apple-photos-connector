import Foundation
import Combine

public struct DebugLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let category: String
    public let message: String
    public init(id: UUID = UUID(), date: Date = Date(), category: String, message: String) {
        self.id = id; self.date = date; self.category = category; self.message = message
    }
}

@MainActor public final class DebugLogStore: ObservableObject {
    public static let shared = DebugLogStore()
    public static let maxEntries = 5000
    @Published public private(set) var entries: [DebugLogEntry] = []
    private init() {}
    public func append(_ message: String, category: String? = nil) {
        let sanitized = Self.sanitize(message)
        guard !sanitized.isEmpty else { return }
        let entry = DebugLogEntry(category: category ?? Self.category(for: sanitized), message: sanitized)
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }
    public func clear() { entries.removeAll(keepingCapacity: true) }
    public var text: String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { "\(formatter.string(from: $0.date))  \($0.category.uppercased())  \($0.message)" }.joined(separator: "\n")
    }
    private static func category(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("failure") { return "error" }
        if lower.contains("inventory") { return "inventory" }
        if lower.contains("mkcol") || lower.contains("webdav") || lower.contains("put") { return "webdav" }
        if lower.contains("upload") { return "upload" }
        if lower.contains("login") || lower.contains("connection") { return "connection" }
        if lower.contains("album") { return "album" }
        if lower.contains("photokit") || lower.contains("photo") { return "photokit" }
        return "system"
    }
    private static func sanitize(_ value: String) -> String {
        var result = value
        let patterns = ["(?i)authorization\\s*[:=]\\s*[^\\s]+", "(?i)(app[- ]?password|password|token|cookie)\\s*[:=]\\s*[^\\s]+"]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "$1=<redacted>", options: .regularExpression) }
        return result
    }
}
