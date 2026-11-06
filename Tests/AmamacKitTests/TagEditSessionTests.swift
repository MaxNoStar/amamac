import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacTestSupport

struct TagEditSessionTests {
    func album() -> [Track] {
        var tracks = [
            makeTrack("One", artist: "Band", album: "Record", track: 1, year: 1998, path: "/m/Band/Record/01 One.flac", id: 1),
            makeTrack("Two", artist: "Band", album: "Record", track: 2, year: 1998, path: "/m/Band/Record/02 Two.flac", id: 2),
            makeTrack("Three", artist: "Guest", album: "Record", track: 3, year: 1998, path: "/m/Band/Record/03 Three.flac", id: 3),
        ]
        tracks[2].compilation = true
        return tracks
    }

    @Test func sharedAndMixedValues() {
        var session = TagEditSession(tracks: album())
        #expect(!session.showsOneTrack)
        #expect(session.value(.album) == "Record" && !session.isMixed(.album))
        #expect(session.value(.artist) == "" && session.isMixed(.artist))
        #expect(session.value(.releaseDate) == "1998")
        #expect(session.compilation == .mixed)

        session.set(.genre, "Shoegaze")
        session.setCompilation(true)
        #expect(session.compilation == .on)
        #expect(session.edits.count == 3)
        #expect(session.changes(at: 0).genre == "Shoegaze")
        #expect(session.changes(at: 0).compilation == true)
        #expect(session.changes(at: 2).compilation == nil, "already a compilation")
        #expect(session.changes(at: 0).artist == nil, "mixed field untouched")
    }

    @Test func perTrackEditsOneTrack() {
        var session = TagEditSession(tracks: album())
        session.perTrack = true
        session.index = 1
        #expect(session.value(.artist) == "Band" && !session.isMixed(.artist))
        session.set(.title, "Deux")
        #expect(session.edits.map(\.path) == ["/m/Band/Record/02 Two.flac"])
        session.index = 99
        #expect(session.index == 2)
    }

    @Test func onlyRealChangesAreWritten() {
        var session = TagEditSession(tracks: [album()[0]])
        session.set(.title, " One ")
        session.set(.releaseDate, "1998")
        session.set(.trackNumber, "01")
        #expect(!session.hasChanges)
        session.set(.releaseDate, "1998-3-12")
        session.set(.isrc, "gb-aye-06-01690")
        session.set(.trackTotal, "12")
        let c = session.changes(at: 0)
        #expect(c.releaseDate == "1998-03-12")
        #expect(c.isrc == "GBAYE0601690")
        #expect(c.trackTotal == 12)
        #expect(c.trackNumber == nil && c.title == nil)
    }

    @Test func invalidValuesBlockSaving() {
        var session = TagEditSession(tracks: album())
        session.set(.releaseDate, "1998-13")
        session.set(.trackTotal, "twelve")
        session.set(.isrc, "nope")
        #expect(Set(session.invalidFields) == [.releaseDate, .trackTotal, .isrc])
        #expect(!session.canSave)
        session.set(.releaseDate, "")
        session.set(.trackTotal, "12")
        session.set(.isrc, "")
        #expect(session.invalidFields.isEmpty && session.canSave)
        #expect(session.changes(at: 0).releaseDate == "")
    }

    /// A value already in a file is kept even if the editor would not accept it typed in.
    @Test func untouchedOddValuesDoNotBlockSaving() {
        var track = album()[0]
        track.isrc = "not-an-isrc"
        var session = TagEditSession(tracks: [track])
        session.set(.title, "Uno")
        #expect(session.canSave)
        #expect(session.changes(at: 0).isrc == nil)
    }

    @Test func fileValuesReplaceUneditedFields() {
        var session = TagEditSession(tracks: [album()[0]])
        session.set(.title, "Edited")
        var file = TagEditSession.Values(track: album()[0], sortNames: SortNames(artist: "Band, The"))
        file.title = "One (file)"
        file.genre = "Dream Pop"
        session.adoptFileValues([file])
        #expect(session.value(.title) == "Edited")
        #expect(session.value(.genre) == "Dream Pop")
        #expect(session.value(.artistSort) == "Band, The")
        #expect(session.changes(at: 0).title == "Edited")
        #expect(session.changes(at: 0).genre == nil, "file values are the baseline")
    }

    @Test func numbersTracksPerDisc() {
        var tracks = album()
        tracks.append(makeTrack("B1", album: "Record", track: 0, disc: 2, path: "/m/b/10 B1.flac", id: 4))
        tracks.append(makeTrack("B2", album: "Record", track: 0, disc: 2, path: "/m/b/9 B2.flac", id: 5))
        var session = TagEditSession(tracks: tracks)
        session.set(.discNumber, "")
        session.perTrack = true
        for i in 3...4 {
            session.index = i
            session.set(.discNumber, "2")
        }
        session.perTrack = false
        session.numberTracks()
        #expect(session.current.map(\.trackNumber) == ["1", "2", "3", "2", "1"])
        #expect(session.current.map(\.trackTotal) == ["3", "3", "3", "2", "2"])
    }

