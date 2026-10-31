import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacDatabase
@testable import AmamacPodcasts
@testable import AmamacWeb

/// What a hostile podcast feed can put in front of Amamac: local-file enclosures, absurd durations,
/// and file names meant to be run rather than played.
struct PodcastSafetyTests {
    static func feed(_ items: [(url: String, duration: String)]) -> Data {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title>
            """
        for (index, item) in items.enumerated() {
            xml += "<item><title>Episode \(index)</title><enclosure url=\"\(item.url)\" length=\"10\" type=\"audio/mpeg\"/>"
            xml += "<itunes:duration>\(item.duration)</itunes:duration></item>\n"
        }
        return Data((xml + "</channel></rss>").utf8)
    }

    @Test func onlyWebEnclosuresBecomeEpisodes() throws {
        let parsed = try PodcastFeedParser.parse(Self.feed([
            ("file:///Users/someone/.ssh/id_rsa", "1:00"), ("javascript:alert(1)", "1:00"),
            ("amamac://navigate/collection", "1:00"), ("https://cdn.example.org/ok.mp3", "1:00"),
        ]))
        #expect(parsed.episodes.map(\.enclosureURL) == ["https://cdn.example.org/ok.mp3"])
    }

    @Test func absurdDurationsAreDropped() throws {
        let parsed = try PodcastFeedParser.parse(Self.feed([("https://cdn.example.org/a.mp3", "99999999999999999999999"),
                                                            ("https://cdn.example.org/b.mp3", "12:30")]))
        #expect(parsed.episodes.map(\.durationMs) == [nil, 750_000])
    }

    @Test func storedFileEnclosuresDontPlay() {
        let episode = PodcastEpisode(id: 1, channelId: 1, guid: "g", title: "t", summary: nil, pubDate: nil, durationMs: nil,
                                     enclosureURL: "file:///etc/hosts", enclosureType: nil, fileSize: nil, localPath: nil,
                                     isNew: true, isPlayed: false)
        #expect(episode.playURL == nil)
    }

    @Test func downloadsGetMediaNamesAndNeverReuseAFile() throws {
        let folder = temporaryDirectory()
        let service = PodcastService(database: try LibraryDatabase.inMemory(),
                                     http: HTTPClient(cacheDirectory: nil), downloadFolder: folder)
        var channel = PodcastChannel(feedURL: "https://pod.example.org/feed.xml", title: "../../Show/\u{301}")
        channel.id = 1
        func episode(_ url: String, _ title: String, type: String? = "audio/mpeg") -> PodcastEpisode {
            PodcastEpisode(id: 7, channelId: 1, guid: url, title: title, summary: nil,
                           pubDate: Date(timeIntervalSince1970: 1_780_000_000), durationMs: nil, enclosureURL: url,
                           enclosureType: type, fileSize: nil, localPath: nil, isNew: true, isPlayed: false)
        }

        let runnable = service.destination(for: episode("https://evil.example/Open%20me.terminal", "Episode 1"), channel: channel)
        #expect(runnable.lastPathComponent == "Episode 1.mp3")
        #expect(runnable.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                "the channel title stays one folder inside the download folder")
        #expect(service.destination(for: episode("https://cdn.example.org/video", "Clip", type: "video/mp4"), channel: channel)
            .lastPathComponent == "Clip.mp4")

        let plain = service.destination(for: episode("https://cdn.example.org/show.mp3", "Episode 2"), channel: channel)
        #expect(plain.lastPathComponent == "show.mp3")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: plain)
        let dated = service.destination(for: episode("https://cdn.example.org/show.mp3", "Episode 3"), channel: channel)
        #expect(dated.lastPathComponent == "2026-05-28 show.mp3")
        try Data().write(to: dated)
        #expect(service.destination(for: episode("https://cdn.example.org/show.mp3", "Episode 4"), channel: channel)
            .lastPathComponent == "2026-05-28 show 2.mp3")
    }
}
