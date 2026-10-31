import AmamacWeb
import Foundation

/// Podcast search through the iTunes Search API (no account needed).
public struct PodcastDirectoryClient: Sendable {
    public struct Result: Decodable, Sendable, Hashable, Identifiable {
        public var collectionId: Int
        public var collectionName: String
        public var artistName: String?
        public var feedUrl: String?
        public var artworkUrl100: String?
        public var artworkUrl600: String?
        public var primaryGenreName: String?
        public var trackCount: Int?
        public var id: Int { collectionId }
    }

    let http: HTTPClient
    public init(http: HTTPClient) { self.http = http }

    public func search(_ term: String, limit: Int = 50) async throws -> [Result] {
        struct Response: Decodable { var results: [Result] }
        let url = HTTPClient.url("https://itunes.apple.com/search", [("media", "podcast"), ("entity", "podcast"),
                                                                     ("term", term), ("limit", String(limit))])
        return try await http.json(Response.self, from: url).results.filter { $0.feedUrl != nil }
    }
}
