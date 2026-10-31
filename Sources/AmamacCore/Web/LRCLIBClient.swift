import Foundation

/// Lyrics from LRCLIB (lrclib.net): exact lookup by title/artist/album/duration, then a search
/// accepting matches within ±2 s. Synced (LRC) lyrics are preferred.
public struct LRCLIBClient: Sendable {
    public struct Lyrics: Sendable, Equatable {
        public var text: String
        public var synced: Bool
        public var instrumental: Bool
    }

    struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var lyrics: Lyrics? {
            if instrumental == true { return Lyrics(text: "", synced: false, instrumental: true) }
            if let synced = syncedLyrics, !synced.isEmpty { return Lyrics(text: synced, synced: true, instrumental: false) }
            if let plain = plainLyrics, !plain.isEmpty { return Lyrics(text: plain, synced: false, instrumental: false) }
            return nil
        }
    }

    let http: HTTPClient
    var base = "https://lrclib.net/api"

    public init(http: HTTPClient) { self.http = http }

    /// Returns nil when LRCLIB has nothing for the track.
    public func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Lyrics? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var query = [("track_name", title), ("artist_name", artist)]
        if !album.isEmpty { query.append(("album_name", album)) }
        if duration > 0 { query.append(("duration", String(Int(duration.rounded())))) }
        do {
            let record = try await http.json(Record.self, from: HTTPClient.url(base + "/get", query))
            if let lyrics = record.lyrics { return lyrics }
        } catch HTTPError.notFound {
            // Fall through to the search.
        }
        let results = try await http.json([Record].self, from: HTTPClient.url(base + "/search", [("track_name", title), ("artist_name", artist)]))
        let close = results.filter { record in
            guard duration > 0, let d = record.duration else { return true }
            return abs(d - duration) <= 2
        }
        return (close.first { $0.syncedLyrics?.isEmpty == false } ?? close.first)?.lyrics
    }
}
