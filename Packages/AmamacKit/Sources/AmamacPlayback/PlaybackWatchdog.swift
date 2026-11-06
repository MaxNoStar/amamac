import Foundation

/// Notices local playback that has silently stopped while the app still shows it playing (an
/// event the engine never sent, an engine that didn't come back after a hiccup) and says how to
/// recover. The controller feeds it from its position timer while it believes a local track is
/// playing, and resets it on every deliberate change (play, pause, seek, stop).
public struct PlaybackWatchdog: Sendable {
    public enum Action: Sendable, Equatable {
        case none
        /// The track had (nearly) ended: move on to the next one.
        case advance
        /// Start the same track again from this position.
        case restart(at: TimeInterval)
    }

    /// How long the position may stand still while the engine says it plays.
    public var stallLimit: TimeInterval = 3
    /// How long the engine may report not playing at all.
    public var stoppedLimit: TimeInterval = 1
    /// Within this much of the end a stall counts as the end of the track.
    public var nearEnd: TimeInterval = 2

    private var position: TimeInterval?
    private var since: Date?

    public init() {}

    /// Forgets what it has seen, after the controller changed playback on purpose.
    public mutating func reset() {
        position = nil
        since = nil
    }

    public mutating func check(enginePlaying: Bool, position now: TimeInterval?, duration: TimeInterval?, at time: Date) -> Action {
        if let now, enginePlaying, now > (position ?? -1) + 0.01 {
            position = now
            since = time
            return .none
        }
        guard let since else {
            position = now
            self.since = time
            return .none
        }
        let limit = enginePlaying ? stallLimit : stoppedLimit
        guard time.timeIntervalSince(since) >= limit else { return .none }
        let at = now ?? position ?? 0
        reset()
        if let duration, duration > 0, duration - at <= nearEnd { return .advance }
        return .restart(at: at)
    }
}
