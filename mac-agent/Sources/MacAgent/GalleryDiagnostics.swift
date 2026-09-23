import Foundation
import Darwin

enum GalleryDiagnostics {
    static let noThumbnails = flag("APC_DIAGNOSTIC_NO_THUMBNAILS")
    static let noPhotoKit = flag("APC_DIAGNOSTIC_NO_PHOTOKIT")

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
            || ProcessInfo.processInfo.arguments.contains("--\(name)")
    }

    static func log(_ phase: String, extra: String = "") {
        let rss = memoryBytes()
        let line = "diagnostic.phase=\(phase) rssBytes=\(rss)\(extra.isEmpty ? "" : " \(extra)")"
        GalleryDebug.log(line)
        if noThumbnails || noPhotoKit { print("APC_DIAGNOSTIC \(line)") }
    }

    private static func memoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
