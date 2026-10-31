import FeedKit
import Foundation
import GRDB

// MARK: - Records

public struct PodcastChannel: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "podcast_channel"

    public enum DownloadPolicy: String, Codable, Sendable, CaseIterable {
        /// Stream episodes; download only when asked.
        case onRequest
        /// Download new episodes as soon as they appear.
        case automatic

        public var displayName: String {
            switch self {
            case .onRequest: "Stream, download on request"
            case .automatic: "Download new episodes automatically"
            }
        }
    }

    public var id: Int64?
    public var feedURL: String
    public var title: String
    public var subtitle: String?
    public var author: String?
    public var summary: String?
    public var imageURL: String?
    public var link: String?
    public var keywords: String?
    /// Included in automatic updates.
    public var autoScan: Bool
    public var downloadPolicy: DownloadPolicy
    /// Downloaded episodes to keep (0 keeps all).
    public var keepMax: Int
    public var saveLocation: String?
    public var subscribed: Date
    public var lastUpdated: Date?

    public init(feedURL: String, title: String) {
        self.feedURL = feedURL
        self.title = title
        autoScan = true
        downloadPolicy = .onRequest
        keepMax = 0
        subscribed = Date()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PodcastEpisode: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "podcast_episode"
    public var id: Int64?
    public var channelId: Int64
    public var guid: String
    public var title: String
    public var summary: String?
    public var pubDate: Date?
    public var durationMs: Int?
    public var enclosureURL: String
    public var enclosureType: String?
    public var fileSize: Int64?
    public var localPath: String?
    public var isNew: Bool
    public var isPlayed: Bool

    public var isDownloaded: Bool { localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    /// The downloaded file when there is one, else the feed's enclosure.
    public var playURL: URL? {
        if isDownloaded, let localPath { return URL(fileURLWithPath: localPath) }
        return URL(string: enclosureURL)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// A playlist item for the episode, titled with the channel as artist and album.
    public func playlistItem(channel: PodcastChannel?) -> PlaylistItem? {
        guard let url = playURL else { return nil }
        var track = Track(path: url.isFileURL ? url.path : url.absoluteString, title: title, artist: channel?.title ?? "",
                          album: channel?.title ?? "", durationMs: durationMs ?? 0, format: "podcast")
        track.comment = PodcastText.plain(summary ?? "")
        track.updateDerivedFields()
        return PlaylistItem(track: track, source: .podcast, url: url)
    }
}

// MARK: - Feed parsing

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

// MARK: - OPML

public enum OPML {
    public struct Outline: Sendable, Equatable {
        public var title: String
        public var feedURL: URL
        public init(title: String, feedURL: URL) {
            self.title = title
            self.feedURL = feedURL
        }
    }

    /// Every outline with an `xmlUrl`, however deeply nested.
    public static func parse(_ data: Data) throws -> [Outline] {
        final class Delegate: NSObject, XMLParserDelegate {
            var outlines: [Outline] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                guard name.lowercased() == "outline", let raw = attributes["xmlUrl"] ?? attributes["xmlurl"],
                      let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) else { return }
                outlines.append(Outline(title: attributes["title"] ?? attributes["text"] ?? url.absoluteString, feedURL: url))
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? PodcastFeedError.notAFeed }
        return delegate.outlines
    }

    public static func export(_ outlines: [Outline], title: String) -> Data {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>\(escape(title))</title></head>
              <body>

            """
        for o in outlines {
            xml += "    <outline type=\"rss\" text=\"\(escape(o.title))\" title=\"\(escape(o.title))\" xmlUrl=\"\(escape(o.feedURL.absoluteString))\"/>\n"
        }
        xml += "  </body>\n</opml>\n"
        return Data(xml.utf8)
    }
}

// MARK: - Service

/// Subscriptions, updates, downloads and OPML.
public struct PodcastService: Sendable {
    public static let changed = Notification.Name("amamacPodcastsChanged")
    let database: LibraryDatabase
    let http: HTTPClient
    public let downloadFolder: URL

    public init(database: LibraryDatabase, http: HTTPClient, downloadFolder: URL) {
        self.database = database
        self.http = http
        self.downloadFolder = downloadFolder
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    public func channels() -> [PodcastChannel] {
        (try? database.writer.read { try PodcastChannel.fetchAll($0, sql: "SELECT * FROM podcast_channel ORDER BY title COLLATE NOCASE") }) ?? []
    }

    public func channel(id: Int64) -> PodcastChannel? {
        try? database.writer.read { try PodcastChannel.fetchOne($0, key: id) }
    }

    public func episodes(channelId: Int64) -> [PodcastEpisode] {
        (try? database.writer.read {
            try PodcastEpisode.fetchAll($0, sql: "SELECT * FROM podcast_episode WHERE channelId = ? ORDER BY pubDate DESC, id DESC",
                                        arguments: [channelId])
        }) ?? []
    }

    public func episode(id: Int64) -> PodcastEpisode? {
        try? database.writer.read { try PodcastEpisode.fetchOne($0, key: id) }
    }

    /// New-episode counts per channel.
    public func newCounts() -> [Int64: Int] {
        let rows = (try? database.writer.read {
            try Row.fetchAll($0, sql: "SELECT channelId, COUNT(*) AS n FROM podcast_episode WHERE isNew GROUP BY channelId")
        }) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["channelId"] as Int64, $0["n"] as Int) })
    }

    /// Subscribes to a feed (or returns the existing subscription). Only the newest episode is marked new.
    @discardableResult
    public func subscribe(feedURL: URL) async throws -> PodcastChannel {
        if let existing = channels().first(where: { $0.feedURL == feedURL.absoluteString }) { return existing }
        let parsed = try PodcastFeedParser.parse(try await http.data(from: feedURL, useCache: false))
        let channel = try await database.writer.write { db -> PodcastChannel in
            var channel = PodcastChannel(feedURL: feedURL.absoluteString, title: parsed.title)
            Self.apply(parsed, to: &channel)
            channel.lastUpdated = Date()
            try channel.insert(db)
            let newest = parsed.episodes.max { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }?.guid
            for e in parsed.episodes { try Self.insert(e, channelId: channel.id!, isNew: e.guid == newest, db: db) }
            return channel
        }
        notify()
        return channel
    }

    /// Fetches the feed and adds episodes not seen before (marked new). Returns them.
    @discardableResult
    public func update(channelId: Int64) async throws -> [PodcastEpisode] {
        guard var channel = channel(id: channelId), let url = URL(string: channel.feedURL) else { return [] }
        let parsed = try PodcastFeedParser.parse(try await http.data(from: url, useCache: false))
        Self.apply(parsed, to: &channel)
        channel.lastUpdated = Date()
        let refreshed = channel
        let added = try await database.writer.write { db -> [PodcastEpisode] in
            try refreshed.update(db)
            let known = Set(try String.fetchAll(db, sql: "SELECT guid FROM podcast_episode WHERE channelId = ?", arguments: [channelId]))
            var added: [PodcastEpisode] = []
            for e in parsed.episodes where !known.contains(e.guid) {
                added.append(try Self.insert(e, channelId: channelId, isNew: true, db: db))
            }
            return added
        }
        notify()
        return added
    }

    /// Updates every channel with automatic updates on (or all, when `includeManual`).
    public func updateAll(includeManual: Bool = true) async -> (added: [PodcastEpisode], failures: [String]) {
        var added: [PodcastEpisode] = []
        var failures: [String] = []
        for channel in channels() where includeManual || channel.autoScan {
            do { added += try await update(channelId: channel.id!) } catch { failures.append(channel.title) }
        }
        return (added, failures)
    }

    private static func apply(_ parsed: ParsedFeed, to channel: inout PodcastChannel) {
        channel.title = parsed.title
        channel.subtitle = parsed.subtitle
        channel.author = parsed.author
        channel.summary = parsed.summary
        channel.imageURL = parsed.imageURL
        channel.link = parsed.link
        channel.keywords = parsed.keywords
    }

    @discardableResult
    private static func insert(_ e: ParsedEpisode, channelId: Int64, isNew: Bool, db: Database) throws -> PodcastEpisode {
        var episode = PodcastEpisode(channelId: channelId, guid: e.guid, title: e.title, summary: e.summary, pubDate: e.pubDate,
                                     durationMs: e.durationMs, enclosureURL: e.enclosureURL, enclosureType: e.enclosureType,
                                     fileSize: e.fileSize, localPath: nil, isNew: isNew, isPlayed: false)
        try episode.insert(db, onConflict: .ignore)
        return episode
    }

    public func save(_ channel: PodcastChannel) {
        try? database.writer.write { try channel.update($0) }
        notify()
    }

    public func unsubscribe(channelId: Int64, deleteDownloads: Bool) {
        if deleteDownloads {
            for e in episodes(channelId: channelId) where e.isDownloaded { try? FileManager.default.removeItem(atPath: e.localPath!) }
        }
        try? database.writer.write { _ = try PodcastChannel.deleteOne($0, key: channelId) }
        notify()
    }

    public func setPlayed(_ episodeIds: [Int64], played: Bool) {
        try? database.writer.write { db in
            for id in episodeIds {
                try db.execute(sql: "UPDATE podcast_episode SET isPlayed = ?, isNew = 0 WHERE id = ?", arguments: [played, id])
            }
        }
        notify()
    }

    public func setNew(_ episodeIds: [Int64], isNew: Bool) {
        try? database.writer.write { db in
            for id in episodeIds { try db.execute(sql: "UPDATE podcast_episode SET isNew = ? WHERE id = ?", arguments: [isNew, id]) }
        }
        notify()
    }

    /// Where an episode is saved: <folder>/<channel>/<file name from the enclosure>.
    public func destination(for episode: PodcastEpisode, channel: PodcastChannel) -> URL {
        let folder = channel.saveLocation.map { URL(fileURLWithPath: $0) }
            ?? downloadFolder.appendingPathComponent(Self.safeName(channel.title), isDirectory: true)
        var name = URL(string: episode.enclosureURL)?.lastPathComponent ?? ""
        if name.isEmpty || name == "/" || !name.contains(".") {
            let ext = episode.enclosureType.flatMap { $0.contains("mp4") || $0.contains("m4a") ? "m4a" : nil } ?? "mp3"
            name = Self.safeName(episode.title) + "." + ext
        }
        var url = folder.appendingPathComponent(Self.safeName(name))
        // Feeds that reuse one file name for every episode get the date in front.
        if FileManager.default.fileExists(atPath: url.path), episode.localPath != url.path {
            let stamp = episode.pubDate.map { ISO8601DateFormatter.string(from: $0, timeZone: .gmt, formatOptions: .withFullDate) } ?? String(episode.id ?? 0)
            url = folder.appendingPathComponent(stamp + " " + Self.safeName(name))
        }
        return url
    }

    /// Downloads an episode, reporting progress (0...1), and records the file.
    @discardableResult
    public func download(_ episode: PodcastEpisode, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PodcastEpisode {
        guard let channel = channel(id: episode.channelId), let url = URL(string: episode.enclosureURL) else { throw HTTPError.invalidResponse }
        let target = destination(for: episode, channel: channel)
        try await http.download(from: url, to: target, progress: progress)
        var updated = episode
        updated.localPath = target.path
        let saved = updated
        try await database.writer.write { try saved.update($0) }
        prune(channelId: channel.id!)
        notify()
        return updated
    }

    public func deleteDownload(_ episode: PodcastEpisode) {
        if let path = episode.localPath { try? FileManager.default.removeItem(atPath: path) }
        try? database.writer.write { db in
            try db.execute(sql: "UPDATE podcast_episode SET localPath = NULL WHERE id = ?", arguments: [episode.id])
        }
        notify()
    }

    /// Keeps only the newest `keepMax` downloads of a channel.
    public func prune(channelId: Int64) {
        guard let channel = channel(id: channelId), channel.keepMax > 0 else { return }
        let downloaded = episodes(channelId: channelId).filter(\.isDownloaded)
        for episode in downloaded.dropFirst(channel.keepMax) { deleteDownload(episode) }
    }

    // MARK: OPML

    public func importOPML(_ url: URL) async throws -> (added: Int, failed: [String]) {
        let outlines = try OPML.parse(try Data(contentsOf: url))
        var added = 0
        var failed: [String] = []
        for outline in outlines {
            do {
                try await subscribe(feedURL: outline.feedURL)
                added += 1
            } catch {
                failed.append(outline.title)
            }
        }
        return (added, failed)
    }

    public func exportOPML(to url: URL) throws {
        let outlines = channels().compactMap { c in URL(string: c.feedURL).map { OPML.Outline(title: c.title, feedURL: $0) } }
        try OPML.export(outlines, title: "Amamac Podcasts").write(to: url, options: .atomic)
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\0")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }
}

// MARK: - Podcast directory

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
