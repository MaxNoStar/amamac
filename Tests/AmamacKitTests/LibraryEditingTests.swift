import Foundation
import GRDB
import Testing
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacTestSupport
@testable import AmamacWeb

@Suite(.serialized)
struct LibraryEditingTests {
    /// A small scanned library: two tagged FLAC files in one album folder.
    func makeLibrary() async throws -> (root: URL, db: LibraryDatabase, scanner: CollectionScanner) {
        let root = temporaryDirectory().appendingPathComponent("Music")
        var tags = TagChanges()
        tags.title = "First"
        tags.artist = "Editors Band"
        tags.album = "Edit Album"
        tags.trackNumber = 1
        tags.year = 2001
        try AudioFixtures.make(.init("Unsorted/a.flac", seconds: 1, tags: tags), in: root)
        tags.title = "Second"
        tags.trackNumber = 2
        try AudioFixtures.make(.init("Unsorted/b.flac", seconds: 1, tags: tags), in: root)
        let db = try LibraryDatabase.inMemory()
        try await db.writer.write { db in
            var folder = CollectionFolder(path: root.path)
            try folder.insert(db)
        }
        let scanner = CollectionScanner(database: db)
        _ = try await scanner.scan()
        return (root, db, scanner)
    }

    func track(_ db: LibraryDatabase, title: String) async throws -> Track {
        try #require(try await db.writer.read { try Track.fetchOne($0, sql: "SELECT * FROM track WHERE title = ?", arguments: [title]) })
    }

    @Test func tagEditsAreWrittenAndKeepIdentityAndStatistics() async throws {
        let (_, db, scanner) = try await makeLibrary()
        let first = try await track(db, title: "First")
        try await db.writer.write { db in
            var stats = TrackStatistics(trackId: first.id!)
            stats.playCount = 7
            try stats.save(db)
        }
        var changes = TagChanges()
        changes.title = "Première"
        changes.genre = "Test Genre"
        changes.year = 1987
        let failures = await TrackEditor.apply([.init(path: first.path, changes: changes)], scanner: scanner)
        #expect(failures.isEmpty)
        let edited = try await track(db, title: "Première")
        #expect(edited.id == first.id)
        #expect(edited.genre == "Test Genre")
        #expect(edited.year == 1987)
        #expect(edited.dateAdded == first.dateAdded)
        let stats = try await db.writer.read { try TrackStatistics.fetchOne($0, key: first.id!) }
        #expect(stats?.playCount == 7)
        // A later scan sees nothing new.
        let rescan = try await scanner.scan()
        #expect(rescan.updated == 0 && rescan.added == 0 && rescan.removed == 0)
    }

    @Test func organizeMovesFilesAndUpdatesPaths() async throws {
        let (root, db, scanner) = try await makeLibrary()
        let tracks = try await db.writer.read { try Track.fetchAll($0, sql: "SELECT * FROM track ORDER BY trackNumber") }
        let plan = Organizer.plan(tracks, root: root.path, pattern: FileNamingPattern("%artist%/%album%/%track% - %title%"),
                                  options: OrganizeOptions())
        #expect(plan.map { ($0.destination as NSString).lastPathComponent } == ["01 - First.flac", "02 - Second.flac"])
        #expect(plan.allSatisfy { $0.destination.hasPrefix(root.path + "/Editors Band/Edit Album/") })
        #expect(!plan.contains { $0.conflict })
        let result = await Organizer.execute(plan, overwrite: false, scanner: scanner)
        #expect(result.failures.isEmpty)
        #expect(result.moved.count == 2)
        let paths = try await db.writer.read { try String.fetchAll($0, sql: "SELECT path FROM track ORDER BY trackNumber") }
        #expect(paths == plan.map(\.destination))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Unsorted").path))
        let rescan = try await scanner.scan()
        #expect(rescan.added == 0 && rescan.removed == 0)
    }

    @Test func organizeDetectsConflicts() async throws {
        let (root, db, _) = try await makeLibrary()
        let tracks = try await db.writer.read { try Track.fetchAll($0) }
        // Both tracks map to the same name.
        let plan = Organizer.plan(tracks, root: root.path, pattern: FileNamingPattern("%album%"), options: OrganizeOptions())
        #expect(plan.filter(\.conflict).count == 1)
    }

