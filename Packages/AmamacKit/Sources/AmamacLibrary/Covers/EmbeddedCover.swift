import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images for embedding as a front cover from the tag editor: JPEG and PNG stay as they are,
/// any other image type ImageIO reads is converted to PNG.
public enum EmbeddedCover {
    public enum Problem: LocalizedError, Equatable {
        case tooLarge
        case notAnImage

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The image is larger than 20 MB."
            case .notAnImage: "The file is not an image Amamac can read."
            }
        }
    }

    /// Largest image accepted, before and after conversion.
    public static let maxBytes = 20 * 1024 * 1024

    /// The data to embed.
    public static func prepared(_ data: Data) throws(Problem) -> Data {
        guard data.count <= maxBytes else { throw .tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil,
              CGImageSourceGetCount(source) > 0 else { throw .notAnImage }
        if type.conforms(to: .jpeg) || type.conforms(to: .png) { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw .notAnImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw .notAnImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .notAnImage }
        guard out.length <= maxBytes else { throw .tooLarge }
        return out as Data
    }

    /// Whether the file at `url` is small enough to try (checked before reading it).
    public static func fileIsSmallEnough(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return false }
        return size <= maxBytes
    }
}
