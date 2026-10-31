import Foundation

/// Conversions for numbers read from files, feeds, headers and links, which can be huge, negative
/// or not a number. They return nil where a plain conversion would trap.
public enum SafeNumbers {
    /// The longest duration accepted, in seconds (about 115 days).
    public static let maxSeconds: Double = 10_000_000

    /// Milliseconds for a duration in seconds; nil when negative, not finite or absurdly long.
    public static func milliseconds(seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds < maxSeconds else { return nil }
        return Int((seconds * 1000).rounded())
    }

    /// Milliseconds for a whole number of seconds; nil when negative or absurdly long.
    public static func milliseconds(seconds: Int) -> Int? {
        guard seconds >= 0, Double(seconds) < maxSeconds else { return nil }
        return seconds * 1000
    }

    /// `value` rounded to an Int within `range`; nil when not finite or outside it.
    public static func int(_ value: Double, in range: ClosedRange<Int> = 0...Int(Int32.max)) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound) else { return nil }
        return Int(rounded)
    }
}
