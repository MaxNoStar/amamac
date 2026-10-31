import SwiftUI

/// Amarok's block analyzer: stacks of small blocks with falling fade bars, drawn straight onto the
/// pane. Under the Accent palette it keeps its original colours.
final class BlockRenderer: AnalyzerRenderer {
    private let gap: CGFloat = 2
    private let blockHeight: CGFloat = 4
    private let blockGap: CGFloat = 1

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        max(4, Int((size.width - 16 + gap) / (barWidth + gap)))
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        let barWidth = frame.barWidth
        let bands = bands(for: size, barWidth: barWidth)
        let blocks = max(1, Int((size.height - 16) / (blockHeight + blockGap)))
        let x0 = (size.width - CGFloat(bands) * (barWidth + gap) + gap) / 2
        let classic = frame.palette == .accent
        for i in 0..<min(bands, frame.levels.count) {
            let x = x0 + CGFloat(i) * (barWidth + gap)
            let lit = Int((CGFloat(frame.levels[i]) * CGFloat(blocks)).rounded())
            for b in 0..<lit {
                let y = size.height - 8 - CGFloat(b + 1) * (blockHeight + blockGap)
                let t = Double(b) / Double(blocks)
                let color = classic ? (t > 0.8 ? .yellow : Color.amamacAccent.opacity(0.55 + 0.45 * t))
                    : frame.palette.color(at: t, onDark: frame.darkAppearance)
                context.fill(Path(CGRect(x: x, y: y, width: barWidth, height: blockHeight)), with: .color(color))
            }
            if frame.showFadeBars {
                let peakBlock = Int((CGFloat(frame.peaks[i]) * CGFloat(blocks)).rounded())
                if peakBlock > lit {
                    let y = size.height - 8 - CGFloat(peakBlock) * (blockHeight + blockGap)
                    context.fill(Path(CGRect(x: x, y: y, width: barWidth, height: blockHeight)),
                                 with: .color(.secondary.opacity(0.6)))
                }
            }
        }
    }
}
