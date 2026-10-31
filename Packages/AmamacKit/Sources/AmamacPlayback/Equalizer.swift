import Foundation

/// A 10-band equalizer setting. Bands follow `LocalAudioEngine.equalizerFrequencies`; values are
/// dB in -12...12. The preset names follow Amarok's list; the curves are Amamac's own.
public struct EqualizerPreset: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var preamp: Double
    public var bands: [Double]
    public var id: String { name }

    public init(name: String, preamp: Double, bands: [Double]) {
        self.name = name
        self.preamp = preamp
        self.bands = Self.normalized(bands)
    }

    public static let bandCount = 10
    public static let range: ClosedRange<Double> = -12...12
    /// The preset that holds whatever the user set by hand.
    public static let manualName = "Manual"
    public static let zeroName = "Zero"

    static func normalized(_ bands: [Double]) -> [Double] {
        let padded = Array(bands.prefix(bandCount)) + Array(repeating: 0, count: max(0, bandCount - bands.count))
        return padded.map { min(range.upperBound, max(range.lowerBound, $0)) }
    }

    /// Flattened as preamp followed by the bands, for storing in user defaults.
    public var values: [Double] { [preamp] + bands }

    public init(name: String, values: [Double]) {
        self.init(name: name, preamp: values.first ?? 0, bands: Array(values.dropFirst()))
    }

    /// Built-in curves (29 Hz … 15 kHz). Boosting presets carry a negative preamp so loud passages
    /// keep some headroom.
    public static let builtIn: [EqualizerPreset] = [
        EqualizerPreset(name: manualName, preamp: 0, bands: Array(repeating: 0, count: bandCount)),
        EqualizerPreset(name: "Classical", preamp: 0, bands: [0, 0, 0, 0, 0, 0, -1, -2.5, -4, -5.5]),
        EqualizerPreset(name: "Club", preamp: -2, bands: [1, 2, 4, 3.5, 2.5, 3, 2, 1, 0, 0]),
        EqualizerPreset(name: "Dance", preamp: -3, bands: [6, 5, 3, 0.5, -1, -1.5, 0, 2, 3, 3]),
        EqualizerPreset(name: "Full Bass", preamp: -4, bands: [7.5, 7, 5, 3, 1, -1, -2, -3, -3.5, -3.5]),
        EqualizerPreset(name: "Full Treble", preamp: -4, bands: [-4, -4, -3, -1.5, 0, 2, 4.5, 7, 8, 8.5]),
        EqualizerPreset(name: "Full Bass + Treble", preamp: -3.5, bands: [6, 5, 2, 0, -2, -1.5, 1, 4, 6, 7]),
        EqualizerPreset(name: "Laptop/Headphones", preamp: -3, bands: [3, 5, 3, -0.5, -1, 0, 2, 3.5, 5, 6]),
        EqualizerPreset(name: "Large Hall", preamp: -2.5, bands: [5, 5, 3.5, 2, 0, -1.5, -2, -1, 0, 1]),
        EqualizerPreset(name: "Live", preamp: -1.5, bands: [-2, 0, 1.5, 2.5, 3, 3, 2.5, 2, 2, 1]),
        EqualizerPreset(name: "Party", preamp: -2.5, bands: [5, 4, 1, 0, 0, 0, 1, 2, 4, 5]),
        EqualizerPreset(name: "Pop", preamp: -2, bands: [-1, 1, 3, 4, 3.5, 2, 0, -1, -1, -1.5]),
        EqualizerPreset(name: "Reggae", preamp: -2, bands: [4, 4, 1.5, -1.5, -2.5, -1, 1, 3, 2.5, 1]),
        EqualizerPreset(name: "Rock", preamp: -2.5, bands: [5, 4, 2, -1.5, -2.5, -1, 2, 4, 5, 5]),
        EqualizerPreset(name: "Ska", preamp: -2.5, bands: [-1, -2, -1, 0, 1.5, 3, 4, 4.5, 5, 4]),
        EqualizerPreset(name: "Soft", preamp: -1, bands: [2, 1.5, 1, 0, -1, -1, 0, 1, 2, 3]),
        EqualizerPreset(name: "Soft Rock", preamp: -1.5, bands: [2.5, 2, 1, 0, -1.5, -2, -1, 1, 2.5, 3.5]),
        EqualizerPreset(name: "Techno", preamp: -3, bands: [5.5, 4.5, 2, -1, -2, -1, 1, 3.5, 5, 4.5]),
        EqualizerPreset(name: zeroName, preamp: 0, bands: Array(repeating: 0, count: bandCount)),
    ]

    public static func builtIn(named name: String) -> EqualizerPreset? { builtIn.first { $0.name == name } }
}
