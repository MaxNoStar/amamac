import Foundation

/// Amarok's play-count and score rules.
public enum PlayStatistics {
    /// A play counts when a short track (≤ 30 s) reached its end, or when at least half of the
    /// track or five minutes of it were played.
    public static func countsAsPlay(playedSeconds: TimeInterval, duration: TimeInterval, reachedEnd: Bool) -> Bool {
        if duration > 0 && duration <= 30 { return reachedEnd }
        if reachedEnd { return true }
        if playedSeconds >= 300 { return true }
        return duration > 0 && playedSeconds / duration >= 0.5
    }

    /// Percentage of the track that was played (0...100).
    public static func percentage(playedSeconds: TimeInterval, duration: TimeInterval, reachedEnd: Bool) -> Double {
        if reachedEnd { return 100 }
        guard duration > 0 else { return 0 }
        return min(100, max(0, playedSeconds / duration * 100))
    }

    /// Score update: the first play averages the old score with the percentage played; later plays
    /// keep a running average weighted by the play count.
    public static func updatedScore(old: Double, playCount: Int, percentage: Double) -> Double {
        if playCount <= 0 { return (old + percentage) / 2 }
        return (old * Double(playCount) + percentage) / Double(playCount + 1)
    }

    /// Applies a finished or skipped playback to `stats`.
    public static func apply(to stats: inout TrackStatistics, playedSeconds: TimeInterval, duration: TimeInterval,
                             reachedEnd: Bool, at date: Date = Date()) {
        let pct = percentage(playedSeconds: playedSeconds, duration: duration, reachedEnd: reachedEnd)
        // Ignore accidental starts (less than a second played) so browsing doesn't tank scores.
        guard reachedEnd || playedSeconds >= 1 else { return }
        stats.score = updatedScore(old: stats.score, playCount: stats.playCount, percentage: pct)
        if countsAsPlay(playedSeconds: playedSeconds, duration: duration, reachedEnd: reachedEnd) {
            stats.playCount += 1
            if stats.firstPlayed == nil { stats.firstPlayed = date }
            stats.lastPlayed = date
        }
    }
}
