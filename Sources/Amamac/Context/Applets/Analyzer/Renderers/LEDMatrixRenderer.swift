import SwiftUI

/// A grid of round lamps, lit from the bottom and coloured by height; the fade bar is a white lamp.
final class LEDMatrixRenderer: AnalyzerRenderer {
    private func area(_ size: CGSize) -> CGRect { AnalyzerDrawing.panelRect(size).insetBy(dx: 10, dy: 8) }
    private func lamp(_ barWidth: CGFloat) -> CGFloat { min(12, max(4, barWidth)) }
    private func gap(_ lamp: CGFloat) -> CGFloat { max(2, (lamp * 0.35).rounded()) }

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        let lamp = lamp(barWidth)
        return AnalyzerDrawing.Columns(in: area(size), width: lamp, gap: gap(lamp)).count
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = area(size)
        let lamp = lamp(frame.barWidth), gap = gap(lamp)
        let columns = AnalyzerDrawing.Columns(in: area, width: lamp, gap: gap)
        let rows = max(4, Int((area.height + gap) / (lamp + gap)))
        let bottom = area.maxY - (area.height - (CGFloat(rows) * (lamp + gap) - gap)) / 2
        var unlit = Path(), peaks = Path()
        var lit = [Path](repeating: Path(), count: rows)
        for i in 0..<min(columns.count, frame.levels.count) {
            let x = columns.x(i)
            let litRows = Int((CGFloat(frame.levels[i]) * CGFloat(rows)).rounded())
            let peakRow = frame.showFadeBars ? Int((CGFloat(frame.peaks[i]) * CGFloat(rows)).rounded()) - 1 : -1
            for row in 0..<rows {
                let rect = CGRect(x: x, y: bottom - CGFloat(row + 1) * (lamp + gap) + gap, width: lamp, height: lamp)
                if row < litRows {
                    lit[row].addEllipse(in: rect)
                } else if row == peakRow {
                    peaks.addEllipse(in: rect)
                } else {
                    unlit.addEllipse(in: rect)
                }
            }
        }
        context.fill(unlit, with: .color(.white.opacity(0.055)))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: frame.palette.glow.opacity(0.75), radius: 4))
            for (row, path) in lit.enumerated() where !path.isEmpty {
                layer.fill(path, with: .color(frame.palette.color(at: Double(row) / Double(rows - 1))))
            }
            layer.fill(peaks, with: .color(.white))
        }
    }
}
