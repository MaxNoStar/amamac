import Foundation
import Testing
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacTestSupport

/// The fields the new tag editor writes, through `TagWriter` and back through `TagReader`, in
/// every format the fixtures produce.
@Suite(.serialized)
struct TagRoundTripTests {
    static let formats = ["flac", "ogg", "opus", "m4a", "mp3", "wav", "aiff"]

    func silentFile(_ ext: String, tags: TagChanges = TagChanges(), name: String = #function) throws -> URL {
        let root = temporaryDirectory(name + ext)
        return try AudioFixtures.make(.init("track.\(ext)", seconds: 0.5, amplitude: 0, tags: tags), in: root)
    }

    @Test(arguments: formats)
    func newFieldsRoundTrip(ext: String) throws {
        let url = try silentFile(ext)
        var c = TagChanges()
        c.title = "Here Comes the Sun"
        c.artist = "The Beatles"
        c.trackNumber = 7
        c.trackTotal = 17
        c.discNumber = 1
        c.discTotal = 2
        c.releaseDate = "1969-09-26"
        c.originalDate = "1969-09"
        c.grouping = "Side Two"
        c.isrc = "GBAYE0601690"
        c.titleSort = "Here Comes the Sun"
        c.artistSort = "Beatles, The"
        c.albumArtistSort = "Beatles, The"
        c.albumSort = "Abbey Road (Remaster)"
        try TagWriter.write(c, to: url)

        let read = try TagReader.read(url: url)
        let t = read.track
        #expect(t.title == "Here Comes the Sun")
        #expect(t.trackNumber == 7 && t.trackTotal == 17, "\(ext): track \(t.trackNumber) of \(t.trackTotal)")
        #expect(t.discNumber == 1 && t.discTotal == 2, "\(ext): disc \(t.discNumber) of \(t.discTotal)")
        #expect(t.releaseDate == "1969-09-26", "\(ext)")
        #expect(t.year == 1969)
        #expect(t.originalDate == "1969-09", "\(ext)")
        #expect(t.grouping == "Side Two", "\(ext)")
        #expect(t.isrc == "GBAYE0601690", "\(ext)")
        #expect(read.sortNames == SortNames(title: "Here Comes the Sun", artist: "Beatles, The",
                                            albumArtist: "Beatles, The", album: "Abbey Road (Remaster)"), "\(ext)")
        // `Track` keeps folded sort keys for sorting.
        #expect(t.artistSort == "beatles, the")
    }

    @Test(arguments: formats)
    func datesKeepTheirPrecisionAndClear(ext: String) throws {
        let url = try silentFile(ext)
        for date in ["2001", "2001-05", "2001-05-17"] {
            var c = TagChanges()
            c.releaseDate = date
            c.originalDate = date
            try TagWriter.write(c, to: url)
            let t = try TagReader.read(url: url).track
            #expect(t.releaseDate == date, "\(ext): wrote \(date), read \(t.releaseDate)")
            #expect(t.originalDate == date, "\(ext): wrote \(date), read original \(t.originalDate)")
            #expect(t.year == 2001)
        }
        var clear = TagChanges()
        clear.releaseDate = ""
        clear.originalDate = ""
        clear.grouping = ""
        try TagWriter.write(clear, to: url)
        let t = try TagReader.read(url: url).track
        #expect(t.releaseDate == "" && t.year == 0, "\(ext): \(t.releaseDate)")
        #expect(t.originalDate == "", "\(ext): \(t.originalDate)")
    }

    /// Other software writes `1998` or `1998-03-12` to ID3 TDRC, which SFBAudioEngine drops on
    /// every write unless it is a full timestamp. Editing the title alone must keep it.
    @Test(arguments: ["mp3", "wav", "aiff"], ["1998", "1998-03-12", "1998-03-12T08:15"])
    func foreignID3DatesSurviveATitleEdit(ext: String, date: String) throws {
        var tags = TagChanges()
        tags.title = "Before"
        let url = try silentFile(ext, tags: tags)
        try TagLibFieldIO.write(releaseDate: date, originalDate: "1970", to: url)
        #expect(TagLibFieldIO.read(url)?.releaseDate == date)

        var change = TagChanges()
        change.title = "After"
        try TagWriter.write(change, to: url)

        #expect(TagLibFieldIO.read(url) == .init(releaseDate: date, originalDate: "1970", isrc: nil), "\(ext)")
        let t = try TagReader.read(url: url).track
        #expect(t.title == "After")
        #expect(t.releaseDate == ReleaseDate(date)?.isoString)
        #expect(t.originalDate == "1970")
    }

    /// Amamac 0.1.6 wrote ID3 years as July 1st; the next write leaves just the year.
    @Test func legacyID3YearStampBecomesAYear() throws {
        let url = try silentFile("mp3")
        try TagLibFieldIO.write(releaseDate: "1999-07-01T12:00:00Z", to: url)
        #expect(try TagReader.read(url: url).track.releaseDate == "1999")
        var c = TagChanges()
        c.year = 2004
        try TagWriter.write(c, to: url)
        #expect(TagLibFieldIO.read(url)?.releaseDate == "2004")
    }

    @Test func unparseableDatesAreRefused() throws {
        let url = try silentFile("flac")
        var c = TagChanges()
        c.releaseDate = "next spring"
        #expect(throws: TagWriteError.invalidDate("next spring")) { try TagWriter.write(c, to: url) }
    }

    /// The editor's play count goes to the library only, never into the file.
    @Test func playCountNeverReachesTheFile() async throws {
        let root = temporaryDirectory()
        var tags = TagChanges()
        tags.title = "Counted"
        let url = try AudioFixtures.make(.init("Counted.flac", seconds: 0.5, amplitude: 0, tags: tags), in: root)
        let db = try LibraryDatabase.inMemory()
        try db.setCollectionFolders(paths: [root.path])
        let scanner = CollectionScanner(database: db)
        _ = try await scanner.scan()
        let track = try #require(try await db.tracks().first?.track)

        var session = TagEditSession(tracks: [track], playCounts: [0])
        session.setPlayCount(42, at: 0)
        session.set(.genre, "Folk")
        #expect(session.changes(at: 0).playCount == nil)
        #expect(session.playCountEdits.map(\.playCount) == [42])

        let failures = await TrackEditor.apply(session.edits, scanner: scanner)
        #expect(failures.isEmpty)
        for edit in session.playCountEdits {
            try await StatisticsStore(database: db).setPlayCount(edit.playCount, for: edit.trackId)
        }
        let stats = try await db.tracks(ids: [track.id!]).first?.statistics
        #expect(stats?.playCount == 42)
        let read = try TagReader.read(url: url)
        #expect(read.track.genre == "Folk")
        #expect(read.playCount == nil)
    }
}
