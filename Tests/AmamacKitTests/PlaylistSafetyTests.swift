import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacDatabase
@testable import AmamacModels
@testable import AmamacPlaylist

/// Playlist files and sessions from outside: duplicates, self-references, huge numbers, broken
/// markup and line breaks must neither crash the app nor change what a playlist says.
struct PlaylistSafetyTests {
    let base = URL(fileURLWithPath: "/music")

    /// A session holding the same collection track twice used to crash every launch.
    @MainActor @Test func sessionWithTheSameTrackTwiceRestores() async throws {
        let database = try LibraryDatabase.inMemory()
        let track = try await database.writer.write { db in
            var track = makeTrack("Song", artist: "Band", path: "/music/song.flac")
            try track.insert(db)
            return track
        }
        let model = PlaylistModel()
        _ = model.append([PlaylistItem(track: track), PlaylistItem(track: track)])
        let session = PlaylistLoader.Session(model: model, position: nil, wasPlaying: false)
        let items = await PlaylistLoader.items(for: session, database: database)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.track.id == track.id })
    }

    @Test func aPlaylistThatListsItselfIsReadOnce() throws {
        let dir = temporaryDirectory()
        let list = dir.appendingPathComponent("loop.m3u")
        let lines = ["#EXTM3U"] + Array(repeating: "loop.m3u", count: 200) + ["song.mp3"]
        try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        var entries: [PlaylistFileEntry] = []
        var visited = Set<String>()
        let started = Date()
        PlaylistLoader.expand(list, into: &entries, visited: &visited, depth: 0)
        #expect(entries.map(\.url.lastPathComponent) == ["song.mp3"])
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func onlyAudioFilesAndWebStreamsAreTakenFromPlaylists() throws {
        let dir = temporaryDirectory()
        let list = dir.appendingPathComponent("mixed.m3u")
        try ["/etc/passwd", "notes.txt", "amamac://navigate/collection", "javascript:alert(1)",
             "http://radio.example.org/stream", "track.flac"].joined(separator: "\n")
            .write(to: list, atomically: true, encoding: .utf8)
        var entries: [PlaylistFileEntry] = []
        var visited = Set<String>()
        PlaylistLoader.expand(list, into: &entries, visited: &visited, depth: 0)
        #expect(entries.map(\.url.absoluteString) == ["http://radio.example.org/stream", dir.appendingPathComponent("track.flac").absoluteString])
    }

    @Test func hugeDurationsAreIgnoredInsteadOfOverflowing() {
        let m3u = PlaylistFile.parseM3U("#EXTM3U\n#EXTINF:9223372036854775,Artist - Title\nsong.mp3\n", base: base)
        #expect(m3u.count == 1 && m3u[0].durationMs == nil && m3u[0].title == "Title")
        let pls = PlaylistFile.parsePLS("[playlist]\nFile1=song.mp3\nLength1=9223372036854775\nNumberOfEntries=1\n", base: base)
        #expect(pls.count == 1 && pls[0].durationMs == nil)
    }

    @Test func asxWithThousandsOfUnclosedEntriesIsFast() {
        let hostile = String(repeating: "<entry><ref href=\"x", count: 10_000)
        let text = "<asx version=\"3.0\"><ENTRY><Ref HREF=\"http://example.org/a.mp3\"/><TITLE> Song </TITLE></ENTRY>" + hostile + "</asx>"
        let started = Date()
        let entries = PlaylistFile.parseASX(text, base: base)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(entries.count == 1)
        #expect(entries.first?.url.absoluteString == "http://example.org/a.mp3")
        #expect(entries.first?.title == "Song")
    }

    @Test func lineBreaksInTitlesDontAddOrReplaceEntries() {
        let song = URL(fileURLWithPath: "/music/song.mp3")
        let entries = [PlaylistFileEntry(url: song, title: "Evil\nhttp://tracker.example/x\nFile1=/etc/passwd", artist: "A\rB", durationMs: 1000)]
        for format in [PlaylistFileFormat.m3u8, .pls] {
            let text = PlaylistFile.serialize(entries, format: format, base: nil)
            let back = format == .pls ? PlaylistFile.parsePLS(text, base: base) : PlaylistFile.parseM3U(text, base: base)
            #expect(back.map(\.url) == [song], "\(format)")
        }
    }

    @Test func controlCharactersDontBreakExportedXML() {
        let song = URL(fileURLWithPath: "/music/song.mp3")
        let text = PlaylistFile.serialize([PlaylistFileEntry(url: song, title: "a\u{1}b"), PlaylistFileEntry(url: song, title: "c")],
                                          format: .xspf, base: nil)
        let back = PlaylistFile.parseXSPF(Data(text.utf8), base: base)
        #expect(back.map(\.title) == ["ab", "c"])
    }

    @Test func oversizedPlaylistFilesAreRefused() throws {
        let file = temporaryDirectory().appendingPathComponent("huge.m3u")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PlaylistFile.maxFileSize + 1))
        try handle.close()
        #expect(throws: PlaylistFileError.self) { try PlaylistFile.read(from: file) }
    }
}
