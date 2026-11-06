import AmamacBase
import AmamacModels
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
        /// The release's date at the precision MusicBrainz gives (`1998`, `1998-03` or `1998-03-12`), or "".
        public var releaseDate: String
        public var trackNumber: Int
        /// Tracks on this track's medium (disc).
        public var trackTotal: Int
        public var discNumber: Int
        public var durationMs: Int
        public var score: Int
        public var id: String { recordingId + "/" + releaseId }
        public var year: Int { ReleaseDate(releaseDate)?.year ?? 0 }
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
        let url = try HTTPClient.url(base + "/recording/", [("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "15")])
        let root = try await http.jsonObject(from: url) as? [String: Any]
        var result: [Candidate] = []
        for recording in root?["recordings"] as? [[String: Any]] ?? [] {
            let length = recording["length"] as? Int ?? 0
            if durationMs > 0, length > 0, abs(length - durationMs) > 10_000 { continue }
            let credit = Self.artistCredit(recording["artist-credit"])
            for release in recording["releases"] as? [[String: Any]] ?? [] {
                let media = (release["media"] as? [[String: Any]])?.first
                let track = (media?["track"] as? [[String: Any]])?.first
                let date = ReleaseDate.lenient(release["date"] as? String)?.isoString ?? ""
                result.append(Candidate(
                    recordingId: recording["id"] as? String ?? "", releaseId: release["id"] as? String ?? "",
                    title: recording["title"] as? String ?? title, artist: credit,
                    album: release["title"] as? String ?? "",
                    albumArtist: Self.artistCredit(release["artist-credit"]).nilIfEmpty ?? credit,
                    releaseDate: date,
                    trackNumber: Int(track?["number"] as? String ?? "") ?? (track?["position"] as? Int ?? 0),
                    trackTotal: min(max(media?["track-count"] as? Int ?? 0, 0), 9999),
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
        let url = try HTTPClient.url(base + "/release/", [("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "8")])
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
