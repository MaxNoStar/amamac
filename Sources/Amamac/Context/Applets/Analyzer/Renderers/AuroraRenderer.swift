import SwiftUI

/// Three smooth, glowing curtains: the spectrum now and two fading echoes of it a moment ago,
/// blended additively.
final class AuroraRenderer: AnalyzerRenderer {
    /// How many frames back each echo is, oldest first, and how strongly it is drawn.
    private let echoes: [(age: Int, strength: Double)] = [(10, 0.25), (5, 0.45)]

    private func area(_ size: CGSize) -> CGRect { AnalyzerDrawing.panelRect(size).insetBy(dx: 8, dy: 10) }

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        max(16, min(64, Int(area(size).width / 9)))
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = area(size)
        guard frame.levels.count > 1 else { return }
        let palette = frame.palette
        let curtain = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [palette.color(at: 1).opacity(0.8), palette.color(at: 0.5).opacity(0.45), palette.color(at: 0).opacity(0.04)]),
            startPoint: CGPoint(x: 0, y: area.minY), endPoint: CGPoint(x: 0, y: area.maxY))
        var layers: [([Float], Double)] = []
        for echo in echoes {
            if let values = frame.history.frame(age: echo.age), values.count == frame.levels.count { layers.append((values, echo.strength)) }
        }
        layers.append((frame.levels, 1))

        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for (values, strength) in layers {
                let edge = curve(through: smoothed(values), in: area)
                var fill = edge
                fill.addLine(to: CGPoint(x: area.maxX, y: area.maxY))
                fill.addLine(to: CGPoint(x: area.minX, y: area.maxY))
                fill.closeSubpath()
                layer.opacity = strength
                layer.fill(fill, with: curtain)
                if strength < 1 { layer.stroke(edge, with: .color(palette.color(at: 0.8)), lineWidth: 1) }
            }
        }
        // The current edge glows.
        let edge = curve(through: smoothed(frame.levels), in: area)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: palette.glow, radius: 6))
            layer.stroke(edge, with: .color(palette.color(at: 0.9)), lineWidth: 2)
        }
    }

    /// Softens neighbouring bands into each other, for rounder curves.
    private func smoothed(_ values: [Float]) -> [Float] {
        values.indices.map { i in
            let left = values[max(0, i - 1)], right = values[min(values.count - 1, i + 1)]
            return 0.25 * left + 0.5 * values[i] + 0.25 * right
        }
    }

    /// A Catmull-Rom curve through the levels, spread across `rect`.
    private func curve(through values: [Float], in rect: CGRect) -> Path {
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: rect.maxY - 1 - CGFloat(value) * rect.height * 0.92)
        }
        var path = Path()
        path.move(to: points[0])
        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}
