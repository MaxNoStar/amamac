import Foundation
import Testing
@testable import AmamacCore

struct AudioSettingsTests {
    @Test func equalizerPresetsCoverAmaroksNames() {
        let names = EqualizerPreset.builtIn.map(\.name)
        #expect(names == ["Manual", "Classical", "Club", "Dance", "Full Bass", "Full Treble", "Full Bass + Treble",
                          "Laptop/Headphones", "Large Hall", "Live", "Party", "Pop", "Reggae", "Rock", "Ska", "Soft",
                          "Soft Rock", "Techno", "Zero"])
        for preset in EqualizerPreset.builtIn {
            #expect(preset.bands.count == LocalAudioEngine.equalizerFrequencies.count)
            #expect(preset.bands.allSatisfy { EqualizerPreset.range.contains($0) })
            // Boosting presets leave headroom: preamp plus the largest boost stays modest.
            #expect(preset.preamp + (preset.bands.max() ?? 0) <= 6, "\(preset.name) is too hot")
        }
        #expect(EqualizerPreset.builtIn(named: "Zero")?.bands.allSatisfy { $0 == 0 } == true)
    }

    @Test func presetValuesRoundTripAndClamp() {
        let preset = EqualizerPreset(name: "Mine", preamp: -2, bands: [20, -20, 1])
        #expect(preset.bands == [12, -12, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(EqualizerPreset(name: "Mine", values: preset.values) == preset)
    }

    @Test func replayGainUsesFallbackAndLimitsPeaks() {
        var track = Track(path: "/a.flac", title: "A")
        #expect(ReplayGain.gain(for: track, mode: .track, preamp: 3, fallback: -4) == -4)
        #expect(ReplayGain.gain(for: track, mode: .off, fallback: -4) == 0)
        track.rgTrackGain = 6
        track.rgTrackPeak = 0.8
        // +6 dB would clip a 0.8 peak; the gain stops at -20·log10(0.8) ≈ 1.94 dB.
        #expect(abs(ReplayGain.gain(for: track, mode: .track) - 1.938) < 0.01)
        track.rgAlbumGain = -3
        #expect(ReplayGain.gain(for: track, mode: .album, preamp: 1) == -2)
    }
}
