import Foundation

/// A level of the collection tree (Amarok's "Group By" categories).
public enum CollectionLevel: String, CaseIterable, Sendable, Codable {
    case albumArtist, artist, album, genre, composer, label, year

    public var displayName: String {
        switch self {
        case .albumArtist: "Album Artist"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .composer: "Composer"
        case .label: "Label"
        case .year: "Year"
        }
    }

    /// SQL expression for the display value of this level.
    var valueExpression: String {
        switch self {
        case .albumArtist: "(CASE WHEN t.compilation THEN '\(TrackText.variousArtists)' WHEN t.albumArtist = '' THEN t.artist ELSE t.albumArtist END)"
        case .artist: "t.artist"
        case .album: "t.album"
        case .genre: "t.genre"
        case .composer: "t.composer"
        case .label: "COALESCE(l.name, '')"
        case .year: "t.year"
        }
    }

    /// SQL expression identifying a node at this level (pre-folded, indexed columns).
    var keyExpression: String {
        switch self {
        case .albumArtist: "t.albumArtistKey"
        case .artist: "t.artistKey"
        case .album: "t.albumKey"
        case .genre: "t.genreKey"
        case .composer: "t.composerKey"
        case .year: "t.year"
        case .label: "amamac_fold(COALESCE(l.name, ''))"
        }
    }

    public func emptyName() -> String {
        switch self {
        case .albumArtist, .artist: TrackText.unknownArtist
        case .album: TrackText.unknownAlbum
        case .genre: TrackText.unknownGenre
        case .composer: TrackText.unknownComposer
        case .label: "No Label"
        case .year: "Unknown Year"
        }
    }
}

/// Collection browser grouping presets (Sort Options menu).
public struct CollectionGrouping: Sendable, Codable, Hashable {
    public var levels: [CollectionLevel]

    public init(_ levels: [CollectionLevel]) { self.levels = Array(levels.prefix(3)) }

    public static let albumArtistAlbum = CollectionGrouping([.albumArtist, .album])
    public static let albumArtist = CollectionGrouping([.album, .artist])
    public static let genreAlbumArtist = CollectionGrouping([.genre, .albumArtist])
    public static let genreAlbumArtistAlbum = CollectionGrouping([.genre, .albumArtist, .album])

    public static let presets: [(String, CollectionGrouping)] = [
        ("Album Artist / Album", .albumArtistAlbum),
        ("Album / Artist", .albumArtist),
        ("Genre / Album Artist", .genreAlbumArtist),
        ("Genre / Album Artist / Album", .genreAlbumArtistAlbum),
    ]

    public var displayName: String { levels.map(\.displayName).joined(separator: " / ") }
}

/// Restricts a query to one node of a level.
public struct CollectionConstraint: Sendable, Hashable, Codable {
    public var level: CollectionLevel
    public var key: String

    public init(level: CollectionLevel, key: String) {
        self.level = level
        self.key = key
    }
}

/// A non-leaf node in the collection tree.
public struct CollectionGroup: Sendable, Hashable, Identifiable {
    public var level: CollectionLevel
    public var key: String
    public var name: String
    public var trackCount: Int
    /// For album nodes: the release year, album key and the album's artist.
    public var year: Int
    public var albumKey: String?
    public var albumArtist: String?
    public var isCompilation: Bool

    public var id: String { level.rawValue + "\u{1F}" + key }
    public var displayName: String { name.isEmpty ? level.emptyName() : name }
}
