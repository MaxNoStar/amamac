import AmamacDatabase
import AmamacQuery
import Foundation
import GRDB

/// What the generator needs to know about a collection track.
public struct TrackFacts: Sendable, Hashable {
    public var id: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var albumKey: String
    public var discNumber: Int
    public var trackNumber: Int
    public var durationMs: Int
    public var fileSize: Int64

    public init(id: Int64, title: String, artist: String, album: String, albumKey: String, discNumber: Int, trackNumber: Int,
                durationMs: Int, fileSize: Int64) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.durationMs = durationMs
        self.fileSize = fileSize
    }

    var albumOrder: Int { discNumber * 1000 + trackNumber }
}

/// The collection as seen by dynamic playlists and the playlist generator.
public struct TrackUniverse: Sendable {
    public var tracks: [TrackFacts]
    public var byId: [Int64: TrackFacts]
    /// Matching ids for each filter query.
    public var searches: [String: Set<Int64>]

    public init(tracks: [TrackFacts], searches: [String: Set<Int64>]) {
        self.tracks = tracks
        byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.searches = searches
    }

    public static func load(_ database: LibraryDatabase, queries: Set<String>, now: Date = Date()) async throws -> TrackUniverse {
        try await database.writer.read { db in
            let tracks = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, album, albumKey, discNumber, trackNumber, durationMs, fileSize FROM track
                """).map { row in
                TrackFacts(id: row["id"], title: row["title"], artist: row["artist"], album: row["album"], albumKey: row["albumKey"],
                           discNumber: row["discNumber"], trackNumber: row["trackNumber"], durationMs: row["durationMs"],
                           fileSize: row["fileSize"])
            }
            var searches: [String: Set<Int64>] = [:]
            for query in queries {
                let filter = CollectionQuery.parse(query)
                searches[query] = Set(try CollectionQueries.tracks(db, constraints: [], filter: filter, now: now).compactMap(\.track.id))
            }
            return TrackUniverse(tracks: tracks, searches: searches)
        }
    }
}
