import Foundation
import GRDB
import Testing
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacQuery
@testable import AmamacTestSupport

@Suite(.serialized)
struct ScannerTests {
    static let library: URL = {
        let root = temporaryDirectory("fixture-library")
        _ = try! AudioFixtures.buildStandardLibrary(at: root)
        return root
    }()

    func copyLibrary() throws -> URL {
        let dest = temporaryDirectory()
        let target = dest.appendingPathComponent("Music")
        try FileManager.default.copyItem(at: Self.library, to: target)
        return target
    }

    func scannedDatabase(root: URL) async throws -> (LibraryDatabase, CollectionScanner, ScanResult) {
        let db = try LibraryDatabase.inMemory()
        try await db.writer.write { db in
            var folder = CollectionFolder(path: root.path)
            try folder.insert(db)
        }
        let scanner = CollectionScanner(database: db)
        let result = try await scanner.scan()
        return (db, scanner, result)
    }

    @Test func scansEveryFormatAndGroupsAlbums() async throws {
        let root = try copyLibrary()
        let (db, _, result) = try await scannedDatabase(root: root)
        let expected = AudioFixtures.standardLibrary().count
        #expect(result.added == expected)
        #expect(result.failed.isEmpty, "failed: \(result.failed)")

        let artists = try await db.writer.read { try CollectionQueries.groups($0, level: .albumArtist, constraints: [], filter: CollectionQuery()) }
        let names = artists.map(\.displayName)
        #expect(names.first == TrackText.variousArtists)
        #expect(names.contains("The Synthetics"))
        #expect(names.contains("Björk Ensemble"))
        #expect(names.contains(TrackText.unknownArtist))

        // Both compilations end up under Various Artists (tag and folder heuristic).
        let va = artists.first { $0.displayName == TrackText.variousArtists }!
        let vaAlbums = try await db.writer.read {
            try CollectionQueries.groups($0, level: .album, constraints: [CollectionConstraint(level: .albumArtist, key: va.key)], filter: CollectionQuery())
        }
        #expect(Set(vaAlbums.map(\.name)) == ["Hits", "Summer Mix"])

        let synth = artists.first { $0.displayName == "The Synthetics" }!
        let tracks = try await db.writer.read {
            try CollectionQueries.tracks($0, constraints: [CollectionConstraint(level: .albumArtist, key: synth.key)], filter: CollectionQuery())
        }
        #expect(tracks.map(\.track.trackNumber) == [1, 2, 3, 4, 5, 6], "\(tracks.map { ($0.track.fileName, $0.track.trackNumber, $0.track.year) })")
        #expect(Set(tracks.map(\.track.format)) == ["flac", "mp3", "ogg", "opus", "m4a", "wav"])
        #expect(tracks.allSatisfy { $0.track.year == 1999 }, "\(tracks.map { ($0.track.format, $0.track.year) })")
        #expect(tracks.allSatisfy { $0.track.durationMs > 1500 })

        let filtered = try await db.writer.read { try CollectionQueries.count($0, filter: CollectionQuery.parse("sóng")) }
        #expect(filtered == 4)
    }

    @Test func rescansAreIncrementalAndHandleMoves() async throws {
        let root = try copyLibrary()
        let (db, scanner, first) = try await scannedDatabase(root: root)
        let again = try await scanner.scan()
        #expect(again.unchanged == first.added && !again.changed, "\(again)")

        // Give a track statistics, then move its file.
        let original = root.appendingPathComponent("Gapless Group/Continuous/1 Part 1.flac")
        let trackId = try await db.writer.write { db -> Int64 in
            let row = try CollectionQueries.track(db, path: original.path)!
            try TrackStatistics(trackId: row.track.id!, rating: 9, playCount: 3).save(db)
            return row.track.id!
        }
        let movedURL = root.appendingPathComponent("Moved/Part One.flac")
        try FileManager.default.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: movedURL)
        let afterMove = try await scanner.scan()
        #expect(afterMove.moved == 1 && afterMove.removed == 0)
        let moved = try await db.writer.read { try CollectionQueries.track($0, path: movedURL.path) }
        #expect(moved?.track.id == trackId)
        #expect(moved?.statistics?.rating == 9)

