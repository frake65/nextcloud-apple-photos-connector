import Foundation

public struct UploadProgressDisplay: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let filename: String?
    public let failed: Bool
    public init(completed: Int, total: Int, filename: String? = nil, failed: Bool = false) {
        self.completed = completed; self.total = total; self.filename = filename; self.failed = failed
    }
    public var fraction: Double { total == 0 ? 1 : min(1, max(0, Double(completed) / Double(total))) }
    public var isComplete: Bool { completed >= total }
}

public enum UploadModalState: Equatable, Sendable {
    case hidden, active, cancelled, completed
}
