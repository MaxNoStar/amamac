import AmamacModels
import Foundation

/// How the playing track hands over to the next one when it plays to its end.
public enum TrackTransition: Sendable, Equatable {
    /// Back to back on one player, without a gap.
    case gapless
    /// The next track fades in while this one fades out, overlapping for `seconds`.
    case crossfade(seconds: Double)
}

/// Decides which automatic track changes crossfade and shapes the fade. Manual changes (Next,
/// double-click) never crossfade; a fade that can't fit falls back to gapless.
public struct CrossfadePolicy: Sendable, Equatable {
    /// Fades shorter than this sound like a glitch rather than a blend, so they stay gapless.
    public static let shortestFade: TimeInterval = 1
    public static let longestFade: TimeInterval = 12

    public var enabled: Bool
    public var seconds: TimeInterval
    /// Tracks of one album follow each other gaplessly (live albums, DJ mixes, classical).
    public var keepAlbumsGapless: Bool

    public init(enabled: Bool = false, seconds: TimeInterval = 5, keepAlbumsGapless: Bool = true) {
        self.enabled = enabled
        self.seconds = seconds
        self.keepAlbumsGapless = keepAlbumsGapless
    }

    public func transition(from current: Track, to next: Track) -> TrackTransition {
        guard enabled, !(keepAlbumsGapless && Self.sameAlbum(current, next)),
              let length = Self.fadeLength(requested: seconds, outgoing: current.duration, incoming: next.duration)
        else { return .gapless }
        return .crossfade(seconds: length)
    }

    /// Same non-empty album title and the same album artist, compared like the collection groups albums.
    public static func sameAlbum(_ a: Track, _ b: Track) -> Bool {
        guard !a.album.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return key(a) == key(b)
    }

    private static func key(_ track: Track) -> String {
        Track.albumKey(album: track.album, albumArtist: track.albumArtist, artist: track.artist, compilation: track.compilation)
    }

    /// The fade to use, at most half of either track (unknown durations, 0 or less, don't limit it);
    /// nil when that leaves less than `shortestFade`.
    public static func fadeLength(requested: TimeInterval, outgoing: TimeInterval?, incoming: TimeInterval?) -> TimeInterval? {
        guard requested.isFinite else { return nil }
        var length = min(requested, longestFade)
        for duration in [outgoing, incoming] {
            if let duration, duration.isFinite, duration > 0 { length = min(length, duration / 2) }
        }
        return length >= shortestFade ? length : nil
    }

    /// Equal-power gains at `progress` (0...1) through a fade: `outgoing² + incoming² = 1`, so the
    /// loudness holds steady instead of dipping halfway.
    public static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        guard progress.isFinite, progress < 1 else { return (0, 1) }
        guard progress > 0 else { return (1, 0) }
        let angle = progress * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }
}
