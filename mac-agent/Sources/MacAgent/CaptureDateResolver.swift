import Foundation
import ImageIO
import AVFoundation

/// Resolves the date used for the physical YYYY/MM path and records its origin.
struct CaptureDateResolution: Sendable { let date: Date; let origin: String }

struct CaptureDateResolver {
    func resolve(file: URL, assetDate: Date?, fallback: Date = Date()) async -> CaptureDateResolution {
        if let date = imageDate(file) { return CaptureDateResolution(date: date, origin: "exif") }
        if let date = await videoDate(file) { return CaptureDateResolution(date: date, origin: "exif") }
        if let assetDate { return CaptureDateResolution(date: assetDate, origin: "phasset") }
        return CaptureDateResolution(date: fallback, origin: "fallback")
    }

    private func imageDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let xmp = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        for value in [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized], xmp?[kCGImagePropertyIPTCDateCreated]] {
            if let string = value as? String, let date = parse(string) { return date }
        }
        return nil
    }

    private func videoDate(_ url: URL) async -> Date? {
        let asset = AVAsset(url: url)
        let keys = [AVMetadataKey.commonKeyCreationDate.rawValue, "com.apple.quicktime.creationdate"]
        for key in keys {
            if let item = try? await asset.load(.metadata).first(where: { $0.commonKey?.rawValue == key }), let value = try? await item.load(.stringValue), let date = parse(value) { return date }
        }
        return nil
    }

    private func parse(_ value: String) -> Date? {
        let formats = ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX"]
        for format in formats {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format; formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
