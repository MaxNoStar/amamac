// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacTestSupport
import AppKit
import SwiftUI

extension SnapshotRunner {
    /// Shows the Analyzer, as Configure Applets does, and checks in every style that its tap
    /// receives a playing tone, its bars rise while playing and fall back after Stop. Then draws
    /// each style from a made-up, music-like spectrum and captures it as
    /// `context-analyzer-<style>.png`.
    func checkAnalyzer() async {
        let player = env.player
        let context = window.context
        let kinds = context.enabledKinds
        let defaults = env.settings.defaults
        let savedStyle = defaults.string(forKey: AppSettings.Key.analyzerStyle)
        // Snapshot runs enable every applet; show the Analyzer alone so it is on screen.
        context.setEnabled([.analyzer])
        guard let analyzer = context.applet(.analyzer) as? AnalyzerAppletController,
              let id = env.playlist.activeID, let column = context.appletColumn else { fail("no analyzer applet or active track") }
        func barPeak() -> Float { analyzer.state.levels.max() ?? 0 }

        for style in AnalyzerStyle.allCases {
            defaults.set(style.rawValue, forKey: AppSettings.Key.analyzerStyle)
            player.play(id)
            await Snapshotter.waitUntil(timeout: 3) { player.currentTime > 0.5 }
            await Snapshotter.waitUntil(timeout: 2) { barPeak() > 0.2 }
            let tapPeak = analyzer.tap.spectrum(bands: 16).max() ?? 0
            print("snapshot: analyzer \(style.rawValue): time \(player.currentTime), tap peak \(tapPeak), bar peak \(barPeak())")
            guard tapPeak > 0.2, barPeak() > 0.2 else { fail("analyzer bars did not rise in \(style.rawValue)") }
            player.stop()
            await Snapshotter.waitUntil(timeout: 4) { barPeak() < 0.01 }
            guard barPeak() < 0.01 else { fail("analyzer bars did not fall after stop in \(style.rawValue) (peak \(barPeak()))") }
        }

        // Stopped, there is no album to show; Halo gets the fixture library's generated cover.
        let tone = analyzer.state.spectrum, cover = analyzer.state.cover
        let demoCover = NSImage(data: AudioFixtures.coverPNG(text: "SW", hue: 0.58, size: 256))
        let start = Date()
        analyzer.state.spectrum = { bands in Self.demoSpectrum(bands: bands, at: Date().timeIntervalSince(start)) }
        analyzer.state.cover = { demoCover }
        for style in AnalyzerStyle.allCases {
            defaults.set(style.rawValue, forKey: AppSettings.Key.analyzerStyle)
            // Let the bars settle; the waterfall needs a few seconds to fill its width.
            try? await Task.sleep(for: .seconds(style == .waterfall ? 9.5 : 1.2))
            guard barPeak() > 0.2 else { fail("analyzer \(style.rawValue) did not draw the demo spectrum") }
            await Snapshotter.capture(column, to: output.appendingPathComponent("context-analyzer-\(style.rawValue).png"), scale: 2)
        }
        analyzer.state.spectrum = tone
        analyzer.state.cover = cover
        defaults.set(savedStyle, forKey: AppSettings.Key.analyzerStyle)

        // The settings popover's content, with its style picker and colour swatches.
        let settings = NSWindow(contentViewController: NSHostingController(rootView: AnalyzerSettingsView(defaults: defaults).padding(12)))
        settings.isReleasedWhenClosed = false
        settings.title = "Analyzer Settings"
        settings.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        if let view = settings.contentView?.superview ?? settings.contentView {
            await Snapshotter.capture(view, to: output.appendingPathComponent("context-analyzer-settings.png"), scale: 2)
        }
        settings.close()
        context.setEnabled(kinds)
        print("snapshot: analyzer check passed")
    }

    /// A spectrum that looks like music: more bass than treble, a kick drum twice a second and
    /// bands that drift up and down.
    static func demoSpectrum(bands: Int, at time: Double) -> [Float] {
        (0..<bands).map { band in
            let x = Double(band) / Double(max(1, bands - 1))
            let kick = pow(max(0, sin(time * 2 * .pi * 2)), 8) * exp(-x * 6)
            let body = 0.52 - 0.34 * x
            let drift = 0.16 * sin(time * 3.1 + x * 9) + 0.12 * sin(time * 5.3 - x * 17)
            let grain = 0.1 * sin(Double(band) * 12.9898 + time * 7)
            return Float(min(1, max(0.02, body + drift + grain + 0.35 * kick)))
        }
    }
}
#endif
