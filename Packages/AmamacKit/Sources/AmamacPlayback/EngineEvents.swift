import AmamacModels
import Foundation

/// The track the engine should play when the current one ends on its own.
public struct UpcomingTrack: Sendable, Equatable {
    public var itemID: PlaylistItemID
    public var url: URL
    /// ReplayGain + preamp in dB applied while this track renders.
    public var gainDB: Float
    /// The item this one follows; the engine only starts it after that item.
    public var after: PlaylistItemID?
    /// Gapless on the same deck, or a crossfade on the other one.
    public var transition: TrackTransition

    public init(itemID: PlaylistItemID, url: URL, gainDB: Float = 0, after: PlaylistItemID?,
                transition: TrackTransition = .gapless) {
        self.itemID = itemID
        self.url = url
        self.gainDB = gainDB
        self.after = after
        self.transition = transition
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
