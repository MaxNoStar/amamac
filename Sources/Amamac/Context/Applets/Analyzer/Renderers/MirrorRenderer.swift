import SwiftUI

/// Rounded bars that grow up and down from a centre line, quiet colours in the middle and loud
/// ones at the tips.
final class MirrorRenderer: AnalyzerRenderer {
    private func area(_ size: CGSize) -> CGRect { AnalyzerDrawing.panelRect(size).insetBy(dx: 10, dy: 8) }
    private func gap(_ barWidth: CGFloat) -> CGFloat { max(2, (barWidth * 0.35).rounded()) }

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        AnalyzerDrawing.Columns(in: area(size), width: barWidth, gap: gap(barWidth)).count
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = area(size)
        let columns = AnalyzerDrawing.Columns(in: area, width: frame.barWidth, gap: gap(frame.barWidth))
        let middle = area.midY
        let half = area.height / 2 - 1
        var bars = Path()
        for i in 0..<min(columns.count, frame.levels.count) {
            let height = max(1, CGFloat(frame.levels[i]) * half)
            let radius = min(columns.width / 2, height)
            bars.addRoundedRect(in: CGRect(x: columns.x(i), y: middle - height, width: columns.width, height: height * 2),
                                cornerSize: CGSize(width: radius, height: radius))
        }
        // Loud at both ends, quiet in the middle.
        let colors = frame.palette.stops().map(\.color)
        var stops: [Gradient.Stop] = []
        for (index, color) in colors.reversed().enumerated() {
            stops.append(.init(color: color, location: 0.5 * Double(index) / Double(colors.count - 1)))
        }
        for (index, color) in colors.enumerated() {
            stops.append(.init(color: color, location: 0.5 + 0.5 * Double(index) / Double(colors.count - 1)))
        }
        context.fill(Path(CGRect(x: area.minX, y: middle - 0.5, width: area.width, height: 1)),
                     with: .color(frame.palette.color(at: 0).opacity(0.35)))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: frame.palette.glow.opacity(0.7), radius: 6))
            layer.fill(bars, with: .linearGradient(Gradient(stops: stops),
                                                   startPoint: CGPoint(x: 0, y: area.minY), endPoint: CGPoint(x: 0, y: area.maxY)))
        }
    }
}
