import Foundation

/// Values the tag editor can change. `nil` leaves a field untouched; an empty string or 0 clears it.
public struct TagChanges: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var composer: String?
    public var genre: String?
    public var comment: String?
    /// Shorthand for a year-only `releaseDate`; `releaseDate` wins when both are set.
    public var year: Int?
    /// Any text `ReleaseDate` parses, written as ISO at its precision ("1998", "1998-03", "1998-03-12").
    public var releaseDate: String?
    /// Same format as `releaseDate`.
    public var originalDate: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var bpm: Int?
    public var compilation: Bool?
    public var grouping: String?
    public var isrc: String?
    public var titleSort: String?
    public var artistSort: String?
    public var albumArtistSort: String?
    public var albumSort: String?
    /// 0...10; written as FMPS_Rating when "write statistics to file" is enabled.
    public var rating: Int?
    /// Written only by `StatisticsTagWriter`; the tag editor changes play counts in the library alone.
    public var playCount: Int?
    /// Front cover image data; empty `Data` removes embedded art.
    public var frontCover: Data?

    public init() {}

    public var isEmpty: Bool { self == TagChanges() }

    /// The release date to write: `releaseDate`, or `year` as a year-only date.
    var effectiveReleaseDate: String? {
        releaseDate ?? year.map { $0 > 0 ? String(format: "%04d", min($0, 9999)) : "" }
    }
}
