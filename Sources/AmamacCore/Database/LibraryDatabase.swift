import Foundation
import GRDB

/// The collection database (SQLite via GRDB).
public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database file at `url`.
    public static func open(at url: URL) throws -> LibraryDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        return try LibraryDatabase(writer: pool)
    }

    /// An in-memory database for tests.
    public static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(writer: DatabaseQueue(configuration: configuration()))
    }

    static let foldFunction = DatabaseFunction("amamac_fold", argumentCount: 1, pure: true) { values in
        guard let s = String.fromDatabaseValue(values[0]) else { return nil }
        return TextFolding.fold(s)
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: foldFunction)
        }
        return config
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "collection_folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("recursive", .boolean).notNull().defaults(to: true)
                t.column("watch", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("folderId", .integer).references("collection_folder", onDelete: .setNull)
                t.column("uniqueId", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("artistSort", .text).notNull()
                t.column("albumArtist", .text).notNull()
                t.column("albumArtistSort", .text).notNull().indexed()
                t.column("album", .text).notNull()
                t.column("albumSort", .text).notNull()
                t.column("albumKey", .text).notNull()
                t.column("composer", .text).notNull()
                t.column("genre", .text).notNull().indexed()
                t.column("year", .integer).notNull().indexed()
                t.column("trackNumber", .integer).notNull()
                t.column("trackTotal", .integer).notNull()
                t.column("discNumber", .integer).notNull()
                t.column("discTotal", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.column("comment", .text).notNull()
                t.column("compilation", .boolean).notNull()
                t.column("mbReleaseId", .text).notNull()
                t.column("mbRecordingId", .text).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("format", .text).notNull()
                t.column("bitrate", .integer).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("channels", .integer).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("mtime", .datetime).notNull()
                t.column("dateAdded", .datetime).notNull().indexed()
                t.column("rgTrackGain", .double)
                t.column("rgTrackPeak", .double)
                t.column("rgAlbumGain", .double)
                t.column("rgAlbumPeak", .double)
                t.column("hasEmbeddedArt", .boolean).notNull()
                t.column("searchFolded", .text).notNull()
            }
            try db.create(index: "track_album", on: "track", columns: ["albumKey", "discNumber", "trackNumber"])
            try db.create(table: "statistics") { t in
                t.primaryKey("trackId", .integer).references("track", onDelete: .cascade)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("firstPlayed", .datetime)
                t.column("lastPlayed", .datetime).indexed()
            }
            try db.create(table: "lyrics") { t in
                t.primaryKey("trackId", .integer).references("track", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("synced", .boolean).notNull().defaults(to: false)
                t.column("source", .text).notNull()
            }
            try db.create(table: "label") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique(onConflict: .ignore)
            }
            try db.create(table: "track_label") { t in
                t.column("trackId", .integer).notNull().references("track", onDelete: .cascade)
                t.column("labelId", .integer).notNull().references("label", onDelete: .cascade)
                t.primaryKey(["trackId", "labelId"], onConflict: .ignore)
            }
            try db.create(table: "album_cover") { t in
                t.primaryKey("albumKey", .text)
                t.column("source", .text).notNull()
                t.column("path", .text)
            }
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("created", .datetime).notNull()
                t.column("modified", .datetime).notNull()
            }
            try db.create(table: "playlist_entry") { t in
                t.column("playlistId", .integer).notNull().references("playlist", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("trackId", .integer).references("track", onDelete: .setNull)
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("artist", .text)
                t.column("album", .text)
                t.column("durationMs", .integer)
                t.column("itemId", .text)
                t.primaryKey(["playlistId", "position"])
            }
            try db.create(table: "dynamic_playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("definition", .jsonText).notNull()
            }
            try db.create(table: "apg_preset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("definition", .jsonText).notNull()
            }
            try db.create(table: "bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("url", .text).notNull()
                t.column("trackId", .integer).references("track", onDelete: .cascade)
                t.column("position", .double)
                t.column("created", .datetime).notNull()
            }
            try db.create(table: "podcast_channel") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("feedURL", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("author", .text)
                t.column("summary", .text)
                t.column("imageURL", .text)
                t.column("link", .text)
                t.column("keywords", .text)
                t.column("autoScan", .boolean).notNull().defaults(to: true)
                t.column("downloadPolicy", .text).notNull().defaults(to: "onRequest")
                t.column("keepMax", .integer).notNull().defaults(to: 0)
                t.column("saveLocation", .text)
                t.column("subscribed", .datetime).notNull()
                t.column("lastUpdated", .datetime)
            }
            try db.create(table: "podcast_episode") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("channelId", .integer).notNull().references("podcast_channel", onDelete: .cascade)
                t.column("guid", .text).notNull()
                t.column("title", .text).notNull()
                t.column("summary", .text)
                t.column("pubDate", .datetime)
                t.column("durationMs", .integer)
                t.column("enclosureURL", .text).notNull()
                t.column("enclosureType", .text)
                t.column("fileSize", .integer)
                t.column("localPath", .text)
                t.column("isNew", .boolean).notNull().defaults(to: true)
                t.column("isPlayed", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["channelId", "guid"])
            }
            try db.create(table: "radio_station") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("stationUUID", .text).unique()
                t.column("name", .text).notNull()
                t.column("url", .text).notNull()
                t.column("homepage", .text)
                t.column("favicon", .text)
                t.column("tags", .text)
                t.column("country", .text)
                t.column("codec", .text)
                t.column("bitrate", .integer)
                t.column("added", .datetime).notNull()
            }
            try db.create(table: "app_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }
        }
        return migrator
    }
}

extension SQLValue {
    var databaseValue: any DatabaseValueConvertible {
        switch self {
        case .text(let s): s
        case .int(let i): i
        case .double(let d): d
        case .date(let d): d
        }
    }
}

extension SQLFragment {
    var statementArguments: StatementArguments {
        StatementArguments(arguments.map(\.databaseValue))
    }
}
