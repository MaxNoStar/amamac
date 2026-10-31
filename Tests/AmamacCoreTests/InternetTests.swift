import Foundation
import Synchronization
import Testing
@testable import AmamacCore

/// Internet radio and podcasts, against canned responses. Part of the serialized `WebTests` suite
/// because the URL stub is global.
extension WebTests {
    static func feed(_ items: [(guid: String?, title: String, date: String, url: String?)]) -> Data {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
            <channel>
              <title>Field Recordings</title>
              <link>https://pod.example.org</link>
              <description>Sounds &amp; stories</description>
              <itunes:author>Example Radio</itunes:author>
              <itunes:image href="https://pod.example.org/art.jpg"/>

            """
        for item in items {
            xml += "<item><title>\(item.title)</title><pubDate>\(item.date)</pubDate>"
            if let guid = item.guid { xml += "<guid isPermaLink=\"false\">\(guid)</guid>" }
            if let url = item.url { xml += "<enclosure url=\"\(url)\" length=\"1234\" type=\"audio/mpeg\"/>" }
            xml += "<itunes:duration>12:30</itunes:duration><description><![CDATA[<p>Episode <b>notes</b></p>]]></description></item>\n"
        }
        xml += "</channel></rss>"
        return Data(xml.utf8)
    }

    @Test func radioBrowserPicksAMirrorAndFlagsUnplayableCodecs() async throws {
        let http = Self.makeClient(routes: [
            "all.api.radio-browser.info/json/servers": [["name": "de2.api.radio-browser.info"], ["name": "evil.example.com"]],
            "de2.api.radio-browser.info/json/stations/topclick": [
                ["stationuuid": "a", "name": "Jazz MP3", "url": "http://a.example/stream", "url_resolved": "http://a.example/live.mp3",
                 "codec": "MP3", "bitrate": 128, "hls": 0, "tags": "jazz,smooth jazz"],
                ["stationuuid": "b", "name": "Ogg Only", "url": "http://b.example/stream.ogg", "codec": "OGG", "bitrate": 160, "hls": 0],
                ["stationuuid": "c", "name": "HLS News", "url": "https://c.example/master.m3u8", "codec": "AAC", "bitrate": 64, "hls": 1],
            ],
        ])
        let radio = await RadioBrowserClient.connect(http: http)
        #expect(radio.server == "de2.api.radio-browser.info")
        let stations = try await radio.topStations()
        #expect(stations.map(\.isPlayable) == [true, false, true])
        #expect(stations.map(\.codecName) == ["MP3", "OGG", "HLS"])
        #expect(stations[0].streamURL?.absoluteString == "http://a.example/live.mp3")
        #expect(stations[0].tagList == ["jazz", "smooth jazz"])

        let db = try LibraryDatabase.inMemory()
        let favorites = RadioFavorites(database: db)
        favorites.add(stations[2])
        favorites.add(stations[2])
        #expect(favorites.all().map(\.name) == ["HLS News"])
        #expect(favorites.all().first?.codecName == "HLS", "HLS survives the round trip through the database")
        favorites.remove(stations[2])
        #expect(favorites.all().isEmpty)
    }

    @Test func podcastSubscribeUpdateDownloadAndPrune() async throws {
        let version = Mutex(1)
        let v1 = Self.feed([("ep1", "First", "Mon, 01 Jun 2026 10:00:00 +0000", "https://cdn.example.org/1.mp3"),
                            (nil, "Second", "Mon, 08 Jun 2026 10:00:00 +0000", "https://cdn.example.org/2.mp3"),
                            ("text", "Announcement", "Tue, 09 Jun 2026 10:00:00 +0000", nil)])
        let v2 = Self.feed([("ep1", "First", "Mon, 01 Jun 2026 10:00:00 +0000", "https://cdn.example.org/1.mp3"),
                            (nil, "Second", "Mon, 08 Jun 2026 10:00:00 +0000", "https://cdn.example.org/2.mp3"),
                            ("ep3", "Third", "Mon, 15 Jun 2026 10:00:00 +0000", "https://cdn.example.org/3.mp3")])
        let config = StubURLProtocol.configuration { request in
            switch request.url?.host() {
            case "pod.example.org": return (200, version.withLock { $0 } == 1 ? v1 : v2)
            case "cdn.example.org": return (200, Data(repeating: 7, count: 4096))
            default: return nil
            }
        }
        let http = HTTPClient(cacheDirectory: nil, configuration: config)
        let db = try LibraryDatabase.inMemory()
        let folder = temporaryDirectory()
        let service = PodcastService(database: db, http: http, downloadFolder: folder)

        var channel = try await service.subscribe(feedURL: URL(string: "https://pod.example.org/feed.xml")!)
        #expect(channel.title == "Field Recordings")
        #expect(channel.author == "Example Radio")
        #expect(channel.imageURL == "https://pod.example.org/art.jpg")
        var episodes = service.episodes(channelId: channel.id!)
        #expect(episodes.map(\.title) == ["Second", "First"], "items without an enclosure are skipped")
        #expect(episodes.map(\.isNew) == [true, false], "only the newest episode starts out new")
        #expect(episodes[0].guid == "https://cdn.example.org/2.mp3", "the enclosure stands in for a missing guid")
        #expect(episodes[0].durationMs == 750_000)
        #expect(PodcastText.plain(episodes[0].summary ?? "") == "Episode notes")

        version.withLock { $0 = 2 }
        let added = try await service.update(channelId: channel.id!)
        #expect(added.map(\.title) == ["Third"])
        #expect(service.newCounts()[channel.id!] == 2)

        channel.keepMax = 1
        service.save(channel)
        episodes = service.episodes(channelId: channel.id!)
        let older = try await service.download(episodes[1])
        #expect(older.isDownloaded)
        #expect(older.localPath?.hasPrefix(folder.appendingPathComponent("Field Recordings").path) == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: older.localPath!)).count == 4096)
        _ = try await service.download(episodes[0])
        let downloaded = service.episodes(channelId: channel.id!).filter(\.isDownloaded).map(\.title)
        #expect(downloaded == ["Third"], "keeping one download removes the older one")

        let item = try #require(service.episodes(channelId: channel.id!)[0].playlistItem(channel: channel))
        #expect(item.url.isFileURL && item.source == .podcast && item.track.artist == "Field Recordings")
        #expect(service.episodes(channelId: channel.id!)[1].playlistItem(channel: channel)?.url.isFileURL == false)
    }

    @Test func podcastDirectoryKeepsResultsWithFeeds() async throws {
        let http = Self.makeClient(routes: ["itunes.apple.com/search": ["results": [
            ["collectionId": 1, "collectionName": "With Feed", "artistName": "A", "feedUrl": "https://f.example/rss"],
            ["collectionId": 2, "collectionName": "No Feed", "artistName": "B"],
        ]]])
        let results = try await PodcastDirectoryClient(http: http).search("sounds")
        #expect(results.map(\.collectionName) == ["With Feed"])
        let url = try #require(StubURLProtocol.requestedURLs.first)
        #expect(query(url, "media") == "podcast")
    }
}

struct OPMLTests {
    @Test func exportsAndParsesNestedOutlines() throws {
        let outlines = [OPML.Outline(title: "Rock & Roll", feedURL: URL(string: "https://a.example/feed?x=1&y=2")!),
                        OPML.Outline(title: "Talk", feedURL: URL(string: "https://b.example/rss")!)]
        #expect(try OPML.parse(OPML.export(outlines, title: "Mine")) == outlines)
        let nested = Data("""
            <opml version="1.0"><body><outline text="Group"><outline text="Inner" xmlUrl="https://c.example/feed"/></outline></body></opml>
            """.utf8)
        #expect(try OPML.parse(nested) == [OPML.Outline(title: "Inner", feedURL: URL(string: "https://c.example/feed")!)])
    }
}
