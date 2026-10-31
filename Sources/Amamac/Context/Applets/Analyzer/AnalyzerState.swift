import AmamacPlayback
import AppKit

/// Per-frame bar levels, recent history and one renderer per style. Mutated from the drawing loop,
/// so it is a plain class rather than observable state.
@MainActor
final class AnalyzerState {
    let defaults: UserDefaults
    /// Target levels for a number of bands; nil while nothing plays, so the bars fall to zero.
    var spectrum: (Int) -> [Float]?
    /// The playing album's cover, asked for only by styles that show it.
    var cover: () -> NSImage? = { nil }
    private var dynamics = SpectrumDynamics()
    /// Recent bar levels, newest last; cleared when the number of bands changes.
    private(set) var history = SpectrumHistory(capacity: 16)
    private var lastUpdate: Date?
    private var renderers: [AnalyzerStyle: AnalyzerRenderer] = [:]

    init(defaults: UserDefaults, spectrum: @escaping (Int) -> [Float]?) {
        self.defaults = defaults
        self.spectrum = spectrum
    }

    var levels: [Float] { dynamics.levels }
    var peaks: [Float] { dynamics.peaks }
    var barWidth: CGFloat { CGFloat(max(3, defaults.double(forKey: AppSettings.Key.analyzerBarWidth))) }
    var showFadebars: Bool { defaults.bool(forKey: AppSettings.Key.analyzerShowFadebars) }

    /// The renderer for `style`, kept for the applet's lifetime so it can carry state between frames.
    func renderer(for style: AnalyzerStyle) -> AnalyzerRenderer {
        if let renderer = renderers[style] { return renderer }
        let renderer = style.makeRenderer()
        renderers[style] = renderer
        return renderer
    }

    /// Advances the bars to `date`. Falling is scaled by the time since the last frame, so the bars
    /// drop at the same speed whatever the frame rate.
    func update(bands: Int, at date: Date) {
        let elapsed = lastUpdate.map { min(0.25, max(0, date.timeIntervalSince($0))) } ?? 0
        lastUpdate = date
        var target = spectrum(bands) ?? []
        if target.count != bands { target = [Float](repeating: 0, count: bands) }
        if bands != dynamics.levels.count { history.removeAll() }
        dynamics.advance(to: target, elapsed: elapsed, fallSpeed: defaults.integer(forKey: AppSettings.Key.analyzerFallSpeed))
        history.append(dynamics.levels)
    }

    /// What the renderer for `style` draws at `date`.
    func frame(style: AnalyzerStyle, palette: AnalyzerPalette, date: Date, reduceMotion: Bool, darkAppearance: Bool) -> AnalyzerFrame {
        AnalyzerFrame(levels: dynamics.levels, peaks: dynamics.peaks, history: history, palette: palette,
                      barWidth: barWidth, showFadeBars: showFadebars, date: date,
                      cover: style.showsCover ? cover() : nil, reduceMotion: reduceMotion, darkAppearance: darkAppearance)
    }
}
