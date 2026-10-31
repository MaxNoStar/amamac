import Foundation
import Synchronization
import Testing
@testable import AmamacCore

/// Online clients against canned responses (no live network).
@Suite(.serialized)
struct WebTests {
    final class AgentLog: Sendable {
        let values = Mutex<Set<String>>([])
    }

    /// Routes requests by host + path to JSON bodies; records User-Agent headers.
    static func makeClient(cache: URL? = nil, routes: [String: Any], agents: AgentLog? = nil) -> HTTPClient {
        let bodies = routes.mapValues { value -> Data in
            if let data = value as? Data { return data }
            return try! JSONSerialization.data(withJSONObject: value)
        }
        let config = StubURLProtocol.configuration { request in
            guard let url = request.url else { return nil }
            if let agent = request.value(forHTTPHeaderField: "User-Agent") { agents?.values.withLock { _ = $0.insert(agent) } }
            let key = (url.host() ?? "") + url.path()
            return bodies[key].map { (200, $0) }
        }
        return HTTPClient(cacheDirectory: cache, configuration: config)
    }

    func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @Test func lrclibExactMatchPrefersSyncedLyrics() async throws {
        let http = Self.makeClient(routes: ["lrclib.net/api/get": [
            "trackName": "Song", "artistName": "Band", "duration": 201.0, "instrumental": false,
            "plainLyrics": "Hello\nWorld", "syncedLyrics": "[00:01.00]Hello\n[00:02.50]World",
        ]])
        let lyrics = try await LRCLIBClient(http: http).lyrics(title: "Song", artist: "Band", album: "Album", duration: 201.4)
        #expect(lyrics == .init(text: "[00:01.00]Hello\n[00:02.50]World", synced: true, instrumental: false))
        let url = try #require(StubURLProtocol.requestedURLs.first)
        #expect(query(url, "duration") == "201")
        #expect(query(url, "album_name") == "Album")
    }

    @Test func lrclibFallsBackToSearchWithinTwoSeconds() async throws {
        let http = Self.makeClient(routes: ["lrclib.net/api/search": [
            ["trackName": "Song", "duration": 150.0, "plainLyrics": "wrong length"],
            ["trackName": "Song", "duration": 201.0, "plainLyrics": "plain only"],
            ["trackName": "Song", "duration": 202.0, "plainLyrics": "p", "syncedLyrics": "[00:01.00]synced"],
        ]])
        let lyrics = try await LRCLIBClient(http: http).lyrics(title: "Song", artist: "Band", album: "", duration: 200.5)
        #expect(lyrics?.text == "[00:01.00]synced")
        #expect(StubURLProtocol.requestedURLs.map(\.path) == ["/api/get", "/api/search"])
    }

    @Test func lrclibReportsInstrumentals() async throws {
        let http = Self.makeClient(routes: ["lrclib.net/api/get": ["instrumental": true]])
        let lyrics = try await LRCLIBClient(http: http).lyrics(title: "Song", artist: "Band", album: "", duration: 60)
        #expect(lyrics?.instrumental == true)
    }

    @Test func wikipediaArtistResolvesThroughMusicBrainzAndWikidata() async throws {
        let agents = AgentLog()
        let http = Self.makeClient(routes: [
            "musicbrainz.org/ws/2/artist/": ["artists": [["id": "other", "name": "Björk Tribute", "score": 95],
                                                        ["id": "mbid-1", "name": "Björk", "score": 100]]],
            "musicbrainz.org/ws/2/artist/mbid-1": ["relations": [["type": "wikidata", "url": ["resource": "https://www.wikidata.org/wiki/Q42"]]]],
            "www.wikidata.org/wiki/Special:EntityData/Q42.json": ["entities": ["Q42": ["sitelinks": ["dewiki": ["title": "Björk (Sängerin)"]]]]],
            "de.wikipedia.org/w/api.php": ["parse": ["title": "Björk (Sängerin)", "text": "<p>Isländische Sängerin</p>"]],
        ], agents: agents)
        var track = Track(path: "/x.flac", title: "Joga", artist: "Bjork")
        track.updateDerivedFields()
        let client = WikipediaClient(http: http, language: "de")
        let page = try await client.page(for: .artist, track: track)
        #expect(page.title == "Björk (Sängerin)")
        #expect(page.html.contains("Isländische"))
        #expect(page.url.absoluteString == "https://de.wikipedia.org/wiki/Bj%C3%B6rk_(S%C3%A4ngerin)")
        #expect(agents.values.withLock { $0 } == [HTTPClient.userAgent])
        let parse = try #require(StubURLProtocol.requestedURLs.last)
        #expect(query(parse, "page") == "Björk (Sängerin)")
    }

