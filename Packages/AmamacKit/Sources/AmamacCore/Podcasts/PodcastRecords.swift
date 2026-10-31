import Foundation
import GRDB

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
