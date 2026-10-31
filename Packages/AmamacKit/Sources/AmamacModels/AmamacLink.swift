import AmamacBase
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
            // Links come from other apps and web pages, so the position must be a real one.
            let seconds = query["pos"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            self = .position(trackId: id, seconds: seconds)
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
        c.escapePlusInQuery()
        return c.url!
    }
}
