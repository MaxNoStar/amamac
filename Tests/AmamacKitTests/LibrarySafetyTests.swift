import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacDatabase
@testable import AmamacLibrary
@testable import AmamacModels
@testable import AmamacTestSupport

/// Organize Files, tag writes, folder covers and the watcher against crafted tags and odd folders:
/// files must never leave the collection folder or be lost.
struct LibrarySafetyTests {
    func makeRoot() throws -> URL {
        let root = temporaryDirectory().appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func craftedTagsCannotLeaveTheCollectionFolder() throws {
        let root = try makeRoot()
        var ascii = OrganizeOptions()
        ascii.asciiOnly = true
        ascii.vfatSafe = false
        let cases: [(Track, String, OrganizeOptions)] = [
            // "/" + a combining mark survives character-based replacing; ASCII-only then strips the mark.
            (makeTrack("Song", albumArtist: "x/\u{301}../\u{301}../\u{301}../\u{301}Documents", path: root.path + "/a.flac"),
             "%albumartist%/%title%", ascii),
            (makeTrack("Song", albumArtist: "/etc", path: root.path + "/b.flac"), "%initial%/%albumartist%/%title%", OrganizeOptions()),
            (makeTrack("Song", path: root.path + "/\t..\t/c.flac"), "%folder%/../%title%", OrganizeOptions()),
        ]
        for (track, pattern, options) in cases {
            let move = try #require(Organizer.plan([track], root: root.path, pattern: FileNamingPattern(pattern), options: options).first)
            #expect(Paths.isInside(move.destination, folder: root.path) || move.refused != nil, "\(pattern): \(move.destination)")
            #expect(!move.destination.contains("/../"))
        }
    }

    @Test func destinationsOutsideTheRootAreRefused() throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let track = makeTrack("Song", path: root.path + "/a.flac")
        func plan(_ pattern: String) throws -> Organizer.Move {
            try #require(Organizer.plan([track], root: root.path, pattern: FileNamingPattern(pattern), options: OrganizeOptions()).first)
        }
        for pattern in [outside.path + "/%title%", "link/%title%"] {
            let move = try plan(pattern)
            #expect(move.refused != nil, "\(pattern) → \(move.destination)")
        }
        // A ".." in the pattern itself is cleaned away rather than followed.
        #expect(Paths.isInside(try plan("%collectionroot%/../Elsewhere/%title%").destination, folder: root.path))
    }

    @Test func caseOnlyRenameKeepsTheFile() async throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("Band")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("SONG.flac")
        try Data("audio".utf8).write(to: source)
        let plan = Organizer.plan([makeTrack("song", artist: "Band", path: source.path)], root: root.path,
                                  pattern: FileNamingPattern("%artist%/%title%"), options: OrganizeOptions())
        #expect(plan.map(\.conflict) == [false])
        let result = await Organizer.execute(plan, overwrite: true, scanner: CollectionScanner(database: try LibraryDatabase.inMemory()))
        #expect(result.failures.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["song.flac"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("song.flac")) == Data("audio".utf8))
    }

    @Test func twoTracksWithOneNameDontTrashEachOther() async throws {
        let root = try makeRoot()
        var tracks: [Track] = []
        for name in ["1", "2"] {
            let file = root.appendingPathComponent("\(name).flac")
            try Data(name.utf8).write(to: file)
            tracks.append(makeTrack("Same", artist: "Band", path: file.path))
        }
        let plan = Organizer.plan(tracks, root: root.path, pattern: FileNamingPattern("%title%"), options: OrganizeOptions())
        let result = await Organizer.execute(plan, overwrite: true, scanner: CollectionScanner(database: try LibraryDatabase.inMemory()))
        #expect(result.moved.count == 1 && result.failures.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("Same.flac")) == Data("1".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2.flac").path))
    }

    @Test func emptiedFoldersAreRemovedButNeverTheRoot() throws {
        let root = try makeRoot()
        let empty = root.appendingPathComponent("A/B")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        Organizer.removeIfEmpty(empty.path, root: root.path)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
        Organizer.removeIfEmpty(root.path, root: root.path)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func tagWritesFollowSymbolicLinksSafely() throws {
        let root = try makeRoot()
        let real = try AudioFixtures.make(.init("real.flac", seconds: 1), in: root)
        let link = root.appendingPathComponent("link.flac")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var changes = TagChanges()
        changes.title = "Through the link"
        try TagWriter.write(changes, to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try TagReader.read(url: real).track.title == "Through the link")
    }

    @Test func folderCoversMustBeRegularFiles() throws {
        let folder = try makeRoot()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("cover.jpg"),
                                                   withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(CoverStore.folderImage(in: folder) == nil)
        try Data([0xFF, 0xD8, 0xFF]).write(to: folder.appendingPathComponent("folder.jpg"))
        #expect(CoverStore.folderImage(in: folder)?.lastPathComponent == "folder.jpg")
    }

    @Test func watcherIgnoresHiddenFoldersBelowARoot() {
        #expect(FolderWatcher.isHidden("/Music/.trash/a.mp3", below: ["/Music"]))
        #expect(!FolderWatcher.isHidden("/Music/Band/a.mp3", below: ["/Music"]))
        #expect(!FolderWatcher.isHidden("/Users/me/.media/Music/a.mp3", below: ["/Users/me/.media/Music"]))
    }
}
