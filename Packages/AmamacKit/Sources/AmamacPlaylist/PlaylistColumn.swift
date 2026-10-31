import AmamacBase
import AmamacModels
import Foundation

/// Playlist layout tokens / columns (Amarok's playlist column set).
public enum PlaylistColumn: String, CaseIterable, Sendable, Codable {
    case album, albumArtist, artist, bitrate, bpm, comment, composer, coverImage, directory, discNumber
    case divider, fileName, fileSize, genre, groupLength, groupTracks, labels, lastPlayed, length
    case playCount, rating, sampleRate, score, source, title, titleWithTrackNumber, trackNumber, type, year

    public var displayName: String {
        switch self {
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .artist: "Artist"
        case .bitrate: "Bitrate"
        case .bpm: "Bpm"
        case .comment: "Comment"
        case .composer: "Composer"
        case .coverImage: "Cover Image"
        case .directory: "Directory"
        case .discNumber: "Disc Number"
        case .divider: "Divider"
        case .fileName: "File Name"
        case .fileSize: "File Size"
        case .genre: "Genre"
        case .groupLength: "Group Length"
        case .groupTracks: "Group Tracks"
        case .labels: "Labels"
        case .lastPlayed: "Last Played"
        case .length: "Length"
        case .playCount: "Play Count"
        case .rating: "Rating"
        case .sampleRate: "Sample Rate"
        case .score: "Score"
        case .source: "Source"
        case .title: "Title"
        case .titleWithTrackNumber: "Title (with track number)"
        case .trackNumber: "Track Number"
        case .type: "Type"
        case .year: "Year"
        }
    }

    /// Columns offered by the sort breadcrumb.
    public static let sortable: [PlaylistColumn] = [
        .album, .albumArtist, .artist, .bitrate, .bpm, .comment, .composer, .directory, .discNumber,
        .fileName, .fileSize, .genre, .lastPlayed, .length, .playCount, .rating, .sampleRate, .score,
        .source, .title, .trackNumber, .type, .year,
    ]

    /// Text shown for an item (used by layouts, copy, and search).
    public func text(for item: PlaylistItem) -> String {
        let t = item.track
        switch self {
        case .album: return t.album
        case .albumArtist: return t.effectiveAlbumArtist
        case .artist: return t.artist
        case .bitrate: return t.bitrate > 0 ? "\(t.bitrate) kbps" : ""
        case .bpm: return t.bpm > 0 ? "\(t.bpm)" : ""
        case .comment: return t.comment
        case .composer: return t.composer
        case .coverImage, .divider: return ""
        case .directory: return item.url.isFileURL ? t.directory : ""
        case .discNumber: return t.discNumber > 0 ? "\(t.discNumber)" : ""
        case .fileName: return item.url.isFileURL ? t.fileName : item.url.absoluteString
        case .fileSize: return t.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: t.fileSize, countStyle: .file) : ""
        case .genre: return t.genre
        case .groupLength, .groupTracks: return ""
        case .labels: return ""
        case .lastPlayed: return item.statistics?.lastPlayed.map { TimeFormatting.relative($0) } ?? "Never"
        case .length: return item.isStream && t.durationMs == 0 ? "" : TimeFormatting.durationMs(t.durationMs)
        case .playCount: return "\(item.statistics?.playCount ?? 0)"
        case .rating: return ""
        case .sampleRate: return t.sampleRate > 0 ? "\(t.sampleRate) Hz" : ""
        case .score: return "\(Int((item.statistics?.score ?? 0).rounded()))"
        case .source: return item.source.rawValue.capitalized
        case .title: return item.streamTitle ?? t.displayTitle
        case .titleWithTrackNumber:
            let title = item.streamTitle ?? t.displayTitle
            return t.trackNumber > 0 ? String(format: "%02d - %@", t.trackNumber, title) : title
        case .trackNumber: return t.trackNumber > 0 ? "\(t.trackNumber)" : ""
        case .type: return t.format.uppercased()
        case .year: return t.year > 0 ? "\(t.year)" : ""
        }
    }

    /// Ordering for sorting.
    func compare(_ a: PlaylistItem, _ b: PlaylistItem) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
        let x = a.track, y = b.track
        switch self {
        case .album: return cmp(x.albumSort, y.albumSort)
        case .albumArtist: return cmp(x.albumArtistSort, y.albumArtistSort)
        case .artist: return cmp(x.artistSort, y.artistSort)
        case .bitrate: return cmp(x.bitrate, y.bitrate)
        case .bpm: return cmp(x.bpm, y.bpm)
        case .comment: return cmp(TextFolding.fold(x.comment), TextFolding.fold(y.comment))
        case .composer: return cmp(TextFolding.sortKey(x.composer), TextFolding.sortKey(y.composer))
        case .directory: return cmp(x.directory, y.directory)
        case .discNumber: return cmp(x.discNumber, y.discNumber)
        case .fileName: return cmp(x.fileName.lowercased(), y.fileName.lowercased())
        case .fileSize: return cmp(x.fileSize, y.fileSize)
        case .genre: return cmp(TextFolding.fold(x.genre), TextFolding.fold(y.genre))
        case .lastPlayed:
            return cmp(a.statistics?.lastPlayed ?? .distantPast, b.statistics?.lastPlayed ?? .distantPast)
        case .length: return cmp(x.durationMs, y.durationMs)
        case .playCount: return cmp(a.statistics?.playCount ?? 0, b.statistics?.playCount ?? 0)
        case .rating: return cmp(a.statistics?.rating ?? 0, b.statistics?.rating ?? 0)
        case .sampleRate: return cmp(x.sampleRate, y.sampleRate)
        case .score: return cmp(a.statistics?.score ?? 0, b.statistics?.score ?? 0)
        case .source: return cmp(a.source.rawValue, b.source.rawValue)
        case .title, .titleWithTrackNumber: return cmp(x.titleSort, y.titleSort)
        case .trackNumber: return cmp(x.trackNumber, y.trackNumber)
        case .type: return cmp(x.format, y.format)
        case .year: return cmp(x.year, y.year)
        default: return .orderedSame
        }
    }
}

