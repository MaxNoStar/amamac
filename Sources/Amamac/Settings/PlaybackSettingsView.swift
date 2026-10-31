import AmamacPlayback
import SwiftUI

/// Settings › Playback: output, fading and crossfades, Replay Gain and seeking.
struct PlaybackSettingsView: View {
    let env: AppEnvironment
    @AppStorage private var fadeOnStop: Bool
    @AppStorage private var fadeOnPause: Bool
    @AppStorage private var fadeDuration: Int
    @AppStorage private var crossfade: Bool
    @AppStorage private var crossfadeDuration: Int
    @AppStorage private var crossfadeKeepsAlbumsGapless: Bool
    @AppStorage private var replayGainMode: ReplayGainMode
    @AppStorage private var replayGainPreamp: Double
    @AppStorage private var replayGainFallback: Double
    @AppStorage private var seekShort: Int
    @AppStorage private var seekMedium: Int
    @AppStorage private var seekLong: Int
    @AppStorage private var outputDevice: String
    @AppStorage private var resumePlayback: Bool
    @State private var devices = OutputDeviceList()

    init(env: AppEnvironment) {
        self.env = env
        let d = env.settings.defaults
        typealias K = AppSettings.Key
        _fadeOnStop = AppStorage(wrappedValue: false, K.fadeOutOnStop, store: d)
        _fadeOnPause = AppStorage(wrappedValue: false, K.fadeOutOnPause, store: d)
        _fadeDuration = AppStorage(wrappedValue: 2000, K.fadeOutDuration, store: d)
        _crossfade = AppStorage(wrappedValue: false, K.crossfade, store: d)
        _crossfadeDuration = AppStorage(wrappedValue: 5000, K.crossfadeDuration, store: d)
        _crossfadeKeepsAlbumsGapless = AppStorage(wrappedValue: true, K.crossfadeKeepsAlbumsGapless, store: d)
        _replayGainMode = AppStorage(wrappedValue: .track, K.replayGainMode, store: d)
        _replayGainPreamp = AppStorage(wrappedValue: 0, K.replayGainPreamp, store: d)
        _replayGainFallback = AppStorage(wrappedValue: 0, K.replayGainFallback, store: d)
        _seekShort = AppStorage(wrappedValue: 2, K.seekShort, store: d)
        _seekMedium = AppStorage(wrappedValue: 10, K.seekMedium, store: d)
        _seekLong = AppStorage(wrappedValue: 60, K.seekLong, store: d)
        _outputDevice = AppStorage(wrappedValue: "", K.outputDevice, store: d)
        _resumePlayback = AppStorage(wrappedValue: true, K.resumePlayback, store: d)
    }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Output device", selection: $outputDevice) {
                    Text("System Default").tag("")
                    if !outputDevice.isEmpty && !devices.devices.contains(where: { $0.uid == outputDevice }) {
                        Text("Unavailable Device").tag(outputDevice)
                    }
                    Divider()
                    ForEach(devices.devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("Resume playback when Amamac starts", isOn: $resumePlayback)
                LabeledContent("Equalizer") {
                    Button("Open Equalizer…") { EqualizerWindow.show(env: env) }
                }
            }
            Section {
                Toggle("Fade out when stopping", isOn: $fadeOnStop)
                Toggle("Fade out when pausing", isOn: $fadeOnPause)
                LabeledContent("Fade-out duration") { durationSlider($fadeDuration, in: 200...8000, step: 100) }
                    .disabled(!fadeOnStop && !fadeOnPause)
                Toggle("Crossfade between tracks", isOn: $crossfade)
                LabeledContent("Crossfade duration") {
                    durationSlider($crossfadeDuration, in: CrossfadePolicy.shortestFade * 1000...CrossfadePolicy.longestFade * 1000, step: 500)
                }
                .disabled(!crossfade)
                Toggle("Don't crossfade within an album", isOn: $crossfadeKeepsAlbumsGapless)
                    .disabled(!crossfade)
            } header: {
                Text("Fading")
            } footer: {
                Text("A track that plays to its end blends into the next one; skipping still switches at once. Radio and podcast streams don't crossfade.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Mode", selection: $replayGainMode) {
                    ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                gainSlider("Pre-amp", $replayGainPreamp, range: -12...12)
                gainSlider("Tracks without Replay Gain", $replayGainFallback, range: -12...6)
            } header: {
                Text("Replay Gain")
            } footer: {
                Text("Track mode evens out loudness between songs; Album mode keeps each album's own dynamics. Peaks are never pushed past full scale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Seeking") {
                seekStepper("Arrow keys", $seekMedium)
                seekStepper("With ⌘ (short)", $seekShort)
                seekStepper("With ⇧ (long)", $seekLong)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A slider over a duration stored in milliseconds, snapping to `step`, with its value in seconds.
    private func durationSlider(_ milliseconds: Binding<Int>, in range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Slider(value: Binding(get: { Double(milliseconds.wrappedValue) },
                                  set: { milliseconds.wrappedValue = Int(($0 / step).rounded() * step) }), in: range)
                .frame(width: 180)
            Text(String(format: "%.1f s", Double(milliseconds.wrappedValue) / 1000)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func gainSlider(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 2).rounded() / 2 }), in: range)
                    .frame(width: 180)
                Text(String(format: "%+.1f dB", value.wrappedValue)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
        .disabled(replayGainMode == .off)
    }

    private func seekStepper(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...600) {
            LabeledContent(title) { Text("\(value.wrappedValue) s").monospacedDigit() }
        }
    }
}
