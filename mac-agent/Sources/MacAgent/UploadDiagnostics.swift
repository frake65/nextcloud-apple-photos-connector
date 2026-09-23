import Foundation
import Darwin

enum UploadDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["APC_UPLOAD_DIAGNOSTICS"] == "1"
    static func log(_ phase: String, bytes: Int64? = nil, count: Int? = nil, retry: Int? = nil, status: Int? = nil) {
        guard enabled else { return }
        var fields = ["phase=\(phase)", "rssBytes=\(rssBytes())"]
        if let bytes { fields.append("bytes=\(bytes)") }; if let count { fields.append("count=\(count)") }
        if let retry { fields.append("retry=\(retry)") }; if let status { fields.append("httpStatus=\(status)") }
        print("APC_UPLOAD_DIAGNOSTIC " + fields.joined(separator: " "))
    }
    private static func rssBytes() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
