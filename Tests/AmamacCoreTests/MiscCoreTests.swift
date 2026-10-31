import Foundation
import Testing
@testable import AmamacCore

struct StatisticsTests {
    @Test func playCountRules() {
        #expect(PlayStatistics.countsAsPlay(playedSeconds: 20, duration: 25, reachedEnd: true))
        #expect(!PlayStatistics.countsAsPlay(playedSeconds: 20, duration: 25, reachedEnd: false))
        #expect(PlayStatistics.countsAsPlay(playedSeconds: 100, duration: 200, reachedEnd: false))
        #expect(!PlayStatistics.countsAsPlay(playedSeconds: 99, duration: 200, reachedEnd: false))
        #expect(PlayStatistics.countsAsPlay(playedSeconds: 300, duration: 3600, reachedEnd: false))
    }

    @Test func scoreFormula() {
        #expect(PlayStatistics.updatedScore(old: 0, playCount: 0, percentage: 100) == 50)
        #expect(PlayStatistics.updatedScore(old: 50, playCount: 1, percentage: 100) == 75)
        var stats = TrackStatistics(trackId: 1)
        PlayStatistics.apply(to: &stats, playedSeconds: 200, duration: 200, reachedEnd: true)
        #expect(stats.playCount == 1 && stats.score == 50 && stats.firstPlayed != nil)
        PlayStatistics.apply(to: &stats, playedSeconds: 20, duration: 200, reachedEnd: false)
        #expect(stats.playCount == 1)
        #expect(stats.score < 50)
    }
}

struct PlaylistFileTests {
    let entries = [
        PlaylistFileEntry(url: URL(fileURLWithPath: "/music/A/a b.flac"), title: "Song & Dance", artist: "A", album: "X", durationMs: 61_000, trackNumber: 1),
        PlaylistFileEntry(url: URL(string: "http://radio.example/stream")!, title: "Radio"),
    ]

    @Test(arguments: PlaylistFileFormat.allCases)
    func roundTrip(format: PlaylistFileFormat) throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("list.\(format.rawValue)")
        try PlaylistFile.write(entries, to: url, relativePaths: false, title: "Test")
        let read = try PlaylistFile.read(from: url)
        #expect(read.map(\.url) == entries.map(\.url), "\(format)")
        #expect(read.first?.title?.contains("Song & Dance") == true, "\(format)")
    }

    @Test func relativePaths() throws {
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("Sub/track.mp3")
        let url = dir.appendingPathComponent("list.m3u8")
        try PlaylistFile.write([PlaylistFileEntry(url: file)], to: url, relativePaths: true)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\nSub/track.mp3"))
        #expect(try PlaylistFile.read(from: url).first?.url.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func parsesExtinf() {
        let entries = PlaylistFile.parseM3U("#EXTM3U\n#EXTINF:123,Artist - Title\nmusic/a.mp3\n", base: URL(fileURLWithPath: "/base"))
        #expect(entries == [PlaylistFileEntry(url: URL(fileURLWithPath: "/base/music/a.mp3"), title: "Title", artist: "Artist", durationMs: 123_000)])
    }
}

struct OrganizeTests {
    @Test func expandsPatternsAndOptionalSections() {
        var t = makeTrack("Come Together", artist: "The Beatles", album: "Abbey Road", track: 1, year: 1969)
        t.path = "/old/x.MP3"
        var options = OrganizeOptions()
        options.ignoreThe = false
        let p = FileNamingPattern("%artist%/%album%{ (%year%)}/{%discnumber%-}%track% - %title%")
        #expect(p.destination(for: t, collectionRoot: "/Music", options: options) == "/Music/The Beatles/Abbey Road (1969)/01 - Come Together.mp3")
        options.ignoreThe = true
        options.replaceSpaces = true
        #expect(p.render(track: t, collectionRoot: "/Music", options: options) == "Beatles,_The/Abbey_Road_(1969)/01_-_Come_Together")
    }

    @Test func sanitizesComponents() {
        let t = makeTrack("What? / Why: \"now\"", artist: "AC/DC", album: "Ünïcode")
        var options = OrganizeOptions()
        options.asciiOnly = true
        let out = FileNamingPattern("%artist%/%album%/%title%").render(track: t, collectionRoot: "/M", options: options)
        #expect(out == "AC-DC/Unicode/What_ - Why_ _now_")
    }
}

struct LRCTests {
    @Test func parsesSyncedLyrics() {
        let text = "[ar:Someone]\n[00:01.50]First\n[00:03.00][00:10.00]Chorus\n[00:05]Second"
        let lines = LRCParser.parse(text)
        #expect(lines.map(\.text) == ["First", "Chorus", "Second", "Chorus"])
        #expect(lines[0].time == 1.5)
        #expect(LRCParser.currentLine(lines, at: 4) == 1)
        #expect(LRCParser.plainText("[00:01.00]Hi\n[00:02.00]There") == "Hi\nThere")
    }
}

struct TextTests {
    @Test func foldingAndSortKeys() {
        #expect(TextFolding.fold("Björk") == "bjork")
        #expect(TextFolding.sortKey("The Beatles") == "beatles")
        #expect(TextFolding.likeEscaped("100%_a") == "100\\%\\_a")
        #expect(TimeFormatting.duration(3725) == "1:02:05")
        #expect(TimeFormatting.duration(65) == "1:05")
    }
}
