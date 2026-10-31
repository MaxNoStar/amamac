import AmamacModels
import AmamacQuery
import Foundation
import GRDB

/// The collection as seen from outside the package: the app reads and changes it through these
/// methods and never runs SQL itself (`writer` is package-only).
extension LibraryDatabase {
    // MARK: Collection browsing

    public func groups(level: CollectionLevel, constraints: [CollectionConstraint], filter: CollectionQuery,
                       sortAlbumsByYear: Bool = false) throws -> [CollectionGroup] {
        try writer.read {
            try CollectionQueries.groups($0, level: level, constraints: constraints, filter: filter, sortAlbumsByYear: sortAlbumsByYear)
        }
    }

    public func tracks(constraints: [CollectionConstraint] = [], filter: CollectionQuery = CollectionQuery(),
                       limit: Int? = nil) throws -> [TrackWithStatistics] {
        try writer.read { try CollectionQueries.tracks($0, constraints: constraints, filter: filter, limit: limit) }
    }

    public func tracks(constraints: [CollectionConstraint] = [], filter: CollectionQuery = CollectionQuery(),
                       limit: Int? = nil) async throws -> [TrackWithStatistics] {
        try await writer.read { try CollectionQueries.tracks($0, constraints: constraints, filter: filter, limit: limit) }
    }

    public func tracks(ids: [Int64]) throws -> [TrackWithStatistics] {
        try writer.read { try CollectionQueries.tracks($0, ids: ids) }
    }

    public func tracks(ids: [Int64]) async throws -> [TrackWithStatistics] {
        try await writer.read { try CollectionQueries.tracks($0, ids: ids) }
    }

    public func count(filter: CollectionQuery) throws -> Int {
        try writer.read { try CollectionQueries.count($0, filter: filter) }
    }

    /// The artist's albums with their tracks, read in one transaction.
    public func albumsWithTracks(artist: String) async throws -> [(album: CollectionGroup, tracks: [TrackWithStatistics])] {
        try await writer.read { db in
            try CollectionQueries.albums(db, artist: artist).map { group in
                let tracks = try group.albumKey.map {
                    try CollectionQueries.tracks(db, constraints: [CollectionConstraint(level: .album, key: $0)], filter: CollectionQuery())
                } ?? []
                return (group, tracks)
            }
        }
    }

    public func recentlyAddedAlbums(limit: Int) async throws -> [CollectionGroup] {
        try await writer.read { try CollectionQueries.recentlyAddedAlbums($0, limit: limit) }
    }

    public func allAlbums() async throws -> [CollectionGroup] {
        try await writer.read { try CollectionQueries.allAlbums($0) }
    }

    /// A MusicBrainz release id tagged on any of the album's tracks.
    public func releaseID(albumKey: String) throws -> String? {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT mbReleaseId FROM track WHERE albumKey = ? AND mbReleaseId <> '' LIMIT 1",
                                arguments: [albumKey])
        }
    }

    /// Tracks that have statistics (rating, score or plays).
    public func trackIdsWithStatistics() async throws -> [Int64] {
        try await writer.read { try Int64.fetchAll($0, sql: "SELECT trackId FROM statistics") }
    }

    // MARK: Labels

    /// Labels of each track (empty for tracks outside the collection), plus every label name, read
    /// in one transaction.
    public func labels(trackIds: [Int64?]) async throws -> (labels: [[String]], allLabels: [String]) {
        try await writer.read { db in
            let labels = try trackIds.map { id in try id.map { try CollectionQueries.labels(db, trackId: $0) } ?? [] }
            return (labels, try CollectionQueries.allLabels(db).map(\.name))
        }
    }

    /// Replaces the labels of each track, in one transaction.
    public func setLabels(_ labelsByTrack: [(trackId: Int64, labels: [String])]) async throws {
        try await writer.write { db in
            for (id, names) in labelsByTrack { try CollectionQueries.setLabels(db, trackId: id, labels: names) }
        }
    }

    // MARK: Collection folders

    public func collectionFolders() throws -> [CollectionFolder] {
        try writer.read { try CollectionFolder.fetchAll($0) }
    }

    /// Makes the collection folders exactly `paths`, keeping the settings of folders that stay.
    public func setCollectionFolders(paths: [String]) throws {
        try writer.write { db in
            let existing = try CollectionFolder.fetchAll(db)
            for folder in existing where !paths.contains(folder.path) { try folder.delete(db) }
            for path in paths where !existing.contains(where: { $0.path == path }) {
                var folder = CollectionFolder(path: path)
                try folder.insert(db)
            }
        }
    }

    public func setWatch(_ watch: Bool, folderPath: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE collection_folder SET watch = ? WHERE path = ?", arguments: [watch, folderPath])
        }
    }

    // MARK: Totals

    /// Counts shown in Diagnostics.
    public struct Totals: Sendable {
        public var tracks = 0
        public var albums = 0
        public var playedTracks = 0
        public var playlists = 0
        public var podcasts = 0

        public init() {}

        init(tracks: Int, albums: Int, playedTracks: Int, playlists: Int, podcasts: Int) {
            (self.tracks, self.albums, self.playedTracks, self.playlists, self.podcasts) = (tracks, albums, playedTracks, playlists, podcasts)
        }
    }

    public func totals() throws -> Totals {
        try writer.read { db in
            Totals(tracks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0,
                   albums: try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT albumKey) FROM track") ?? 0,
                   playedTracks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE playCount > 0") ?? 0,
                   playlists: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? 0,
                   podcasts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcast_channel") ?? 0)
        }
    }
}