        // Edit tags: the track is updated in place.
        var change = TagChanges()
        change.title = "Renamed"
        try TagWriter.write(change, to: movedURL)
        let afterEdit = try await scanner.scan()
        #expect(afterEdit.updated == 1)
        let edited = try await db.writer.read { try CollectionQueries.track($0, path: movedURL.path) }
        #expect(edited?.track.title == "Renamed")

        // Delete a file: removed.
        try FileManager.default.removeItem(at: movedURL)
        let afterDelete = try await scanner.scan()
        #expect(afterDelete.removed == 1)
    }

    @Test func unreachableRootKeepsTracks() async throws {
        let root = try copyLibrary()
        let (db, scanner, first) = try await scannedDatabase(root: root)
        let hidden = root.deletingLastPathComponent().appendingPathComponent("Unplugged")
        try FileManager.default.moveItem(at: root, to: hidden)
        let result = try await scanner.scan()
        #expect(result.unreachableRoots == [root.path])
        #expect(result.removed == 0)
        let count = try await db.writer.read { try CollectionQueries.count($0, filter: CollectionQuery()) }
        #expect(count == first.added)
    }

    @Test func coversFromFolderAndEmbeddedArt() async throws {
        let root = try copyLibrary()
        var tags = TagChanges()
        tags.frontCover = AudioFixtures.coverPNG(text: "B", hue: 0.1, size: 120)
        try TagWriter.write(tags, to: root.appendingPathComponent("Gapless Group/Continuous/2 Part 2.flac"))
        let (db, _, _) = try await scannedDatabase(root: root)
        let store = CoverStore(database: db, cacheDirectory: temporaryDirectory("covers"))
        let albums = try await db.writer.read { try CollectionQueries.groups($0, level: .album, constraints: [], filter: CollectionQuery()) }
        let sine = albums.first { $0.name == "Sine Waves" }!.albumKey!
        let gapless = albums.first { $0.name == "Continuous" }!.albumKey!
        let hits = albums.first { $0.name == "Hits" }!.albumKey!
        #expect(await store.cover(albumKey: sine, size: 64) != nil)
        #expect(await store.cover(albumKey: gapless, size: 64) != nil)
        #expect(await store.cover(albumKey: hits, size: 64) == nil)
        try await store.unsetCover(albumKey: sine)
        #expect(await store.cover(albumKey: sine, size: 64) == nil)
        try await store.setCover(albumKey: hits, imageData: AudioFixtures.coverPNG(text: "H", hue: 0.3))
        #expect(await store.cover(albumKey: hits, size: 32) != nil)
    }

    @Test func customCoverWinsOverFolderImage() async throws {
        let root = try copyLibrary()
        let (db, _, _) = try await scannedDatabase(root: root)
        let store = CoverStore(database: db, cacheDirectory: temporaryDirectory("covers"))
        let albums = try await db.writer.read { try CollectionQueries.groups($0, level: .album, constraints: [], filter: CollectionQuery()) }
        let sine = albums.first { $0.name == "Sine Waves" }!.albumKey!
        let folder = try Data(contentsOf: root.appendingPathComponent("The Synthetics/Sine Waves/cover.png"))
        #expect(await store.originalImageData(albumKey: sine) == folder)
        let custom = AudioFixtures.coverPNG(text: "C", hue: 0.6)
        try await store.setCover(albumKey: sine, imageData: custom)
        #expect(await store.originalImageData(albumKey: sine) == custom)
    }
}

struct PerformanceTests {
    @Test func collectionQueriesStayFastOn20kTracks() throws {
        let db = try LibraryDatabase.inMemory()
        try SyntheticLibrary.populate(db, trackCount: 20_000)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            try db.writer.read { db in
                let artists = try CollectionQueries.groups(db, level: .albumArtist, constraints: [], filter: CollectionQuery())
                #expect(artists.count > 500)
                let filtered = try CollectionQueries.groups(db, level: .albumArtist, constraints: [], filter: CollectionQuery.parse("night"))
                #expect(!filtered.isEmpty)
                let albums = try CollectionQueries.groups(db, level: .album, constraints: [CollectionConstraint(level: .albumArtist, key: artists[3].key)], filter: CollectionQuery())
                #expect(!albums.isEmpty)
            }
        }
        #expect(elapsed < .seconds(2), "queries took \(elapsed)")
    }
}
