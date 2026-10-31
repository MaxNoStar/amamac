import AmamacModels
import Foundation

/// The track the engine should enqueue when the current one finishes decoding.
public struct UpcomingTrack: Sendable, Equatable {
    public var itemID: PlaylistItemID
    public var url: URL
    /// ReplayGain + preamp in dB applied while this track renders.
    public var gainDB: Float
    /// The item this one follows; the bridge only enqueues it after that item's decoder.
    public var after: PlaylistItemID?

    public init(itemID: PlaylistItemID, url: URL, gainDB: Float = 0, after: PlaylistItemID?) {
        self.itemID = itemID
        self.url = url
        self.gainDB = gainDB
        self.after = after
    }
}

public enum EnginePlaybackState: Sendable, Equatable {
    case stopped, playing, paused
}

/// Events from the audio engines, delivered in order on one `AsyncStream`.
public enum EngineEvent: Sendable, Equatable {
    /// A new item started rendering (`nil` when playback ran out).
    case nowPlayingChanged(PlaylistItemID?)
    case stateChanged(EnginePlaybackState)
    /// Rendering finished and nothing else is queued.
    case endOfAudio
    case error(String, PlaylistItemID?)
    /// A stream reported a new title (ICY metadata).
    case streamTitle(String, PlaylistItemID)
    /// A stream is buffering / became ready.
    case buffering(Bool)
}