    @Test func trackNumberingOrder() {
        let numbers = TrackNumbering.number([
            .init(discNumber: 1, trackNumber: 0, fileName: "b.flac"),
            .init(discNumber: 1, trackNumber: 5, fileName: "z.flac"),
            .init(discNumber: 2, trackNumber: 1, fileName: "c.flac"),
            .init(discNumber: 1, trackNumber: 0, fileName: "a10.flac"),
            .init(discNumber: 1, trackNumber: 0, fileName: "a9.flac"),
        ])
        #expect(numbers.map(\.trackNumber) == [4, 1, 1, 3, 2])
        #expect(numbers.map(\.trackTotal) == [4, 4, 1, 4, 4])
    }

    @Test func guessAndFill() {
        var session = TagEditSession(tracks: album())
        #expect(session.guessFromFilenames(pattern: "%artist%/%album%/%track% %title%") == 3)
        #expect(session.current.map(\.title) == ["One", "Two", "Three"])
        #expect(session.value(.artist) == "Band")
        session.fill([.releaseDate: "1998-03-12", .trackTotal: "11", .album: ""], at: 0)
        #expect(session.current[0].releaseDate == "1998-03-12")
        #expect(session.current[0].album == "Record")
    }

    @Test func labelsCoversAndPlayCounts() {
        var session = TagEditSession(tracks: album(), playCounts: [3, 0, 1], labels: [["calm"], [], ["calm", "live"]])
        #expect(session.shownLabels == ["calm", "live"])
        session.addLabel(" night ")
        session.removeLabel("live")
        #expect(session.labelEdits.map(\.labels) == [["calm", "night"], ["night"], ["calm", "night"]])

        session.setCover(.set(Data([1, 2, 3])))
        #expect(session.coverEdit == .set(Data([1, 2, 3])))
        #expect(session.changes(at: 1).frontCover == Data([1, 2, 3]))
        session.perTrack = true
        session.setCover(.remove)
        #expect(session.changes(at: 0).frontCover == Data())

        session.setPlayCount(9, at: 2)
        session.setPlayCount(-4, at: 1)
        #expect(session.playCount(at: 2) == 9)
        #expect(session.playCountEdits.map(\.playCount) == [9])
        #expect(session.edits.allSatisfy { $0.changes.playCount == nil })
    }

    @Test func labelsLoadedLaterKeepEdits() {
        var session = TagEditSession(tracks: Array(album().prefix(2)))
        session.perTrack = true
        session.addLabel("added early")
        session.adoptLabels([["calm"], ["live"]])
        #expect(session.labelEdits.map(\.labels) == [["added early"]])
        session.index = 1
        #expect(session.shownLabels == ["live"])
    }

    @Test func coverImagesArePreparedForEmbedding() throws {
        let png = AudioFixtures.coverPNG(text: "x", hue: 0.3)
        #expect(try EmbeddedCover.prepared(png) == png)

        let tiff = NSMutableData()
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let destination = try #require(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        #expect(CGImageDestinationFinalize(destination))
        let converted = try EmbeddedCover.prepared(tiff as Data)
        #expect(converted.starts(with: [0x89, 0x50, 0x4E, 0x47]), "converted to PNG")

        #expect(throws: EmbeddedCover.Problem.notAnImage) { try EmbeddedCover.prepared(Data("text".utf8)) }
        #expect(throws: EmbeddedCover.Problem.tooLarge) { try EmbeddedCover.prepared(Data(count: EmbeddedCover.maxBytes + 1)) }
    }

    @Test func completesFromTheCollection() async throws {
        let db = try LibraryDatabase.inMemory()
        try await db.writer.write { db in
            for (i, (artist, genre)) in [("The Beatles", "Rock"), ("Beat Happening", "Indie Pop"), ("Björk", "Art Pop"),
                                         ("Björk", "Art Pop"), ("Blur", "Britpop"), ("Abbey Beat", "Rock")].enumerated() {
                var t = makeTrack("T\(i)", artist: artist, genre: genre, path: "/m/\(i).flac")
                try t.insert(db)
            }
        }
        #expect(try await db.distinctValues(.artist, prefix: "be") == ["Beat Happening", "Abbey Beat", "The Beatles"])
        #expect(try await db.distinctValues(.artist, prefix: "BJO") == ["Björk"])
        #expect(try await db.distinctValues(.genre, prefix: "pop") == ["Art Pop", "Indie Pop"])
        #expect(try await db.distinctValues(.genre, prefix: "", limit: 2) == ["Art Pop", "Rock"])
        #expect(try await db.distinctValues(.album, prefix: "100%_") == [])
    }
}
