import AppKit
import SwiftUI
import AmamacCore

/// Block spectrum analyzer with falling peak ("fade") bars. The output tap is installed only
/// while the applet is shown.
final class AnalyzerAppletController: Applet {
    let kind = AppletKind.analyzer
    let contentView: NSView
    private let env: AppEnvironment
    private let tap = SpectrumTap()
    private let state: AnalyzerState

    init(env: AppEnvironment) {
        self.env = env
        state = AnalyzerState(tap: tap, defaults: env.settings.defaults, player: env.player)
        contentView = HostedAppletView(rootView: AnalyzerApplet(state: state))
    }

    func setActive(_ active: Bool) {
        tap.reset()
        env.player.local.setSpectrumTap(active ? tap : nil)
    }

    func makeConfigurationView() -> AnyView? {
        AnyView(AnalyzerSettingsView(defaults: env.settings.defaults))
    }
}

/// Per-frame bar levels with gravity and peak hold. Mutated from the drawing loop, so it is a
/// plain class rather than observable state.
@MainActor
final class AnalyzerState {
    let tap: SpectrumTap
    let defaults: UserDefaults
    let player: PlayerController
    private(set) var levels: [Float] = []
    private(set) var peaks: [Float] = []
    private var peakAge: [Int] = []

    init(tap: SpectrumTap, defaults: UserDefaults, player: PlayerController) {
        self.tap = tap
        self.defaults = defaults
        self.player = player
    }

    var barWidth: CGFloat { CGFloat(max(3, defaults.double(forKey: AppSettings.Key.analyzerBarWidth))) }
    var showFadebars: Bool { defaults.bool(forKey: AppSettings.Key.analyzerShowFadebars) }

    func update(bands: Int) {
        let playing = player.state == .playing
        let fall = Float(max(1, min(5, defaults.integer(forKey: AppSettings.Key.analyzerFallSpeed)))) * 0.012
        var target = [Float](repeating: 0, count: bands)
        if playing {
            target = tap.spectrum(bands: bands, sampleSize: max(512, defaults.integer(forKey: AppSettings.Key.analyzerSampleSize)),
                                  minFrequency: Float(defaults.double(forKey: AppSettings.Key.analyzerMinFrequency)),
                                  maxFrequency: Float(defaults.double(forKey: AppSettings.Key.analyzerMaxFrequency)))
            if target.count != bands { target = [Float](repeating: 0, count: bands) }
        }
        if levels.count != bands {
            levels = target
            peaks = target
            peakAge = [Int](repeating: 0, count: bands)
            return
        }
        for i in 0..<bands {
            levels[i] = target[i] >= levels[i] ? target[i] : max(target[i], levels[i] - fall)
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                peakAge[i] = 0
            } else {
                peakAge[i] += 1
                // Hold briefly, then fall faster than the bars.
                if peakAge[i] > 12 { peaks[i] = max(levels[i], peaks[i] - fall * 0.6) }
            }
        }
    }
}

struct AnalyzerApplet: View {
    let state: AnalyzerState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            Canvas { context, size in
                let gap: CGFloat = 2
                let barWidth = state.barWidth
                let bands = max(4, Int((size.width - 16 + gap) / (barWidth + gap)))
                state.update(bands: bands)
                let blockHeight: CGFloat = 4
                let blockGap: CGFloat = 1
                let usable = size.height - 16
                let blocks = max(1, Int(usable / (blockHeight + blockGap)))
                let x0 = (size.width - CGFloat(bands) * (barWidth + gap) + gap) / 2
                let low = Color.amamacAccent
                for i in 0..<min(bands, state.levels.count) {
                    let x = x0 + CGFloat(i) * (barWidth + gap)
                    let lit = Int((CGFloat(state.levels[i]) * CGFloat(blocks)).rounded())
                    for b in 0..<lit {
                        let y = size.height - 8 - CGFloat(b + 1) * (blockHeight + blockGap)
                        let t = Double(b) / Double(blocks)
                        context.fill(Path(CGRect(x: x, y: y, width: barWidth, height: blockHeight)),
                                     with: .color(t > 0.8 ? .yellow : low.opacity(0.55 + 0.45 * t)))
                    }
                    if state.showFadebars {
                        let peakBlock = Int((CGFloat(state.peaks[i]) * CGFloat(blocks)).rounded())
                        if peakBlock > lit {
                            let y = size.height - 8 - CGFloat(peakBlock) * (blockHeight + blockGap)
                            context.fill(Path(CGRect(x: x, y: y, width: barWidth, height: blockHeight)),
                                         with: .color(.secondary.opacity(0.6)))
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Spectrum analyzer")
    }
}

struct AnalyzerSettingsView: View {
    @AppStorage private var barWidth: Double
    @AppStorage private var fallSpeed: Int
    @AppStorage private var fadebars: Bool
    @AppStorage private var sampleSize: Int
    @AppStorage private var minFrequency: Double
    @AppStorage private var maxFrequency: Double

    init(defaults: UserDefaults) {
        _barWidth = AppStorage(wrappedValue: 8, AppSettings.Key.analyzerBarWidth, store: defaults)
        _fallSpeed = AppStorage(wrappedValue: 3, AppSettings.Key.analyzerFallSpeed, store: defaults)
        _fadebars = AppStorage(wrappedValue: true, AppSettings.Key.analyzerShowFadebars, store: defaults)
        _sampleSize = AppStorage(wrappedValue: 4096, AppSettings.Key.analyzerSampleSize, store: defaults)
        _minFrequency = AppStorage(wrappedValue: 40, AppSettings.Key.analyzerMinFrequency, store: defaults)
        _maxFrequency = AppStorage(wrappedValue: 16_000, AppSettings.Key.analyzerMaxFrequency, store: defaults)
    }

    var body: some View {
        Form {
            Slider(value: $barWidth, in: 3...20, step: 1) { Text("Bar width") }
            Picker("Fall speed", selection: $fallSpeed) {
                Text("Very slow").tag(1); Text("Slow").tag(2); Text("Medium").tag(3); Text("Fast").tag(4); Text("Very fast").tag(5)
            }
            Toggle("Show fade bars", isOn: $fadebars)
            Picker("Lowest frequency", selection: $minFrequency) {
                ForEach([20.0, 40, 80, 160], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
            }
            Picker("Highest frequency", selection: $maxFrequency) {
                ForEach([5_000.0, 10_000, 16_000, 20_000], id: \.self) { Text("\(Int($0 / 1000)) kHz").tag($0) }
            }
            Picker("Sample size", selection: $sampleSize) {
                ForEach([1024, 2048, 4096, 8192], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .frame(width: 300)
    }
}
