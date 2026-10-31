import AmamacModels
import Foundation
import GRDB

extension Track: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension TrackStatistics: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "statistics"
}

public struct CollectionFolder: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "collection_folder"
    public var id: Int64?
    public var path: String
    public var recursive: Bool
    public var watch: Bool

    public init(id: Int64? = nil, path: String, recursive: Bool = true, watch: Bool = true) {
        self.id = id
        self.path = path
        self.recursive = recursive
        self.watch = watch
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct AlbumCoverRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "album_cover"
    public enum Source: String, Codable, Sendable { case custom, fetched, unset }
    public var albumKey: String
    public var source: Source
    public var path: String?

    public init(albumKey: String, source: Source, path: String?) {
        self.albumKey = albumKey
        self.source = source
        self.path = path
    }
}

public struct LabelRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "label"
    public var id: Int64?
    public var name: String
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A track together with its statistics, as returned by collection queries.
public struct TrackWithStatistics: Sendable, Hashable, FetchableRecord {
    public var track: Track
    public var statistics: TrackStatistics?

    public init(track: Track, statistics: TrackStatistics?) {
        self.track = track
        self.statistics = statistics
    }

    public init(row: Row) throws {
        track = try Track(row: row)
        if let trackId: Int64 = row["s_trackId"] {
            statistics = TrackStatistics(trackId: trackId, rating: row["s_rating"] ?? 0, score: row["s_score"] ?? 0,
                                         playCount: row["s_playCount"] ?? 0, firstPlayed: row["s_firstPlayed"],
                                         lastPlayed: row["s_lastPlayed"])
        } else {
            statistics = nil
        }
    }

    /// Columns to select alongside `t.*` for `init(row:)`.
    public static let statisticsColumns = "s.trackId AS s_trackId, s.rating AS s_rating, s.score AS s_score, s.playCount AS s_playCount, s.firstPlayed AS s_firstPlayed, s.lastPlayed AS s_lastPlayed"

    public func playlistItem(source: PlaylistItemSource = .collection) -> PlaylistItem {
        PlaylistItem(track: track, statistics: statistics, source: source)
    }
}

/// Key/value app state (current playlist session etc.).
public struct AppStateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "app_state"
    public var key: String
    public var value: Data?

    package init(key: String, value: Data?) {
        self.key = key
        self.value = value
    }
}
