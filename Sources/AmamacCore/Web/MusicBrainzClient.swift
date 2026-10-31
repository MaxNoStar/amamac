import Foundation

/// MusicBrainz lookups used by the tag editor and the cover fetcher (rate limited by HTTPClient).
public struct MusicBrainzClient: Sendable {
    /// One recording on one release, as offered in the tag editor.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var recordingId: String
        public var releaseId: String
        public var title: String
        public var artist: String
        public var album: String
        public var albumArtist: String
        public var year: Int
        public var trackNumber: Int
        public var discNumber: Int
        public var durationMs: Int
        public var score: Int
        public var id: String { recordingId + "/" + releaseId }
    }

    public struct Release: Sendable, Equatable {
        public var id: String
        public var title: String
        public var artist: String
        public var score: Int
    }

    let http: HTTPClient
    var base = "https://musicbrainz.org/ws/2"

    public init(http: HTTPClient) { self.http = http }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// Recordings matching title (and artist / album when given), best first, one candidate per
    /// release. Candidates whose length differs by more than 10 s from `durationMs` are dropped.
    public func recordings(title: String, artist: String, album: String, durationMs: Int) async throws -> [Candidate] {
        guard !title.isEmpty else { return [] }
        var terms = ["recording:" + Self.quoted(title)]
        if !artist.isEmpty { terms.append("artist:" + Self.quoted(artist)) }
        if !album.isEmpty { terms.append("release:" + Self.quoted(album)) }
        let url = HTTPClient.url(base + "/recording/", [("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "15")])
        let root = try await http.jsonObject(from: url) as? [String: Any]
        var result: [Candidate] = []
        for recording in root?["recordings"] as? [[String: Any]] ?? [] {
            let length = recording["length"] as? Int ?? 0
            if durationMs > 0, length > 0, abs(length - durationMs) > 10_000 { continue }
            let credit = Self.artistCredit(recording["artist-credit"])
            for release in recording["releases"] as? [[String: Any]] ?? [] {
                let media = (release["media"] as? [[String: Any]])?.first
                let track = (media?["track"] as? [[String: Any]])?.first
                let date = release["date"] as? String ?? ""
                result.append(Candidate(
                    recordingId: recording["id"] as? String ?? "", releaseId: release["id"] as? String ?? "",
                    title: recording["title"] as? String ?? title, artist: credit,
                    album: release["title"] as? String ?? "",
                    albumArtist: Self.artistCredit(release["artist-credit"]).nilIfEmpty ?? credit,
                    year: Int(date.prefix(4)) ?? 0,
                    trackNumber: Int(track?["number"] as? String ?? "") ?? (track?["position"] as? Int ?? 0),
                    discNumber: media?["position"] as? Int ?? 0,
                    durationMs: length, score: recording["score"] as? Int ?? 0))
            }
        }
        return result
    }

    /// Releases for an album (cover lookups).
    public func releases(album: String, artist: String) async throws -> [Release] {
        guard !album.isEmpty else { return [] }
        var terms = ["release:" + Self.quoted(album)]
        if !artist.isEmpty && TextFolding.fold(artist) != TextFolding.fold(TrackText.variousArtists) {
            terms.append("artist:" + Self.quoted(artist))
        }
        let url = HTTPClient.url(base + "/release/", [("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "8")])
        let root = try await http.jsonObject(from: url) as? [String: Any]
        return (root?["releases"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return Release(id: id, title: r["title"] as? String ?? "", artist: Self.artistCredit(r["artist-credit"]),
                           score: r["score"] as? Int ?? 0)
        }
    }

    static func artistCredit(_ value: Any?) -> String {
        guard let credits = value as? [[String: Any]] else { return "" }
        return credits.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
    }
}

/// Finds cover images: Cover Art Archive for MusicBrainz releases, then the iTunes Search API.
public struct CoverFetcher: Sendable {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public enum Source: String, Sendable { case coverArtArchive = "Cover Art Archive", iTunes = "iTunes" }
        public var source: Source
        public var title: String
        public var artist: String
        public var imageURL: URL
        public var id: URL { imageURL }
    }

    let http: HTTPClient
    let musicBrainz: MusicBrainzClient

    public init(http: HTTPClient) {
        self.http = http
        musicBrainz = MusicBrainzClient(http: http)
    }

    /// Candidate covers for an album, best first. `releaseId` (from tags) is tried first.
    public func candidates(album: String, artist: String, releaseId: String? = nil) async -> [Candidate] {
        var result: [Candidate] = []
        var releaseIds: [(String, String, String)] = []
        if let releaseId, !releaseId.isEmpty { releaseIds.append((releaseId, album, artist)) }
        if let releases = try? await musicBrainz.releases(album: album, artist: artist) {
            let wanted = TextFolding.fold(album)
            for r in releases where r.score >= 80 && TextFolding.fold(r.title) == wanted && !releaseIds.contains(where: { $0.0 == r.id }) {
                releaseIds.append((r.id, r.title, r.artist))
            }
        }
        for (id, title, credit) in releaseIds.prefix(4) {
            // The archive answers 404 when a release has no front cover.
            let url = URL(string: "https://coverartarchive.org/release/\(id)/front-500")!
            if (try? await http.data(from: url)) != nil {
                result.append(Candidate(source: .coverArtArchive, title: title, artist: credit, imageURL: url))
            }
        }
        if let itunes = try? await iTunes(album: album, artist: artist) { result += itunes }
        return result
    }

    func iTunes(album: String, artist: String) async throws -> [Candidate] {
        let term = [artist, album].filter { !$0.isEmpty && TextFolding.fold($0) != TextFolding.fold(TrackText.variousArtists) }
            .joined(separator: " ")
        let url = HTTPClient.url("https://itunes.apple.com/search", [("term", term), ("entity", "album"), ("limit", "6")])
        let root = try await http.jsonObject(from: url) as? [String: Any]
        return (root?["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let art = r["artworkUrl100"] as? String,
                  let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else { return nil }
            return Candidate(source: .iTunes, title: r["collectionName"] as? String ?? "", artist: r["artistName"] as? String ?? "",
                             imageURL: url)
        }
    }

    public func imageData(_ candidate: Candidate) async throws -> Data {
        try await http.data(from: candidate.imageURL)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
