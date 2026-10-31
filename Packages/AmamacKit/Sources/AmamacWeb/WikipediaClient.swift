import AmamacBase
import AmamacModels
import Foundation

/// Finds and fetches Wikipedia articles for the Wikipedia applet. Artists and composers are
/// resolved through MusicBrainz → Wikidata → the language's sitelink; everything else (and any
/// artist MusicBrainz does not know) falls back to a Wikipedia search.
public struct WikipediaClient: Sendable {
    public enum Subject: String, CaseIterable, Sendable {
        case artist, composer, album, track
    }

    public struct Page: Sendable, Equatable {
        public var title: String
        public var language: String
        /// Article body HTML (without the surrounding document).
        public var html: String
        public var url: URL { URL(string: "https://\(language).wikipedia.org/wiki/" + WikipediaClient.encodeTitle(title))! }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case nothingToLookUp
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .nothingToLookUp: "There is nothing to look up for this track."
            case .notFound(let what): "No Wikipedia article was found for “\(what)”."
            }
        }
    }

    let http: HTTPClient
    public var language: String

    public init(http: HTTPClient, language: String = "en") {
        self.http = http
        self.language = language.isEmpty ? "en" : language
    }

    public static func encodeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? title
    }

    /// The text the subject looks up for `track` (shown in the applet's header).
    public static func query(for subject: Subject, track: Track) -> String? {
        let value: String
        switch subject {
        case .artist: value = track.artist.isEmpty ? track.effectiveAlbumArtist : track.artist
        case .composer: value = track.composer
        case .album: value = track.album
        case .track: value = track.title
        }
        return value.isEmpty ? nil : value
    }

    public func page(for subject: Subject, track: Track) async throws -> Page {
        guard let query = Self.query(for: subject, track: track) else { throw Failure.nothingToLookUp }
        var title: String?
        switch subject {
        case .artist, .composer:
            title = try? await titleFromMusicBrainz(artist: query)
            if title == nil {
                let hint = subject == .composer ? "composer" : "(band OR musician OR singer OR rapper OR composer)"
                title = try await search(language == "en" ? "\"\(query)\" \(hint)" : "\"\(query)\"")
            }
        case .album:
            title = try await search(language == "en" ? "\"\(query)\" album \(track.effectiveAlbumArtist)" : "\"\(query)\" \(track.effectiveAlbumArtist)")
        case .track:
            title = try await search(language == "en" ? "\"\(query)\" song \(track.artist)" : "\"\(query)\" \(track.artist)")
        }
        guard let title else { throw Failure.notFound(query) }
        return try await page(title: title)
    }

    /// Fetches an article by title (also used for links followed inside the applet).
    public func page(title: String) async throws -> Page {
        let url = try HTTPClient.url("https://\(language).wikipedia.org/w/api.php", [
            ("action", "parse"), ("page", title), ("prop", "text"), ("format", "json"), ("formatversion", "2"),
            ("redirects", "1"), ("disableeditsection", "1"), ("disabletoc", "1"),
        ])
        guard let root = try await http.jsonObject(from: url) as? [String: Any],
              let parse = root["parse"] as? [String: Any], let html = parse["text"] as? String else {
            throw Failure.notFound(title)
        }
        return Page(title: parse["title"] as? String ?? title, language: language, html: html)
    }

    /// Title of the best search hit, or nil.
    func search(_ query: String) async throws -> String? {
        let url = try HTTPClient.url("https://\(language).wikipedia.org/w/api.php", [
            ("action", "query"), ("list", "search"), ("srsearch", query), ("srlimit", "1"),
            ("format", "json"), ("formatversion", "2"),
        ])
        let root = try await http.jsonObject(from: url) as? [String: Any]
        let results = (root?["query"] as? [String: Any])?["search"] as? [[String: Any]]
        return results?.first?["title"] as? String
    }

    /// MusicBrainz artist (exact name match) → its Wikidata item → the sitelink for `language`.
    func titleFromMusicBrainz(artist: String) async throws -> String? {
        let searchURL = try HTTPClient.url("https://musicbrainz.org/ws/2/artist/", [
            ("query", "artist:\"\(artist.replacingOccurrences(of: "\"", with: ""))\""), ("fmt", "json"), ("limit", "5"),
        ])
        let root = try await http.jsonObject(from: searchURL) as? [String: Any]
        let artists = root?["artists"] as? [[String: Any]] ?? []
        let wanted = TextFolding.fold(artist)
        guard let match = artists.first(where: { TextFolding.fold($0["name"] as? String ?? "") == wanted && ($0["score"] as? Int ?? 0) >= 90 }),
              let id = match["id"] as? String else { return nil }

        let lookupURL = try HTTPClient.url("https://musicbrainz.org/ws/2/artist/\(id)", [("inc", "url-rels"), ("fmt", "json")])
        let lookup = try await http.jsonObject(from: lookupURL) as? [String: Any]
        let relations = lookup?["relations"] as? [[String: Any]] ?? []
        let resources = relations.compactMap { relation -> (String, String)? in
            guard let type = relation["type"] as? String, let url = relation["url"] as? [String: Any],
                  let resource = url["resource"] as? String else { return nil }
            return (type, resource)
        }
        if let wikidata = resources.first(where: { $0.0 == "wikidata" })?.1,
           let qid = wikidata.split(separator: "/").last.map(String.init), qid.hasPrefix("Q") {
            let entityURL = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")!
            let entity = try await http.jsonObject(from: entityURL) as? [String: Any]
            let item = (entity?["entities"] as? [String: Any])?[qid] as? [String: Any]
            let sitelink = (item?["sitelinks"] as? [String: Any])?["\(language)wiki"] as? [String: Any]
            if let title = sitelink?["title"] as? String { return title }
        }
        // Older MusicBrainz entries link Wikipedia directly.
        let prefix = "https://\(language).wikipedia.org/wiki/"
        if let direct = resources.first(where: { $0.0 == "wikipedia" && $0.1.hasPrefix(prefix) })?.1 {
            return String(direct.dropFirst(prefix.count)).removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
        }
        return nil
    }
}
