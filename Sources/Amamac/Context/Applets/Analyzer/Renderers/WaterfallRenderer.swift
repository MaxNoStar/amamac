import CoreGraphics
import SwiftUI

/// A spectrogram that scrolls to the left: time runs across, frequency up, loudness in colour. It
/// draws into a small bitmap, one column per tick, and scales that up, which stays cheap at 30 fps.
final class WaterfallRenderer: AnalyzerRenderer {
    private let columnsPerSecond = 30.0
    private let columnWidth: CGFloat = 3
    private let rowHeight: CGFloat = 3
    /// RGBA pixels, top row first.
    private var pixels: [UInt8] = []
    private var width = 0
    private var height = 0
    /// Premultiplied RGBA for each of 256 levels.
    private var colors: [UInt8] = []
    private var colorsPalette: AnalyzerPalette?
    private var lastDate: Date?
    private var pendingColumns = 0.0

    private func area(_ size: CGSize) -> CGRect { AnalyzerDrawing.panelRect(size) }

    func bands(for size: CGSize, barWidth: CGFloat) -> Int {
        max(16, min(128, Int(area(size).height / rowHeight)))
    }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        let shape = AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = area(size)
        let columns = max(8, Int(area.width / columnWidth)), rows = frame.levels.count
        guard rows > 0 else { return }
        if columns != width || rows != height {
            width = columns
            height = rows
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            pendingColumns = 0
        }
        if colorsPalette != frame.palette { makeColors(frame.palette) }
        // Scroll by elapsed time, so the speed doesn't depend on the frame rate.
        let elapsed = lastDate.map { min(0.25, max(0, frame.date.timeIntervalSince($0))) } ?? 1 / columnsPerSecond
        lastDate = frame.date
        pendingColumns += elapsed * columnsPerSecond
        let steps = min(width, Int(pendingColumns))
        pendingColumns -= Double(steps)
        if steps > 0 { scroll(by: steps, adding: frame.levels) }
        guard let image = makeImage() else { return }
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.draw(Image(decorative: image, scale: 1).interpolation(.medium), in: area)
        }
    }

    /// Moves every row `steps` columns to the left and fills the freed columns with `levels`.
    private func scroll(by steps: Int, adding levels: [Float]) {
        let rowBytes = width * 4, shift = steps * 4
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<height {
                let start = base + row * rowBytes
                if shift < rowBytes { memmove(start, start + shift, rowBytes - shift) }
                // Bass at the bottom.
                let level = levels[height - 1 - row]
                let index = Int(max(0, min(1, level)) * 255) * 4
                for column in (width - steps)..<width {
                    for channel in 0..<4 { buffer[row * rowBytes + column * 4 + channel] = colors[index + channel] }
                }
            }
        }
    }

    private func makeColors(_ palette: AnalyzerPalette) {
        colors = []
        colors.reserveCapacity(256 * 4)
        for value in 0..<256 {
            let t = Double(value) / 255
            let rgb = palette.rgb(at: t)
            // Quiet parts stay see-through, so the panel shows behind them.
            let alpha = min(1, pow(t, 0.8) * 1.3)
            for channel in [rgb.r, rgb.g, rgb.b] { colors.append(UInt8(max(0, min(255, channel * alpha * 255)))) }
            colors.append(UInt8(alpha * 255))
        }
        colorsPalette = palette
    }

    private func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
