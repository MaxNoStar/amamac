import AmamacBase
import AmamacModels
import Foundation

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
