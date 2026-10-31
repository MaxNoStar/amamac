import Foundation
import GRDB

/// Playlists saved in the database (Media Sources › Playlists › Saved Playlists).
public struct SavedPlaylistStore: Sendable {
    public struct Summary: Sendable, Identifiable, Hashable {
        public var id: Int64
        public var name: String
        public var trackCount: Int
        public var durationMs: Int
        public var modified: Date
    }

    public static let changed = Notification.Name("amamacSavedPlaylistsChanged")
    let database: LibraryDatabase

    public init(database: LibraryDatabase) { self.database = database }

    public func all() -> [Summary] {
        (try? database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.modified, COUNT(e.position) AS n, COALESCE(SUM(e.durationMs), 0) AS ms
                FROM playlist p LEFT JOIN playlist_entry e ON e.playlistId = p.id
                GROUP BY p.id ORDER BY p.name COLLATE NOCASE
                """).map { Summary(id: $0["id"], name: $0["name"], trackCount: $0["n"], durationMs: $0["ms"], modified: $0["modified"]) }
        }) ?? []
    }

    /// Saves items as a new playlist (or replaces the entries of `id`). Returns the playlist id.
    @discardableResult
    public func save(name: String, items: [PlaylistItem], replacing id: Int64? = nil) throws -> Int64 {
        let result = try database.writer.write { db -> Int64 in
            let playlistId: Int64
            if let id {
                try db.execute(sql: "UPDATE playlist SET name = ?, modified = ? WHERE id = ?", arguments: [name, Date(), id])
                try db.execute(sql: "DELETE FROM playlist_entry WHERE playlistId = ?", arguments: [id])
                playlistId = id
            } else {
                var playlist = SavedPlaylist(name: name)
                try playlist.insert(db)
                playlistId = playlist.id!
            }
            for (i, item) in items.enumerated() {
                try SavedPlaylistEntry(playlistId: playlistId, position: i,
                                       trackId: item.source == .collection ? item.track.id : nil,
                                       url: item.url.absoluteString, title: item.streamTitle ?? item.track.title,
                                       artist: item.track.artist, album: item.track.album,
                                       durationMs: item.track.durationMs).insert(db)
            }
            return playlistId
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return result
    }

    public func rename(id: Int64, to name: String) {
        try? database.writer.write { try $0.execute(sql: "UPDATE playlist SET name = ?, modified = ? WHERE id = ?", arguments: [name, Date(), id]) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func delete(ids: [Int64]) {
        try? database.writer.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id]) }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// The playlist's items: collection tracks by id, everything else from its URL.
    public func items(playlistId: Int64) async -> [PlaylistItem] {
        let database = self.database
        let entries = (try? await database.writer.read {
            try SavedPlaylistEntry.fetchAll($0, sql: "SELECT * FROM playlist_entry WHERE playlistId = ? ORDER BY position", arguments: [playlistId])
        }) ?? []
        let ids = entries.compactMap(\.trackId)
        let known = (try? await database.writer.read { try CollectionQueries.tracks($0, ids: ids) }) ?? []
        let byId = Dictionary(uniqueKeysWithValues: known.map { ($0.track.id!, $0) })
        return entries.compactMap { entry -> PlaylistItem? in
            if let id = entry.trackId, let track = byId[id] { return track.playlistItem() }
            guard let url = URL(string: entry.url) else { return nil }
            let fileEntry = PlaylistFileEntry(url: url, title: entry.title, artist: entry.artist, album: entry.album,
                                              durationMs: entry.durationMs)
            if let item = PlaylistLoader.resolve([fileEntry], database: database).first { return item }
            // A file that is gone stays in the list with its saved details.
            var track = Track(path: url.path, title: entry.title ?? url.lastPathComponent, artist: entry.artist ?? "",
                              album: entry.album ?? "", durationMs: entry.durationMs ?? 0)
            track.updateDerivedFields()
            return PlaylistItem(track: track, source: .file, url: url)
        }
    }

    /// Imports a playlist file into the database.
    public func importFile(_ url: URL) async throws -> Int64 {
        let items = await PlaylistLoader.items(for: [url], database: database)
        return try save(name: url.deletingPathExtension().lastPathComponent, items: items)
    }

    /// Writes a saved playlist to a playlist file (format from the extension).
    public func export(playlistId: Int64, to url: URL) async throws {
        let items = await items(playlistId: playlistId)
        try PlaylistFile.write(items.map(PlaylistFileEntry.init(item:)), to: url)
    }
}

extension PlaylistFileEntry {
    public init(item: PlaylistItem) {
        self.init(url: item.url, title: item.streamTitle ?? item.track.title, artist: item.track.artist, album: item.track.album,
                  durationMs: item.track.durationMs, trackNumber: item.track.trackNumber > 0 ? item.track.trackNumber : nil)
    }
}

public struct SavedPlaylist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"
    public var id: Int64?
    public var name: String
    public var created: Date
    public var modified: Date

    public init(id: Int64? = nil, name: String, created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SavedPlaylistEntry: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playlist_entry"
    public var playlistId: Int64
    public var position: Int
    public var trackId: Int64?
    public var url: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationMs: Int?
    /// Preserved playlist item id (used for the current-playlist session).
    public var itemId: String?

    public init(playlistId: Int64, position: Int, trackId: Int64?, url: String, title: String?, artist: String?,
                album: String?, durationMs: Int?, itemId: String? = nil) {
        self.playlistId = playlistId
        self.position = position
        self.trackId = trackId
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.itemId = itemId
    }
}
