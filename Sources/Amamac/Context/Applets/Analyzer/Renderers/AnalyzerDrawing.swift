import SwiftUI

/// Drawing shared by the analyzer styles.
enum AnalyzerDrawing {
    /// The dark rounded panel every style but Block draws on, in both appearances.
    static func panelRect(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
    }

    /// Fills the panel and returns its shape, for clipping.
    @discardableResult
    static func drawPanel(in context: inout GraphicsContext, size: CGSize) -> Path {
        let rect = panelRect(size)
        let shape = Path(roundedRect: rect, cornerRadius: 10)
        context.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(.sRGB, red: 0.075, green: 0.07, blue: 0.11), Color(.sRGB, red: 0.02, green: 0.02, blue: 0.035)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        context.stroke(shape, with: .color(.white.opacity(0.07)), lineWidth: 1)
        return shape
    }

    /// A vertical gradient running from `palette`'s quiet colour at `from` to its loud colour at `to`.
    static func levelShading(_ palette: AnalyzerPalette, from: CGFloat, to: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(palette.gradient(), startPoint: CGPoint(x: 0, y: from), endPoint: CGPoint(x: 0, y: to))
    }

    /// Equal columns centred in a rectangle: as many as fit, but at least `minimum`.
    struct Columns {
        let count: Int
        let width: CGFloat
        let step: CGFloat
        let x0: CGFloat

        init(in rect: CGRect, width: CGFloat, gap: CGFloat, minimum: Int = 4) {
            count = max(minimum, Int((rect.width + gap) / (width + gap)))
            self.width = width
            step = width + gap
            x0 = rect.midX - (CGFloat(count) * step - gap) / 2
        }

        func x(_ column: Int) -> CGFloat { x0 + CGFloat(column) * step }
    }
}