    @Test func wikipediaAlbumUsesSearch() async throws {
        let http = Self.makeClient(routes: [
            "en.wikipedia.org/w/api.php": ["query": ["search": [["title": "Debut (Björk album)"]]],
                                           "parse": ["title": "Debut (Björk album)", "text": "<p>1993 album</p>"]],
        ])
        var track = Track(path: "/x.flac", title: "Human Behaviour", artist: "Björk", album: "Debut")
        track.updateDerivedFields()
        let page = try await WikipediaClient(http: http).page(for: .album, track: track)
        #expect(page.title == "Debut (Björk album)")
        let search = try #require(StubURLProtocol.requestedURLs.first)
        #expect(query(search, "srsearch") == "\"Debut\" album Björk")
        #expect(StubURLProtocol.requestedURLs.allSatisfy { $0.host() == "en.wikipedia.org" })
    }

    @Test func wikipediaReportsMissingSubject() async throws {
        let http = Self.makeClient(routes: [:])
        let track = Track(path: "/x.flac", title: "Song")
        await #expect(throws: WikipediaClient.Failure.nothingToLookUp) {
            try await WikipediaClient(http: http).page(for: .composer, track: track)
        }
    }

    @Test func responsesAreCachedOnDisk() async throws {
        let dir = temporaryDirectory()
        let http = Self.makeClient(cache: dir, routes: ["example.org/a": ["x": 1]])
        let url = URL(string: "https://example.org/a")!
        _ = try await http.data(from: url)
        _ = try await http.data(from: url)
        #expect(StubURLProtocol.requestedURLs.count == 1)
        _ = try await http.data(from: url, useCache: false)
        #expect(StubURLProtocol.requestedURLs.count == 2)
    }

    @Test func musicBrainzRequestsAreSpacedOneSecondApart() async throws {
        let http = Self.makeClient(routes: ["musicbrainz.org/ws/2/x": ["ok": true]])
        let url = URL(string: "https://musicbrainz.org/ws/2/x")!
        let start = ContinuousClock.now
        _ = try await http.data(from: url, useCache: false)
        _ = try await http.data(from: url, useCache: false)
        #expect(ContinuousClock.now - start >= .milliseconds(950))
    }

    @Test func notFoundIsDistinguished() async throws {
        let http = Self.makeClient(routes: [:])
        await #expect(throws: HTTPError.notFound) { try await http.data(from: URL(string: "https://example.org/missing")!) }
    }

    @Test func lyricsServiceKeepsUserLyrics() async throws {
        let db = try LibraryDatabase.inMemory()
        let track = try await db.writer.write { db -> Track in
            var track = makeTrack("Song", artist: "Band")
            try track.insert(db)
            return track
        }
        let http = Self.makeClient(routes: ["lrclib.net/api/get": ["plainLyrics": "from lrclib"]])
        let service = LyricsService(database: db, http: http)
        try await service.save("my own words", trackId: track.id!)
        let refetched = try await service.lyrics(for: track, refetch: true)
        #expect(refetched?.text == "from lrclib")
        #expect(await service.stored(trackId: track.id!)?.text == "my own words")
        try await service.save("", trackId: track.id!)
        #expect(await service.stored(trackId: track.id!) == nil)
        _ = try await service.lyrics(for: track)
        #expect(await service.stored(trackId: track.id!)?.source == "lrclib")
    }
}
