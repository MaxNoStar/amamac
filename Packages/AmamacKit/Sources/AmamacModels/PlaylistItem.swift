import Foundation

public struct PlaylistItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Where a playlist entry comes from; shown by the "Source" column and emblem.
public enum PlaylistItemSource: String, Sendable, Hashable, Codable {
    case collection
    case file
    case stream
    case podcast
}

/// One entry in the playlist. Holds a snapshot of the track's metadata so rows render without
/// database access.
public struct PlaylistItem: Sendable, Hashable, Identifiable {
    public let id: PlaylistItemID
    public var track: Track
    public var statistics: TrackStatistics?
    public var source: PlaylistItemSource
    public var url: URL
    /// Live title reported by a stream (ICY metadata).
    public var streamTitle: String?

    public init(id: PlaylistItemID = PlaylistItemID(), track: Track, statistics: TrackStatistics? = nil,
                source: PlaylistItemSource = .collection, url: URL? = nil) {
        self.id = id
        self.track = track
        self.statistics = statistics
        self.source = source
        self.url = url ?? track.url
    }

    public static func stream(url: URL, title: String?, id: PlaylistItemID = PlaylistItemID()) -> PlaylistItem {
        var track = Track(path: url.absoluteString, title: title ?? url.absoluteString, format: "stream")
        track.updateDerivedFields()
        return PlaylistItem(id: id, track: track, source: .stream, url: url)
    }

    public var isStream: Bool { source == .stream || !url.isFileURL }
    public var trackId: Int64? { track.id }
    public var albumKey: String { track.albumKey }
    public var duration: TimeInterval { track.duration }
}
