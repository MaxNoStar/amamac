import AppKit
import SwiftUI

/// Colour schemes for the analyzer, running from the quietest level (0) to the loudest (1). Raw
/// values are stored in settings.
enum AnalyzerPalette: String, CaseIterable, Identifiable {
    case neon, accent, ice, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neon: "Neon"
        case .accent: "Accent"
        case .ice: "Ice"
        case .mono: "Mono"
        }
    }

    /// An sRGB colour that can be mixed and turned into pixels.
    struct RGB: Equatable {
        var r, g, b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

        func mixed(with other: RGB, _ t: Double) -> RGB {
            RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }

        func scaled(_ factor: Double) -> RGB { RGB(r * factor, g * factor, b * factor) }
    }

    private static let accentRGB: RGB = {
        let color = NSColor.amamacAccent.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.416, blue: 0.051, alpha: 1)
        return RGB(color.redComponent, color.greenComponent, color.blueComponent)
    }()

    /// Evenly spaced stops from quiet to loud. Every style but Block draws on a dark panel;
    /// `onDark` is false only for Block in the light appearance.
    func stops(onDark: Bool = true) -> [RGB] {
        switch self {
        case .neon: [RGB(1, 0.239, 0.498), RGB(1, 0.416, 0.051), RGB(1, 0.824, 0.247)]
        case .accent: [Self.accentRGB.scaled(0.6), Self.accentRGB, RGB(1, 0.86, 0.45)]
        case .ice: [RGB(0.16, 0.85, 0.78), RGB(0.30, 0.62, 1), RGB(0.70, 0.46, 1)]
        case .mono: onDark ? [RGB(0.42, 0.44, 0.50), RGB(0.96, 0.97, 1)] : [RGB(0.62, 0.62, 0.65), RGB(0.12, 0.12, 0.14)]
        }
    }

    /// The colour at level `t` (0...1).
    func rgb(at t: Double, onDark: Bool = true) -> RGB {
        let stops = stops(onDark: onDark)
        let position = max(0, min(1, t)) * Double(stops.count - 1)
        let index = min(stops.count - 2, Int(position))
        return stops[index].mixed(with: stops[index + 1], position - Double(index))
    }

    func color(at t: Double, onDark: Bool = true) -> Color { rgb(at: t, onDark: onDark).color }

    func gradient(onDark: Bool = true) -> Gradient { Gradient(colors: stops(onDark: onDark).map(\.color)) }

    /// The colour glows are tinted with.
    var glow: Color { color(at: 0.5) }
}
