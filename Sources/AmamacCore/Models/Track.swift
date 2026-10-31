import Foundation

/// A track in the local collection. Missing text tags are stored as empty strings and missing
/// numbers as 0 so grouping and sorting queries stay simple.
public struct Track: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var path: String
    public var folderId: Int64?
    public var uniqueId: String

    public var title: String
    public var titleSort: String
    public var artist: String
    public var artistSort: String
    public var albumArtist: String
    public var albumArtistSort: String
    public var album: String
    public var albumSort: String
    public var albumKey: String
    public var composer: String
    public var genre: String
    public var year: Int
    public var trackNumber: Int
    public var trackTotal: Int
    public var discNumber: Int
    public var discTotal: Int
    public var bpm: Int
    public var comment: String
    public var compilation: Bool
    public var mbReleaseId: String
    public var mbRecordingId: String

    public var durationMs: Int
    public var format: String
    public var bitrate: Int
    public var sampleRate: Int
    public var channels: Int
    public var fileSize: Int64
    public var mtime: Date
    public var dateAdded: Date

    public var rgTrackGain: Double?
    public var rgTrackPeak: Double?
    public var rgAlbumGain: Double?
    public var rgAlbumPeak: Double?
    public var hasEmbeddedArt: Bool
    public var searchFolded: String
    /// Folded grouping keys (indexed) so collection queries don't fold per row.
    public var artistKey: String = ""
    public var albumArtistKey: String = ""
    public var genreKey: String = ""
    public var composerKey: String = ""

    public init(id: Int64? = nil, path: String, folderId: Int64? = nil, uniqueId: String = "",
                title: String = "", titleSort: String = "", artist: String = "", artistSort: String = "",
                albumArtist: String = "", albumArtistSort: String = "", album: String = "",
                albumSort: String = "", albumKey: String = "", composer: String = "", genre: String = "",
                year: Int = 0, trackNumber: Int = 0, trackTotal: Int = 0, discNumber: Int = 0,
                discTotal: Int = 0, bpm: Int = 0, comment: String = "", compilation: Bool = false,
                mbReleaseId: String = "", mbRecordingId: String = "", durationMs: Int = 0,
                format: String = "", bitrate: Int = 0, sampleRate: Int = 0, channels: Int = 0,
                fileSize: Int64 = 0, mtime: Date = Date(timeIntervalSince1970: 0), dateAdded: Date = Date(),
                rgTrackGain: Double? = nil, rgTrackPeak: Double? = nil, rgAlbumGain: Double? = nil,
                rgAlbumPeak: Double? = nil, hasEmbeddedArt: Bool = false, searchFolded: String = "") {
        self.id = id
        self.path = path
        self.folderId = folderId
        self.uniqueId = uniqueId
        self.title = title
        self.titleSort = titleSort
        self.artist = artist
        self.artistSort = artistSort
        self.albumArtist = albumArtist
        self.albumArtistSort = albumArtistSort
        self.album = album
        self.albumSort = albumSort
        self.albumKey = albumKey
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.bpm = bpm
        self.comment = comment
        self.compilation = compilation
        self.mbReleaseId = mbReleaseId
        self.mbRecordingId = mbRecordingId
        self.durationMs = durationMs
        self.format = format
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileSize = fileSize
        self.mtime = mtime
        self.dateAdded = dateAdded
        self.rgTrackGain = rgTrackGain
        self.rgTrackPeak = rgTrackPeak
        self.rgAlbumGain = rgAlbumGain
        self.rgAlbumPeak = rgAlbumPeak
        self.hasEmbeddedArt = hasEmbeddedArt
        self.searchFolded = searchFolded
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
    public var duration: TimeInterval { TimeInterval(durationMs) / 1000 }

    /// Album artist used for grouping: the explicit album artist, "Various Artists" for
    /// compilations, otherwise the track artist.
    public var effectiveAlbumArtist: String {
        if compilation { return TrackText.variousArtists }
        return albumArtist.isEmpty ? artist : albumArtist
    }

    /// Title for display; falls back to the file name without extension.
    public var displayTitle: String {
        title.isEmpty ? (fileName as NSString).deletingPathExtension : title
    }

    public var displayArtist: String { artist.isEmpty ? TrackText.unknownArtist : artist }
    public var displayAlbum: String { album.isEmpty ? TrackText.unknownAlbum : album }

    /// Recomputes the derived columns (`albumKey`, sort keys, `searchFolded`).
    public mutating func updateDerivedFields() {
        if titleSort.isEmpty { titleSort = TextFolding.sortKey(title) }
        if artistSort.isEmpty { artistSort = TextFolding.sortKey(artist) }
        if albumArtistSort.isEmpty { albumArtistSort = TextFolding.sortKey(effectiveAlbumArtist) }
        if albumSort.isEmpty { albumSort = TextFolding.sortKey(album) }
        albumKey = Track.albumKey(album: album, albumArtist: albumArtist, artist: artist, compilation: compilation)
        artistKey = TextFolding.fold(artist)
        albumArtistKey = TextFolding.fold(effectiveAlbumArtist)
        genreKey = TextFolding.fold(genre)
        composerKey = TextFolding.fold(composer)
        searchFolded = TextFolding.fold([title, artist, albumArtist, album, composer, genre,
                                         year > 0 ? String(year) : "", fileName].joined(separator: "\u{1F}"))
    }

    public static func albumKey(album: String, albumArtist: String, artist: String, compilation: Bool) -> String {
        let owner = compilation ? "#va" : TextFolding.fold(albumArtist.isEmpty ? artist : albumArtist)
        return TextFolding.fold(album) + "\u{1F}" + owner
    }
}

/// Play statistics for a track (Amarok's rating / score / play count model).
public struct TrackStatistics: Codable, Sendable, Hashable {
    public var trackId: Int64
    /// 0...10 (half stars). 0 means unrated.
    public var rating: Int
    /// 0...100
    public var score: Double
    public var playCount: Int
    public var firstPlayed: Date?
    public var lastPlayed: Date?

    public init(trackId: Int64, rating: Int = 0, score: Double = 0, playCount: Int = 0,
                firstPlayed: Date? = nil, lastPlayed: Date? = nil) {
        self.trackId = trackId
        self.rating = rating
        self.score = score
        self.playCount = playCount
        self.firstPlayed = firstPlayed
        self.lastPlayed = lastPlayed
    }
}

public enum TrackText {
    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"
    public static let unknownGenre = "Unknown Genre"
    public static let unknownComposer = "Unknown Composer"
    public static let variousArtists = "Various Artists"
}