public struct PlaylistSortLevel: Sendable, Codable, Hashable {
    /// `nil` column means "Shuffle".
    public var column: PlaylistColumn?
    public var ascending: Bool

    public init(column: PlaylistColumn?, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    public static let shuffle = PlaylistSortLevel(column: nil)
    public var displayName: String { column?.displayName ?? "Shuffle" }
}

/// How the playlist groups consecutive rows (Amarok's "Group by").
public enum PlaylistGrouping: String, CaseIterable, Sendable, Codable {
    case album, artist, composer, directory, genre, rating, source, year, none

    public var displayName: String {
        switch self {
        case .none: "None"
        default: rawValue.capitalized
        }
    }

    public func key(for item: PlaylistItem) -> String {
        let t = item.track
        switch self {
        case .album: return item.isStream ? "stream:" + item.url.absoluteString : t.albumKey
        case .artist: return TextFolding.fold(t.artist)
        case .composer: return TextFolding.fold(t.composer)
        case .directory: return t.directory
        case .genre: return TextFolding.fold(t.genre)
        case .rating: return "\(item.statistics?.rating ?? 0)"
        case .source: return item.source.rawValue
        case .year: return "\(t.year)"
        case .none: return item.id.description
        }
    }
}

/// Fields the progressive playlist search looks at (Search Preferences menu).
public struct PlaylistSearchFields: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let tracks = PlaylistSearchFields(rawValue: 1 << 0)
    public static let albums = PlaylistSearchFields(rawValue: 1 << 1)
    public static let artists = PlaylistSearchFields(rawValue: 1 << 2)
    public static let genre = PlaylistSearchFields(rawValue: 1 << 3)
    public static let composers = PlaylistSearchFields(rawValue: 1 << 4)
    public static let rating = PlaylistSearchFields(rawValue: 1 << 5)
    public static let years = PlaylistSearchFields(rawValue: 1 << 6)

    public static let `default`: PlaylistSearchFields = [.tracks, .albums, .artists]
}

public struct PlaylistSearch: Sendable, Equatable {
    public var text: String
    public var fields: PlaylistSearchFields

    public init(text: String, fields: PlaylistSearchFields = .default) {
        self.text = text
        self.fields = fields
    }

    public func matches(_ item: PlaylistItem) -> Bool {
        let needle = TextFolding.fold(text.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return true }
        let t = item.track
        func has(_ s: String) -> Bool { TextFolding.fold(s).contains(needle) }
        if fields.contains(.tracks), has(item.streamTitle ?? t.displayTitle) { return true }
        if fields.contains(.albums), has(t.album) { return true }
        if fields.contains(.artists), has(t.artist) || has(t.albumArtist) { return true }
        if fields.contains(.genre), has(t.genre) { return true }
        if fields.contains(.composers), has(t.composer) { return true }
        if fields.contains(.rating), let stars = Double(needle), Double(item.statistics?.rating ?? 0) == stars * 2 { return true }
        if fields.contains(.years), t.year > 0, String(t.year).contains(needle) { return true }
        return false
    }
}
