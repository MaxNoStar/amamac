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

    /// `v1` is what 0.1 – 0.1.2 created; it must never change.
    @Test func v1SchemaIsUnchanged() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.configuration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v1")
        let v1 = try Self.schema(queue)
        #expect(v1.migrations == ["v1"])
        #expect(v1.digest == "7920a13fc5f0cf8ba28f41d33cbf17f2277da09af92fe48b302d5210910b74b6", "v1 schema changed:\n\(v1.text)")
    }

    /// The current schema: v1 without the lyrics table (v2, 0.1.3).
    @Test func currentSchemaAndMigrationsAreUnchanged() throws {
        let current = try Self.schema(try LibraryDatabase.inMemory().writer)
        #expect(current.migrations == ["v1", "v2"])
        #expect(current.digest == "a71f6d6659a8a95004ce7bea5d6a181a02aac84ab17417d9d3b762f69db94a90", "schema changed:\n\(current.text)")
    }

    /// A library written by 0.1.2, lyrics included, keeps its tracks, statistics and labels.
    @Test func v2DropsLyricsAndKeepsTheCollection() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.configuration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            var track = makeTrack("Song", artist: "Band")
            try track.insert(db)
            var stats = TrackStatistics(trackId: track.id!)
            stats.rating = 8
            try stats.save(db)
            try CollectionQueries.setLabels(db, trackId: track.id!, labels: ["mellow"])
            try db.execute(sql: "INSERT INTO lyrics (trackId, text, synced, source) VALUES (?, 'words', 0, 'tag')", arguments: [track.id!])
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
