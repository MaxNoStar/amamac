import SwiftUI

/// Rounded gradient bars that glow, over a soft reflection, with glowing caps for the fade bars.
final class NeonBarsRenderer: AnalyzerRenderer {
    private func area(_ size: CGSize) -> CGRect { AnalyzerDrawing.panelRect(size).insetBy(dx: 12, dy: 10) }
    private func gap(_ barWidth: CGFloat) -> CGFloat { max(2, (barWidth * 0.4).rounded()) }

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        AnalyzerDrawing.Columns(in: area(size), width: barWidth, gap: gap(barWidth)).count
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = area(size)
        let columns = AnalyzerDrawing.Columns(in: area, width: frame.barWidth, gap: gap(frame.barWidth))
        let baseline = area.minY + area.height * 0.8
        let full = baseline - area.minY
        let corner = CGSize(width: min(columns.width / 2, 3), height: min(columns.width / 2, 3))
        var bars = Path(), reflection = Path(), caps = Path()
        for i in 0..<min(columns.count, frame.levels.count) {
            let x = columns.x(i)
            let height = max(1.5, CGFloat(frame.levels[i]) * full)
            bars.addRoundedRect(in: CGRect(x: x, y: baseline - height, width: columns.width, height: height), cornerSize: corner)
            reflection.addRoundedRect(in: CGRect(x: x, y: baseline + 2, width: columns.width, height: height * 0.45), cornerSize: corner)
            if frame.showFadeBars, frame.peaks[i] > frame.levels[i] + 0.02 {
                let y = baseline - CGFloat(frame.peaks[i]) * full - 3
                caps.addRoundedRect(in: CGRect(x: x, y: y, width: columns.width, height: 2), cornerSize: CGSize(width: 1, height: 1))
            }
        }
        // The reflection fades out towards the bottom of the panel.
        context.drawLayer { layer in
            layer.opacity = 0.3
            layer.clipToLayer { mask in
                mask.fill(Path(CGRect(x: area.minX, y: baseline, width: area.width, height: area.maxY - baseline)),
                          with: .linearGradient(Gradient(colors: [.white, .clear]),
                                                startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: area.maxY)))
            }
            layer.fill(reflection, with: AnalyzerDrawing.levelShading(frame.palette, from: baseline, to: baseline + full * 0.45))
        }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: frame.palette.glow.opacity(0.85), radius: 7))
            layer.fill(bars, with: AnalyzerDrawing.levelShading(frame.palette, from: baseline, to: area.minY))
            layer.fill(caps, with: .color(.white.opacity(0.92)))
        }
    }
}
