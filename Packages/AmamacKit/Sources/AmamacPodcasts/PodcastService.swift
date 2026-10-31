import AmamacBase
import AmamacDatabase
import AmamacWeb
import FeedKit
import Foundation
import GRDB

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
