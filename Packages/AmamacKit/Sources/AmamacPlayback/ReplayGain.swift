import AmamacModels
import Foundation

public enum ReplayGainMode: String, CaseIterable, Sendable, Codable {
    case off, track, album

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }
}

public enum ReplayGain {
    /// Gain in dB for `track`, including the pre-amp, limited so the peak doesn't clip.
    public static func gain(for track: Track, mode: ReplayGainMode, preamp: Double = 0, fallback: Double = 0) -> Float {
        guard mode != .off else { return 0 }
        let gain: Double?
        let peak: Double?
        switch mode {
        case .album:
            gain = track.rgAlbumGain ?? track.rgTrackGain
            peak = track.rgAlbumPeak ?? track.rgTrackPeak
        default:
            gain = track.rgTrackGain ?? track.rgAlbumGain
            peak = track.rgTrackPeak ?? track.rgAlbumPeak
        }
        guard let gain else { return Float(fallback) }
        var total = gain + preamp
        if let peak, peak > 0 {
            let maxGain = -20 * log10(peak)
            total = min(total, maxGain)
        }
        return Float(max(-30, min(15, total)))
    }
}
