import AmamacPlayback
import AppKit
import SwiftUI

/// The analyzer's looks. Raw values are stored in settings.
enum AnalyzerStyle: String, CaseIterable, Identifiable {
    case block, neonBars, mirror, halo, aurora, ledMatrix, waterfall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: "Block"
        case .neonBars: "Neon bars"
        case .mirror: "Mirror"
        case .halo: "Halo"
        case .aurora: "Aurora"
        case .ledMatrix: "LED matrix"
        case .waterfall: "Waterfall"
        }
    }

    var symbol: String {
        switch self {
        case .block: "chart.bar.fill"
        case .neonBars: "sparkles"
        case .mirror: "waveform"
        case .halo: "sun.max"
        case .aurora: "water.waves"
        case .ledMatrix: "circle.grid.3x3.fill"
        case .waterfall: "square.grid.4x3.fill"
        }
    }

    /// Whether the bar width setting changes this style.
    var usesBarWidth: Bool {
        switch self {
        case .block, .neonBars, .mirror, .ledMatrix: true
        case .halo, .aurora, .waterfall: false
        }
    }

    /// Whether this style draws fade bars (peaks that hold, then fall).
    var usesFadeBars: Bool {
        switch self {
        case .block, .neonBars, .ledMatrix: true
        case .mirror, .halo, .aurora, .waterfall: false
        }
    }

    /// Whether this style shows the playing album's cover.
    var showsCover: Bool { self == .halo }

    func makeRenderer() -> AnalyzerRenderer {
        switch self {
        case .block: BlockRenderer()
        case .neonBars: NeonBarsRenderer()
        case .mirror: MirrorRenderer()
        case .halo: HaloRenderer()
        case .aurora: AuroraRenderer()
        case .ledMatrix: LEDMatrixRenderer()
        case .waterfall: WaterfallRenderer()
        }
    }
}

/// What a renderer draws from: the bars and their recent history, plus the settings and
/// environment that change the look.
struct AnalyzerFrame {
    var levels: [Float]
    var peaks: [Float]
    var history: SpectrumHistory
    var palette: AnalyzerPalette
    var barWidth: CGFloat
    var showFadeBars: Bool
    var date: Date
    var cover: NSImage?
    var reduceMotion: Bool
    var darkAppearance: Bool
}

/// Draws one analyzer style. A renderer lives as long as the applet and may keep state between
/// frames (the waterfall keeps its image).
@MainActor
protocol AnalyzerRenderer: AnyObject {
    /// How many bands this style draws at `size`.
    func bands(for size: CGSize, barWidth: CGFloat) -> Int
    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize)
}
