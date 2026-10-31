import AppKit
import SwiftUI

/// The album cover in a circle, ringed by rays that follow the spectrum and slowly turn, with
/// mirrored bars spreading out either side. Bass sits at the top of the ring and next to it in the
/// wings. Reduce Motion stops the turning and the pulse; without a cover a glowing disc stands in.
final class HaloRenderer: AnalyzerRenderer {
    private let bandCount = 36
    /// Rays are grouped into this many colours, so they are stroked in a few passes.
    private let colorSteps = 8

    func bands(for size: CGSize, barWidth: CGFloat) -> Int { bandCount }

    func draw(_ frame: AnalyzerFrame, in context: inout GraphicsContext, size: CGSize) {
        AnalyzerDrawing.drawPanel(in: &context, size: size)
        let area = AnalyzerDrawing.panelRect(size).insetBy(dx: 6, dy: 6)
        let centre = CGPoint(x: area.midX, y: area.midY)
        let outer = min(area.width, area.height) / 2
        let bands = min(bandCount, frame.levels.count)
        guard bands > 0, outer > 10 else { return }
        let bass = frame.levels.prefix(4).reduce(0, +) / Float(min(4, bands))
        let radius = outer * 0.5 * (frame.reduceMotion ? 1 : 1 + 0.05 * CGFloat(bass))
        let rayStart = radius + 4
        let rayLength = outer - rayStart
        let rays = bands * 2
        let rayWidth = max(1.5, min(4, 2 * .pi * rayStart / CGFloat(rays) * 0.55))
        // One turn a minute.
        let turn = frame.reduceMotion ? 0 : frame.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) / 60 * 2 * .pi

        var paths = [Path](repeating: Path(), count: colorSteps)
        for ray in 0..<rays {
            let band = ray < bands ? ray : rays - 1 - ray
            let level = CGFloat(frame.levels[band])
            let angle = turn - .pi / 2 + Double(ray) / Double(rays) * 2 * .pi
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let length = max(1.5, level * rayLength)
            let step = min(colorSteps - 1, Int(level * CGFloat(colorSteps)))
            paths[step].move(to: CGPoint(x: centre.x + direction.x * rayStart, y: centre.y + direction.y * rayStart))
            paths[step].addLine(to: CGPoint(x: centre.x + direction.x * (rayStart + length), y: centre.y + direction.y * (rayStart + length)))
        }

        // Wings: the same bands as thin mirrored bars either side, bass nearest the disc, fading out
        // towards the panel's edges. Left out when the panel is too narrow for them.
        let wingStart = outer + 10
        let wingLength = area.width / 2 - wingStart
        if wingLength > 40 {
            let step = wingLength / CGFloat(bands)
            var wings = [Path](repeating: Path(), count: colorSteps)
            for band in 0..<bands {
                let level = CGFloat(frame.levels[band])
                let half = max(1, level * outer * 0.85)
                let color = min(colorSteps - 1, Int(level * CGFloat(colorSteps)))
                let offset = wingStart + (CGFloat(band) + 0.5) * step
                for x in [centre.x - offset, centre.x + offset] {
                    wings[color].move(to: CGPoint(x: x, y: centre.y - half))
                    wings[color].addLine(to: CGPoint(x: x, y: centre.y + half))
                }
            }
            let inner = Double(wingStart / area.width)
            context.drawLayer { layer in
                layer.clipToLayer { mask in
                    mask.fill(Path(area), with: .linearGradient(
                        Gradient(stops: [.init(color: .white.opacity(0.1), location: 0), .init(color: .white, location: 0.5 - inner),
                                         .init(color: .white, location: 0.5 + inner), .init(color: .white.opacity(0.1), location: 1)]),
                        startPoint: CGPoint(x: area.minX, y: 0), endPoint: CGPoint(x: area.maxX, y: 0)))
                }
                layer.addFilter(.shadow(color: frame.palette.glow.opacity(0.6), radius: 4))
                for (color, path) in wings.enumerated() where !path.isEmpty {
                    layer.stroke(path, with: .color(frame.palette.color(at: (Double(color) + 0.5) / Double(colorSteps))),
                                 style: StrokeStyle(lineWidth: max(1.5, min(5, step * 0.5)), lineCap: .round))
                }
            }
        }

        let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let circle = Path(ellipseIn: disc)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: frame.palette.glow.opacity(0.8), radius: 5))
            for (step, path) in paths.enumerated() where !path.isEmpty {
                layer.stroke(path, with: .color(frame.palette.color(at: (Double(step) + 0.5) / Double(colorSteps))),
                             style: StrokeStyle(lineWidth: rayWidth, lineCap: .round))
            }
            layer.stroke(circle, with: .color(frame.palette.glow), lineWidth: 1.5)
        }
        if let cover = frame.cover, cover.size.width > 0, cover.size.height > 0 {
            // Fill the circle, cropping a cover that isn't square.
            let aspect = cover.size.width / cover.size.height
            let fill = aspect > 1 ? CGRect(x: disc.midX - disc.width * aspect / 2, y: disc.minY, width: disc.width * aspect, height: disc.height)
                : CGRect(x: disc.minX, y: disc.midY - disc.height / aspect / 2, width: disc.width, height: disc.height / aspect)
            context.drawLayer { layer in
                layer.clip(to: circle)
                layer.draw(Image(nsImage: cover), in: fill)
            }
        } else {
            context.fill(circle, with: .radialGradient(
                Gradient(colors: [frame.palette.color(at: 0.5).opacity(0.6), frame.palette.color(at: 0).opacity(0.12)]),
                center: centre, startRadius: 0, endRadius: radius))
            let hole = radius * 0.18
            context.fill(Path(ellipseIn: CGRect(x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2)),
                         with: .color(.black.opacity(0.55)))
        }
    }
}
