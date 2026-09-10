import Photos

/// PhotoKit's opaque string format is compatible across both API generations.
/// All OS-dependent persistence decisions belong here.
enum CloudIdentifierCodec {
    static func encode(_ identifier: PHCloudIdentifier?) -> String? {
        guard let identifier else { return nil }
        if #available(macOS 15.2, *) {
            return identifier.archivalStringValue
        } else {
            return identifier.stringValue
        }
    }

    static func decode(_ serialized: String?) -> PHCloudIdentifier? {
        guard let serialized, !serialized.isEmpty else { return nil }
        if #available(macOS 15.2, *) {
            return PHCloudIdentifier(archivalStringValue: serialized)
        } else {
            return PHCloudIdentifier(stringValue: serialized)
        }
    }
}
