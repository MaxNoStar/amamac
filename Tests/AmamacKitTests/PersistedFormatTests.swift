import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacWeb

/// Pins what earlier versions wrote to disk: the schema and its migration name, cache file names,
/// track identity hashes and derived track keys. Refactors must keep all of these unchanged, or
/// existing libraries, covers and caches would be misread or rebuilt.
struct PersistedFormatTests {
    /// Migrations and a digest of the schema they leave behind.
    static func schema(_ writer: any DatabaseWriter) throws -> (migrations: [String], digest: String, text: String) {
        try writer.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            let schema = try String.fetchAll(db, sql: """
                SELECT type || ' ' || name || ': ' || COALESCE(sql, '') FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY type, name
                """).joined(separator: "\n")
            let digest = SHA256.hash(data: Data(schema.utf8)).map { String(format: "%02x", $0) }.joined()
            return (migrations, digest, schema)
        }
    }

    /// A track row as the v1 schema stores it (`Track` itself has columns added since).
    static func insertV1Track(_ db: Database, title: String, year: Int) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO track (path, uniqueId, title, titleSort, artist, artistSort, albumArtist, albumArtistSort, album,
                albumSort, albumKey, composer, genre, year, trackNumber, trackTotal, discNumber, discTotal, bpm, comment,
                compilation, mbReleaseId, mbRecordingId, durationMs, format, bitrate, sampleRate, channels, fileSize, mtime,
                dateAdded, hasEmbeddedArt, searchFolded, artistKey, albumArtistKey, genreKey, composerKey)
            VALUES (?, '', ?, '', 'Band', 'band', '', 'band', '', '', '', '', '', ?, 1, 0, 0, 0, 0, '', 0, '', '', 0, 'flac',
                0, 0, 0, 0, '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 0, '', 'band', 'band', '', '')
            """, arguments: ["/m/\(title).flac", title, year])
        return db.lastInsertedRowID
    }

    /// `v1` is what 0.1 – 0.1.2 created; it must never change.
    @Test func v1SchemaIsUnchanged() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.configuration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v1")
        let v1 = try Self.schema(queue)
        #expect(v1.migrations == ["v1"])
        #expect(v1.digest == "7920a13fc5f0cf8ba28f41d33cbf17f2277da09af92fe48b302d5210910b74b6", "v1 schema changed:\n\(v1.text)")
    }

    /// The current schema: v1 without the lyrics table (v2, 0.1.3), with release dates, original
    /// dates, grouping and ISRC on tracks (v3, 0.1.7).
    @Test func currentSchemaAndMigrationsAreUnchanged() throws {
        let current = try Self.schema(try LibraryDatabase.inMemory().writer)
        #expect(current.migrations == ["v1", "v2", "v3"])
        #expect(current.digest == "1f40863084a5d53d7cb72f1026b594572c8262f883ff34fc0a5b36d7cc7ceb6b",
                "schema changed (\(current.digest)):\n\(current.text)")
    }

    /// A library written by 0.1.2, lyrics included, keeps its tracks, statistics and labels.
    @Test func v2DropsLyricsAndKeepsTheCollection() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.configuration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            let id = try Self.insertV1Track(db, title: "Song", year: 2000)
            var stats = TrackStatistics(trackId: id)
            stats.rating = 8
            try stats.save(db)
            try CollectionQueries.setLabels(db, trackId: id, labels: ["mellow"])
            try db.execute(sql: "INSERT INTO lyrics (trackId, text, synced, source) VALUES (?, 'words', 0, 'tag')", arguments: [id])
        }
        try LibraryDatabase.migrator.migrate(queue)
        let (hasLyrics, tracks, rating, labels) = try queue.read { db in
            (try db.tableExists("lyrics"), try Track.fetchCount(db), try TrackStatistics.fetchOne(db)?.rating,
             try CollectionQueries.labels(db, trackId: 1))
        }
        #expect(!hasLyrics)
        #expect(tracks == 1)
        #expect(rating == 8)
        #expect(labels == ["mellow"])
    }

    /// A library written by 0.1.6 gets the new track columns, with each year as its release date.
    @Test func v3AddsDatesAndKeepsYears() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.configuration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v2")
        try queue.write { db in
            for (title, year) in [("Dated", 1998), ("Undated", 0)] { _ = try Self.insertV1Track(db, title: title, year: year) }
        }
        try LibraryDatabase.migrator.migrate(queue)
        let tracks = try queue.read { try Track.fetchAll($0, sql: "SELECT * FROM track ORDER BY title") }
        #expect(tracks.map(\.releaseDate) == ["1998", ""])
        #expect(tracks.map(\.year) == [1998, 0])
        #expect(tracks.allSatisfy { $0.originalDate.isEmpty && $0.grouping.isEmpty && $0.isrc.isEmpty })
    }

    @Test func coverCacheNamesAreUnchanged() {
        let store = CoverStore(database: try! LibraryDatabase.inMemory(), cacheDirectory: temporaryDirectory())
        #expect(store.cacheKey("abc") == "ba7816bf8f01cfea414140de")
        #expect(store.thumbnailURL(albumKey: "abc", size: 64).lastPathComponent == "ba7816bf8f01cfea414140de-64.jpg")
        #expect(store.originalURL(albumKey: "abc").lastPathComponent == "ba7816bf8f01cfea414140de-full")
    }

    @Test func httpCacheNamesAreUnchanged() throws {
        let dir = temporaryDirectory()
        let client = HTTPClient(cacheDirectory: dir, configuration: .ephemeral)
        let file = dir.appendingPathComponent("aa8f8f8dbc8c01c454e74d52eeeb245c.cache")
        try Data("x".utf8).write(to: file)
        client.removeCachedResponse(for: URL(string: "https://example.org/a?b=1")!)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the cache file name for a URL changed")
    }

    @Test func trackIdentityHashIsUnchanged() throws {
        let file = temporaryDirectory().appendingPathComponent("hello.bin")
        try Data("hello".utf8).write(to: file)
        #expect(CollectionScanner.uniqueId(for: file, size: 5) == "fe745503750fdbf3e6ef676d16d85ee0")
    }

    @Test func derivedTrackKeysAreUnchanged() {
        var t = makeTrack("Here Comes The Sun", artist: "The Beatles", album: "Abbey Road", year: 1969)
        t.updateDerivedFields()
        #expect(t.albumKey == "abbey road\u{1F}the beatles")
        #expect(t.artistSort == "beatles")
        #expect(t.albumArtistSort == "beatles")
        #expect(t.effectiveAlbumArtist == "The Beatles")
        #expect(t.searchFolded == "here comes the sun\u{1F}the beatles\u{1F}\u{1F}abbey road\u{1F}\u{1F}rock\u{1F}1969\u{1F}1 Here Comes The Sun.flac".lowercased())

        var various = makeTrack("Song", artist: "Ärtist", album: "Hits", albumArtist: "Someone", compilation: true)
        various.updateDerivedFields()
        #expect(various.albumKey == "hits\u{1F}#va")
        #expect(various.effectiveAlbumArtist == "Various Artists")
        #expect(various.artistKey == "artist")
        #expect(various.albumArtistKey == "various artists")

        var bare = makeTrack("", artist: "Solo", album: "")
        bare.updateDerivedFields()
        #expect(bare.albumKey == "\u{1F}solo")
        #expect(bare.displayAlbum == "Unknown Album")
        #expect(bare.displayTitle == "1 ")
    }
}
