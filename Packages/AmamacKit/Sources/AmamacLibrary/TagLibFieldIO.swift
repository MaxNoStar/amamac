import AmamacTagLib
import Foundation

/// Fields SFBAudioEngine can't keep exactly, through the TagLib helper (`AmamacTagLib`): the
/// release date in ID3v2 tags (it drops dates that aren't full timestamps), the original date in
/// ID3v2 and MP4 tags, and the ISRC in MP4 tags. Xiph and APE tags keep all of these as they are.
enum TagLibFieldIO {
    struct Values: Sendable, Equatable {
        var releaseDate: String?
        var originalDate: String?
        var isrc: String?
    }

    static func format(of url: URL) -> TagLibFormat { TagLibFields.format(of: url) }

    /// The stored values; nil for other formats or an unreadable file.
    static func read(_ url: URL) -> Values? {
        guard format(of: url) != .other, let values = try? TagLibFields.read(from: url) else { return nil }
        return Values(releaseDate: values.releaseDate, originalDate: values.originalDate, isrc: values.isrc)
    }

    /// nil leaves a field as it is, "" removes it, anything else is stored exactly.
    static func write(releaseDate: String? = nil, originalDate: String? = nil, isrc: String? = nil, to url: URL) throws {
        try TagLibFields.write(releaseDate: releaseDate, originalDate: originalDate, isrc: isrc, to: url)
    }
}
