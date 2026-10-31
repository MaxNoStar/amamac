import Foundation

/// `amamac://navigate/…` links, used by bookmarks and accepted from other apps.
public enum AmamacLink: Equatable, Sendable {
    /// Play a collection track from a position.
    case position(trackId: Int64, seconds: Double)
    /// Local Music with a filter and grouping levels (`CollectionLevel` raw values).
    case collection(filter: String, levels: [String])
    /// Another Media Sources category, optionally at a folder (Files).
    case category(String, path: String?)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "amamac", url.host?.lowercased() == "navigate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let target = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch target {
        case "position":
            guard let id = query["track"].flatMap(Int64.init) else { return nil }
            self = .position(trackId: id, seconds: query["pos"].flatMap(Double.init) ?? 0)
        case "collection", "localMusic":
            let levels = (query["levels"] ?? "").split(separator: "-").map(String.init)
            self = .collection(filter: query["filter"] ?? "", levels: levels)
        case "":
            return nil
        default:
            self = .category(target, path: query["path"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "amamac"
        c.host = "navigate"
        switch self {
        case .position(let id, let seconds):
            c.path = "/position"
            c.queryItems = [URLQueryItem(name: "track", value: String(id)), URLQueryItem(name: "pos", value: String(Int(seconds)))]
        case .collection(let filter, let levels):
            c.path = "/collection"
            c.queryItems = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "levels", value: levels.joined(separator: "-"))]
        case .category(let name, let path):
            c.path = "/" + name
            if let path { c.queryItems = [URLQueryItem(name: "path", value: path)] }
        }
        // Keep "+" literal-safe: URLComponents leaves it unescaped in queries.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}

extension BookmarkStore {
    /// Saves a Media Sources view as a bookmark.
    @discardableResult
    public func addView(name: String, link: AmamacLink) -> BookmarkRecord? {
        add(BookmarkRecord(kind: .view, name: name, url: link.url.absoluteString))
    }
}
