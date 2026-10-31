// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import CoreGraphics
import Foundation
import ImageIO

/// Album covers for `ShowcaseLibrary`, drawn from simple shapes so the screenshots look like a
/// real collection without using anyone's artwork.
public enum ShowcaseCovers {
    public enum Style: Sendable {
        case sunburst, rings, synthSun, bokeh, stripes, smoke
    }

    public static func png(_ style: Style, size: Int) -> Data {
        let s = CGFloat(size)
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        func gradient(_ colors: [UInt32], from: CGPoint, to: CGPoint) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { color($0) } as CFArray, locations: nil)!
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let center = CGPoint(x: s / 2, y: s / 2)

        switch style {
        case .sunburst:
            // Orange rays around a dark handlebar mustache: MC Chops's own album.
            gradient([0xFFB04F, 0xE5462F], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            ctx.setFillColor(color(0xFFFFFF, 0.14))
            for i in 0..<16 where i % 2 == 0 {
                let a0 = CGFloat(i) * .pi / 8, a1 = a0 + .pi / 8
                ctx.move(to: center)
                ctx.addLine(to: CGPoint(x: center.x + cos(a0) * s, y: center.y + sin(a0) * s))
                ctx.addLine(to: CGPoint(x: center.x + cos(a1) * s, y: center.y + sin(a1) * s))
                ctx.closePath()
            }
            ctx.fillPath()
            ctx.setFillColor(color(0x2B1D22))
            for mirror in [CGFloat(1), -1] {
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.scaleBy(x: mirror * s / 512, y: s / 512)
                ctx.move(to: CGPoint(x: 0, y: 18))
                ctx.addCurve(to: CGPoint(x: -150, y: 8), control1: CGPoint(x: -40, y: 50), control2: CGPoint(x: -110, y: 50))
                ctx.addCurve(to: CGPoint(x: -168, y: 70), control1: CGPoint(x: -200, y: -10), control2: CGPoint(x: -210, y: 60))
                ctx.addCurve(to: CGPoint(x: -150, y: 40), control1: CGPoint(x: -150, y: 78), control2: CGPoint(x: -140, y: 52))
                ctx.addCurve(to: CGPoint(x: 0, y: -26), control1: CGPoint(x: -110, y: -30), control2: CGPoint(x: -40, y: -36))
                ctx.closePath()
                ctx.fillPath()
                ctx.restoreGState()
            }
        case .rings:
            // A deep-blue record with velvet grooves.
            gradient([0x22346F, 0x5A2A6E], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s, y: s))
            ctx.setLineWidth(s / 64)
            for i in 1...9 {
                ctx.setStrokeColor(color(0xFFFFFF, i % 3 == 0 ? 0.35 : 0.12))
                let r = s * 0.045 * CGFloat(i)
                ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
            ctx.setFillColor(color(0xF29BB2))
            ctx.fillEllipse(in: CGRect(x: center.x - s * 0.06, y: center.y - s * 0.06, width: s * 0.12, height: s * 0.12))
        case .synthSun:
            // Synthwave: a striped sunset sun over a cyan grid.
            gradient([0x1B0B33, 0x4A1757], from: CGPoint(x: 0, y: s), to: CGPoint(x: 0, y: s * 0.4))
            let sun = CGRect(x: s * 0.22, y: s * 0.36, width: s * 0.56, height: s * 0.56)
            ctx.saveGState()
            ctx.addEllipse(in: sun)
            ctx.clip()
            gradient([0xFFD25C, 0xFF4F8B], from: CGPoint(x: 0, y: sun.maxY), to: CGPoint(x: 0, y: sun.minY))
            ctx.setFillColor(color(0x2A0F3D))
            for i in 0..<5 {
                ctx.fill(CGRect(x: sun.minX, y: sun.minY + s * (0.03 + 0.05 * CGFloat(i)), width: sun.width, height: s * 0.012 * CGFloat(i + 1)))
            }
            ctx.restoreGState()
            ctx.setFillColor(color(0x12062A))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.38))
            ctx.setStrokeColor(color(0x37E3FF, 0.85))
            ctx.setLineWidth(s / 200)
            for i in 0...6 {
                let y = s * 0.38 * pow(CGFloat(i) / 6, 1.8)
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s, y: y))
            }
            for i in -6...6 {
                ctx.move(to: CGPoint(x: center.x + CGFloat(i) * s * 0.03, y: s * 0.38))
                ctx.addLine(to: CGPoint(x: center.x + CGFloat(i) * s * 0.2, y: 0))
            }
            ctx.strokePath()
        case .bokeh:
            // Warm morning light.
            gradient([0xFFE3C2, 0xF6A57E], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            let spots: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
                (0.25, 0.7, 0.22, 0xFFFFFF), (0.7, 0.75, 0.15, 0xFFF4D6), (0.6, 0.35, 0.28, 0xFF8FA8),
                (0.2, 0.25, 0.12, 0xFFFFFF), (0.85, 0.2, 0.1, 0xFFD27F),
            ]
            for (x, y, r, hex) in spots {
                ctx.setFillColor(color(hex, 0.38))
                ctx.fillEllipse(in: CGRect(x: s * (x - r), y: s * (y - r), width: s * 2 * r, height: s * 2 * r))
            }
        case .stripes:
            // Punk: hazard yellow, black stripes and one hot-pink slash.
            ctx.setFillColor(color(0xFFD400))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            ctx.setFillColor(color(0x151515))
            for i in stride(from: -8, through: 8, by: 2) {
                let x = CGFloat(i) * s * 0.09
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x + s * 0.09, y: 0))
                ctx.addLine(to: CGPoint(x: x + s * 1.09, y: s)); ctx.addLine(to: CGPoint(x: x + s, y: s))
                ctx.closePath()
            }
            ctx.fillPath()
            ctx.setFillColor(color(0xFF3D7F))
            ctx.move(to: CGPoint(x: 0, y: s * 0.62)); ctx.addLine(to: CGPoint(x: s, y: s * 0.3))
            ctx.addLine(to: CGPoint(x: s, y: s * 0.44)); ctx.addLine(to: CGPoint(x: 0, y: s * 0.76))
            ctx.closePath()
            ctx.fillPath()
        case .smoke:
            // Late-night jazz: dark teal, gold lines and a drift of smoke.
            gradient([0x0F3B3F, 0x08181C], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            ctx.setStrokeColor(color(0xE7B75F))
            ctx.setLineWidth(s / 90)
            for i in 0..<4 {
                let y = s * (0.18 + 0.06 * CGFloat(i))
                ctx.move(to: CGPoint(x: s * 0.12, y: y)); ctx.addLine(to: CGPoint(x: s * 0.88, y: y + s * 0.02))
            }
            ctx.strokePath()
            ctx.setStrokeColor(color(0xFFFFFF, 0.22))
            ctx.setLineWidth(s / 40)
            ctx.move(to: CGPoint(x: s * 0.5, y: s * 0.4))
            ctx.addCurve(to: CGPoint(x: s * 0.42, y: s * 0.85), control1: CGPoint(x: s * 0.7, y: s * 0.55), control2: CGPoint(x: s * 0.2, y: s * 0.7))
            ctx.strokePath()
        }

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
#endif
