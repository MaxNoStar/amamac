import FeedKit
import Foundation

public struct ParsedFeed: Sendable {
    public var title: String
    public var subtitle: String?
    public var author: String?
    public var summary: String?
    public var imageURL: String?
    public var link: String?
    public var keywords: String?
    public var episodes: [ParsedEpisode]
}

public struct ParsedEpisode: Sendable, Equatable {
    public var guid: String
    public var title: String
    public var summary: String?
    public var pubDate: Date?
    public var durationMs: Int?
    public var enclosureURL: String
    public var enclosureType: String?
    public var fileSize: Int64?
}

public enum PodcastFeedError: Error, LocalizedError {
    case notAFeed
    case noEpisodes

    public var errorDescription: String? {
        switch self {
        case .notAFeed: "This address does not point to a podcast feed."
        case .noEpisodes: "The feed has no audio episodes."
        }
    }
}

public enum PodcastFeedParser {
    public static func parse(_ data: Data) throws -> ParsedFeed {
        let feed: Feed
        do { feed = try Feed(data: data) } catch { throw PodcastFeedError.notAFeed }
        switch feed {
        case .rss(let rss):
            guard let channel = rss.channel else { throw PodcastFeedError.notAFeed }
            let episodes = (channel.items ?? []).compactMap { item -> ParsedEpisode? in
                guard let enclosure = item.enclosure?.attributes, let url = enclosure.url, !url.isEmpty else { return nil }
                let guid = item.guid?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedEpisode(guid: guid?.isEmpty == false ? guid! : url,
                                     title: item.title ?? item.iTunes?.title ?? "Untitled Episode",
                                     summary: item.iTunes?.summary ?? item.content?.encoded ?? item.description,
                                     pubDate: item.pubDate,
                                     durationMs: item.iTunes?.duration.map { Int($0 * 1000) },
                                     enclosureURL: url, enclosureType: enclosure.type,
                                     fileSize: enclosure.length.flatMap { $0 > 0 ? $0 : nil })
            }
            return ParsedFeed(title: channel.title ?? channel.iTunes?.title ?? "Untitled Podcast",
                              subtitle: channel.iTunes?.subtitle, author: channel.iTunes?.author ?? channel.managingEditor,
                              summary: channel.iTunes?.summary ?? channel.description,
                              imageURL: channel.iTunes?.image?.attributes?.href ?? channel.image?.url, link: channel.link,
                              keywords: channel.iTunes?.keywords, episodes: episodes)
        case .atom(let atom):
            let episodes = (atom.entries ?? []).compactMap { entry -> ParsedEpisode? in
                guard let link = entry.links?.first(where: { $0.attributes?.rel == "enclosure" })?.attributes,
                      let url = link.href else { return nil }
                return ParsedEpisode(guid: entry.id ?? url, title: entry.title ?? "Untitled Episode", summary: entry.summary?.text,
                                     pubDate: entry.published ?? entry.updated, durationMs: nil, enclosureURL: url,
                                     enclosureType: link.type, fileSize: link.length)
            }
            return ParsedFeed(title: atom.title?.text ?? "Untitled Podcast", subtitle: atom.subtitle?.text,
                              author: atom.authors?.first?.name, summary: nil, imageURL: atom.logo ?? atom.icon,
                              link: atom.links?.first?.attributes?.href, keywords: nil, episodes: episodes)
        default:
            throw PodcastFeedError.notAFeed
        }
    }
}

/// Feed text is often HTML; lists show it as plain text.
public enum PodcastText {
    public static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
