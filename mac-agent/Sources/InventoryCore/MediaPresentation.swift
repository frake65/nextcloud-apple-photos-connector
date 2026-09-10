import Foundation

/// Presentation-only media helpers. Inventory still retains all media types.
public enum MediaPresentation {
    public static func isVisibleMediaType(_ type: String) -> Bool {
        type == "image" || type == "video"
    }

    public static func durationString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    public static func counts(_ types: [String]) -> (images: Int, videos: Int, audio: Int, visible: Int) {
        let images = types.filter { $0 == "image" }.count
        let videos = types.filter { $0 == "video" }.count
        let audio = types.filter { $0 == "audio" }.count
        return (images, videos, audio, images + videos)
    }
}