    @Test func guessesTagsFromFileNames() {
        let path = "/Music/Some Artist/Great Album/03 - Song Name.flac"
        #expect(FilenameTagGuesser.guess(path: path, pattern: "%artist%/%album%/%track% - %title%")
            == ["artist": "Some Artist", "album": "Great Album", "track": "3", "title": "Song Name"])
        #expect(FilenameTagGuesser.guess(path: path, pattern: "%track% - %title%") == ["track": "3", "title": "Song Name"])
        #expect(FilenameTagGuesser.guess(path: "/x/Artist - Title.mp3", pattern: "%artist% - %title%") == ["artist": "Artist", "title": "Title"])
        #expect(FilenameTagGuesser.guess(path: "/x/Just a title.mp3", pattern: "%track% - %title%") == nil)
        #expect(FilenameTagGuesser.guess(path: "/x/a.mp3", pattern: "%nonsense%") == nil)
    }

    @Test func importsAppleMusicStatistics() async throws {
        let (_, db, _) = try await makeLibrary()
        let first = try await track(db, title: "First")
        let second = try await track(db, title: "Second")
        try await db.writer.write { db in
            var stats = TrackStatistics(trackId: second.id!)
            stats.playCount = 50
            stats.rating = 4
            try stats.save(db)
        }
        let played = Date(timeIntervalSince1970: 1_700_000_000)
        let plist: [String: Any] = ["Tracks": [
            "1": ["Name": "ignored name", "Location": URL(fileURLWithPath: first.path).absoluteString, "Play Count": 12,
                  "Rating": 80, "Play Date UTC": played],
            "2": ["Name": "Second", "Artist": "editors band", "Album": "Edit Album", "Play Count": 3, "Rating": 100],
            "3": ["Name": "Unknown", "Artist": "Nobody", "Play Count": 1],
            "4": ["Name": "Radio", "Kind": "Internet audio stream"],
        ]]
        let file = temporaryDirectory().appendingPathComponent("Library.xml")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
        let entries = try AppleMusicImporter.parse(file)
        #expect(entries.count == 3)
        let report = try await AppleMusicImporter.apply(entries, to: db)
        #expect(report == .init(entries: 3, matched: 2, updated: 1, unmatched: 1))
        let s1 = try await db.writer.read { try TrackStatistics.fetchOne($0, key: first.id!) }
        #expect(s1?.playCount == 12)
        #expect(s1?.rating == 8)
        #expect(s1?.lastPlayed == played)
        // Existing higher play count and rating are kept.
        let s2 = try await db.writer.read { try TrackStatistics.fetchOne($0, key: second.id!) }
        #expect(s2?.playCount == 50)
        #expect(s2?.rating == 4)
    }
}

/// Network-backed parts share the serialized WebTests suite (the URL stub is global).
extension WebTests {
    @Test func musicBrainzRecordingCandidates() async throws {
        let http = WebTests.makeClient(routes: ["musicbrainz.org/ws/2/recording/": ["recordings": [
            ["id": "rec-1", "title": "Song", "length": 200_000, "score": 100,
             "artist-credit": [["name": "A", "joinphrase": " & "], ["name": "B"]],
             "releases": [["id": "rel-1", "title": "Album", "date": "1999-05-01",
                           "media": [["position": 2, "track": [["number": "7", "position": 7]]]]]]],
            ["id": "rec-2", "title": "Song (live)", "length": 400_000, "score": 90, "releases": [["id": "rel-2", "title": "Live"]]],
        ]]])
        let candidates = try await MusicBrainzClient(http: http).recordings(title: "Song", artist: "A", album: "", durationMs: 201_000)
        #expect(candidates.count == 1)
        let c = try #require(candidates.first)
        #expect(c.artist == "A & B")
        #expect(c.albumArtist == "A & B")
        #expect(c.year == 1999 && c.trackNumber == 7 && c.discNumber == 2 && c.releaseId == "rel-1")
    }

    @Test func coverCandidatesFromArchiveAndITunes() async throws {
        let http = WebTests.makeClient(routes: [
            "musicbrainz.org/ws/2/release/": ["releases": [["id": "r1", "title": "Debut", "score": 100],
                                                          ["id": "r2", "title": "Debut", "score": 95],
                                                          ["id": "r3", "title": "Something Else", "score": 90]]],
            "coverartarchive.org/release/r2/front-500": Data([0xFF, 0xD8, 0xFF]),
            "itunes.apple.com/search": ["results": [["collectionName": "Debut", "artistName": "Björk",
                                                     "artworkUrl100": "https://example.org/a/100x100bb.jpg"]]],
        ])
        let candidates = await CoverFetcher(http: http).candidates(album: "Debut", artist: "Björk")
        #expect(candidates.map(\.source) == [.coverArtArchive, .iTunes])
        #expect(candidates.first?.imageURL.absoluteString == "https://coverartarchive.org/release/r2/front-500")
        #expect(candidates.last?.imageURL.absoluteString == "https://example.org/a/600x600bb.jpg")
    }
}
