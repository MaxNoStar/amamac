import Foundation

/// Bar levels (0...1) with gravity and peak hold, for spectrum analyzers. Bars rise at once and fall
/// at a speed scaled by the time since the last frame, so they drop equally fast at any frame rate.
public struct SpectrumDynamics: Sendable {
    public private(set) var levels: [Float] = []
    public private(set) var peaks: [Float] = []
    /// Seconds since each peak was last pushed up.
    private var peakAge: [Double] = []

    /// How long a peak stays put before it starts to fall.
    public static let peakHold: Double = 0.4

    public init() {}

    /// Level lost per second at `fallSpeed` 1 (very slow) ... 5 (very fast).
    public static func fallPerSecond(_ fallSpeed: Int) -> Float { Float(max(1, min(5, fallSpeed))) * 0.36 }

    /// Moves the bars towards `target`. A change in the number of bands starts over at `target`.
    public mutating func advance(to target: [Float], elapsed: Double, fallSpeed: Int) {
        let bands = target.count
        if levels.count != bands {
            levels = target
            peaks = target
            peakAge = [Double](repeating: 0, count: bands)
            return
        }
        let fall = Self.fallPerSecond(fallSpeed) * Float(elapsed)
        for i in 0..<bands {
            levels[i] = target[i] >= levels[i] ? target[i] : max(target[i], levels[i] - fall)
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                peakAge[i] = 0
            } else {
                peakAge[i] += elapsed
                // Hold briefly, then fall slower than the bars.
                if peakAge[i] > Self.peakHold { peaks[i] = max(levels[i], peaks[i] - fall * 0.6) }
            }
        }
    }
}
