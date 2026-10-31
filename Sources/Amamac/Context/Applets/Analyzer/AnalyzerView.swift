import SwiftUI

/// Draws the analyzer in the chosen style, about 30 times a second. Right-clicking it picks the
/// style and colours, as in Amarok.
struct AnalyzerView: View {
    let state: AnalyzerState
    @AppStorage private var style: String
    @AppStorage private var palette: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(state: AnalyzerState) {
        self.state = state
        _style = AppStorage(wrappedValue: AnalyzerStyle.neonBars.rawValue, AppSettings.Key.analyzerStyle, store: state.defaults)
        _palette = AppStorage(wrappedValue: AnalyzerPalette.neon.rawValue, AppSettings.Key.analyzerPalette, store: state.defaults)
    }

    private var currentStyle: AnalyzerStyle { AnalyzerStyle(rawValue: style) ?? .neonBars }
    private var currentPalette: AnalyzerPalette { AnalyzerPalette(rawValue: palette) ?? .neon }

    var body: some View {
        let style = currentStyle, palette = currentPalette
        let reduceMotion = reduceMotion, dark = colorScheme == .dark
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            // The canvas must read the timeline's date: a renderer that doesn't is never redrawn,
            // which left the bars frozen at their first (empty) frame.
            Canvas { context, size in
                let renderer = state.renderer(for: style)
                state.update(bands: renderer.bands(for: size, barWidth: state.barWidth), at: timeline.date)
                let frame = state.frame(style: style, palette: palette, date: timeline.date,
                                        reduceMotion: reduceMotion, darkAppearance: dark)
                renderer.draw(frame, in: &context, size: size)
            }
        }
        .contextMenu {
            Picker("Style", selection: $style) {
                ForEach(AnalyzerStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Colours", selection: $palette) {
                ForEach(AnalyzerPalette.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
        .accessibilityLabel("Spectrum analyzer")
        .accessibilityValue(style.title)
    }
}
