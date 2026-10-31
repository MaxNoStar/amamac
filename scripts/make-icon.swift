#!/usr/bin/env swift
// Amamac's app icon designs, all original artwork drawn with Core Graphics.
//
//   swift scripts/make-icon.swift [--design NAME] [APPICONSET]   writes every size the asset catalog needs
//   swift scripts/make-icon.swift --preview DIR                   writes each design at 1024 px plus a comparison sheet
//
// Designs: speaker (the app icon), record, spectrum, panes, aurora, monogram.

import AppKit
import CoreGraphics

// MARK: - Helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func c(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xFF) / 255 }
    let t = min(1, max(0, t))
    return CGColor(srgbRed: c(a, 16) + (c(b, 16) - c(a, 16)) * t, green: c(a, 8) + (c(b, 8) - c(a, 8)) * t,
                   blue: c(a, 0) + (c(b, 0) - c(a, 0)) * t, alpha: 1)
}

/// The macOS icon grid's 824 pt body.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

/// Core Graphics measures shadow offset and blur in device pixels, so scale them with the drawing;
/// otherwise the 16 px icon gets the 1024 px shadow.
func setShadow(_ ctx: CGContext, offset: CGSize, blur: CGFloat, color shadowColor: CGColor) {
    let s = hypot(ctx.ctm.a, ctx.ctm.b)
    ctx.setShadow(offset: CGSize(width: offset.width * s, height: offset.height * s), blur: blur * s, color: shadowColor)
}

/// Draws the tile with its drop shadow and a gradient (top-left → bottom-right unless given),
/// runs `content` clipped to the tile, then adds a thin rim.
func tile(_ ctx: CGContext, _ fill: CGGradient, from start: CGPoint = CGPoint(x: 180, y: 924),
          to end: CGPoint = CGPoint(x: 844, y: 100), rim: CGFloat = 0.12, content: () -> Void) {
    ctx.saveGState()
    setShadow(ctx, offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x202020))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(fill, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    content()
    ctx.restoreGState()

    ctx.addPath(tilePath)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(color(0xFFFFFF, rim))
    ctx.strokePath()
}

func roundedRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func playTriangle(_ ctx: CGContext, center: CGPoint, size: CGFloat, fill: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - size * 0.38, y: center.y + size * 0.5))
    path.addLine(to: CGPoint(x: center.x + size * 0.62, y: center.y))
    path.addLine(to: CGPoint(x: center.x - size * 0.38, y: center.y - size * 0.5))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
}

// MARK: - Designs

/// A record with a wave-shaped groove and an orange play label on deep blue (the icon until October 2026).
func drawRecord(_ ctx: CGContext) {
    tile(ctx, gradient([color(0x2B5BD7), color(0x152C6E), color(0x0B1638)], [0, 0.55, 1])) {
        let glow = gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 800), startRadius: 0, endCenter: CGPoint(x: 300, y: 800), endRadius: 520, options: [])

        let center = CGPoint(x: 512, y: 500)
        let radius: CGFloat = 318
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        setShadow(ctx, offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
        ctx.addEllipse(in: disc)
        ctx.setFillColor(color(0x0A0D16))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setLineWidth(3)
        for r in stride(from: radius - 24, through: 140, by: -17) {
            ctx.setStrokeColor(color(0x2A3350, r.truncatingRemainder(dividingBy: 34) < 17 ? 0.9 : 0.55))
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0), color(0xB8D4FF, 0.28), color(0xFFFFFF, 0)], [0.3, 0.5, 0.7]),
                               start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
        ctx.restoreGState()

        let wave = CGMutablePath()
        for i in 0...360 {
            let a = CGFloat(i) * .pi / 180
            let r = 238 + 16 * sin(a * 9) * max(0, sin(a / 2))
            let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            i == 0 ? wave.move(to: p) : wave.addLine(to: p)
        }
        ctx.addPath(wave)
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color(0x5EC8FF, 0.95))
        ctx.strokePath()

        let label = CGRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236)
        ctx.saveGState()
        ctx.addEllipse(in: label)
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xFFB547), color(0xF0731E)]), start: CGPoint(x: label.minX, y: label.maxY),
                               end: CGPoint(x: label.maxX, y: label.minY), options: [])
        ctx.restoreGState()
        playTriangle(ctx, center: CGPoint(x: center.x + 4, y: center.y), size: 104, fill: color(0xFFFFFF))
    }
}

/// Block spectrum bars with peak caps and a reflection, like the Analyzer applet.
func drawSpectrum(_ ctx: CGContext) {
    tile(ctx, gradient([color(0x323849), color(0x161A24), color(0x0B0E14)], [0, 0.6, 1]),
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100)) {
        let glow = gradient([color(0x6366F1, 0.35), color(0x6366F1, 0)])
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 300), startRadius: 0, endCenter: CGPoint(x: 512, y: 300), endRadius: 460, options: [])

        let heights = [6, 10, 14, 11, 16, 12, 9, 13, 7]
        let barWidth: CGFloat = 52, gap: CGFloat = 18, block: CGFloat = 26, pitch: CGFloat = 34, baseline: CGFloat = 268
        let startX = 512 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
        func blockColor(_ t: CGFloat) -> CGColor {
            t < 0.5 ? mix(0x22D3EE, 0x6366F1, t * 2) : mix(0x6366F1, 0xEC4899, (t - 0.5) * 2)
        }
        for (i, h) in heights.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + gap)
            for b in 0..<h {
                let y = baseline + CGFloat(b) * pitch
                roundedRect(ctx, CGRect(x: x, y: y, width: barWidth, height: block), radius: 5, fill: blockColor(CGFloat(b) / 15))
            }
            // Peak cap floating above the bar.
            roundedRect(ctx, CGRect(x: x, y: baseline + CGFloat(h + 1) * pitch, width: barWidth, height: 12), radius: 4, fill: color(0xFFFFFF, 0.85))
            // Reflection.
            for b in 0..<min(h, 4) {
                let y = baseline - 14 - CGFloat(b + 1) * pitch + (pitch - block)
                roundedRect(ctx, CGRect(x: x, y: y, width: barWidth, height: block), radius: 5,
                            fill: blockColor(CGFloat(b) / 15).copy(alpha: 0.22 - CGFloat(b) * 0.05)!)
            }
        }
    }
}

/// The app's own layout in miniature: toolbar over three panes, a play button in the middle one.
func drawPanes(_ ctx: CGContext) {
    tile(ctx, gradient([color(0xF8F9FC), color(0xDCE2EC)]), from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), rim: 0.5) {
        func card(_ rect: CGRect) {
            ctx.saveGState()
            setShadow(ctx, offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x1E293B, 0.18))
            roundedRect(ctx, rect, radius: 26, fill: color(0xFFFFFF))
            ctx.restoreGState()
        }
        // Toolbar with a play button and a progress bar.
        card(CGRect(x: 168, y: 768, width: 688, height: 88))
        ctx.addEllipse(in: CGRect(x: 192, y: 782, width: 60, height: 60))
        ctx.setFillColor(color(0x2563EB))
        ctx.fillPath()
        playTriangle(ctx, center: CGPoint(x: 224, y: 812), size: 26, fill: color(0xFFFFFF))
        roundedRect(ctx, CGRect(x: 280, y: 806, width: 540, height: 12), radius: 6, fill: color(0xD7DCE5))
        roundedRect(ctx, CGRect(x: 280, y: 806, width: 330, height: 12), radius: 6, fill: color(0x2563EB))

        // Media Sources.
        let left = CGRect(x: 168, y: 168, width: 168, height: 578)
        card(left)
        for (i, w) in [96, 112, 80, 104, 72, 96, 88].enumerated() {
            let y = left.maxY - 60 - CGFloat(i) * 70
            roundedRect(ctx, CGRect(x: left.minX + 22, y: y, width: 22, height: 22), radius: 6, fill: color(0x94A3B8))
            roundedRect(ctx, CGRect(x: left.minX + 54, y: y + 4, width: CGFloat(w) - 20, height: 14), radius: 7, fill: color(0xCBD5E1))
        }
        // Context, with the big play button and a waveform.
        let middle = CGRect(x: 354, y: 168, width: 316, height: 578)
        card(middle)
        let c = CGPoint(x: middle.midX, y: 512)
        ctx.saveGState()
        setShadow(ctx, offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x1D4ED8, 0.4))
        ctx.addEllipse(in: CGRect(x: c.x - 104, y: c.y - 104, width: 208, height: 208))
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0x60A5FA), color(0x1D4ED8)]), start: CGPoint(x: c.x, y: c.y + 104), end: CGPoint(x: c.x, y: c.y - 104), options: [])
        ctx.restoreGState()
        playTriangle(ctx, center: CGPoint(x: c.x + 8, y: c.y), size: 92, fill: color(0xFFFFFF))
        for i in 0..<11 {
            let h = 18 + 52 * abs(sin(CGFloat(i) * 0.9 + 0.4))
            roundedRect(ctx, CGRect(x: middle.minX + 46 + CGFloat(i) * 21, y: 300 - h / 2, width: 12, height: h), radius: 6, fill: color(0x3B82F6, 0.55))
        }
        // Playlist with the playing row highlighted.
        let right = CGRect(x: 688, y: 168, width: 168, height: 578)
        card(right)
        for i in 0..<8 {
            let y = right.maxY - 62 - CGFloat(i) * 64
            if i == 3 { roundedRect(ctx, CGRect(x: right.minX + 10, y: y - 14, width: right.width - 20, height: 44), radius: 12, fill: color(0xDBEAFE)) }
            roundedRect(ctx, CGRect(x: right.minX + 24, y: y, width: i == 3 ? 104 : 92 - CGFloat(i % 3) * 14, height: 14), radius: 7,
                        fill: i == 3 ? color(0x2563EB) : color(0xCBD5E1))
        }
    }
}

/// Northern lights over dark mountains with a pair of beamed notes.
func drawAurora(_ ctx: CGContext) {
    tile(ctx, gradient([color(0x1E1B4B), color(0x0B1030), color(0x050816)], [0, 0.55, 1]),
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100)) {
        // Stars.
        var seed: UInt64 = 42
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        for _ in 0..<46 {
            let r = 2 + random() * 4
            ctx.setFillColor(color(0xFFFFFF, 0.35 + random() * 0.5))
            ctx.fillEllipse(in: CGRect(x: 120 + random() * 784, y: 420 + random() * 480, width: r, height: r))
        }
        // Curtains: bright along the lower edge, fading upward.
        ctx.setBlendMode(.screen)
        for (base, amplitude, phase, thickness, hue) in [(560.0, 70.0, 0.4, 260.0, UInt32(0x34D399)), (650.0, 60.0, 2.1, 220.0, 0x22D3EE),
                                                         (720.0, 50.0, 3.6, 200.0, 0xA78BFA)] as [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32)] {
            let band = CGMutablePath()
            func top(_ x: CGFloat) -> CGFloat { base + amplitude * sin(x / 150 + phase) + 24 * sin(x / 47 + phase * 2) }
            band.move(to: CGPoint(x: 80, y: top(80)))
            for x in stride(from: 80, through: 944, by: 8) { band.addLine(to: CGPoint(x: CGFloat(x), y: top(CGFloat(x)))) }
            for x in stride(from: 944, through: 80, by: -8) { band.addLine(to: CGPoint(x: CGFloat(x), y: top(CGFloat(x)) - thickness)) }
            band.closeSubpath()
            ctx.saveGState()
            ctx.addPath(band)
            ctx.clip()
            ctx.drawLinearGradient(gradient([color(hue, 0.85), color(hue, 0)]), start: CGPoint(x: 0, y: base - thickness - amplitude),
                                   end: CGPoint(x: 0, y: base + amplitude), options: [.drawsBeforeStartLocation])
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)
        // Mountains.
        let ridge = CGMutablePath()
        ridge.move(to: CGPoint(x: 80, y: 80))
        for (x, y) in [(80, 250), (210, 330), (300, 270), (420, 380), (560, 240), (680, 320), (790, 230), (944, 300), (944, 80)] {
            ridge.addLine(to: CGPoint(x: x, y: y))
        }
        ridge.closeSubpath()
        ctx.addPath(ridge)
        ctx.setFillColor(color(0x04060F))
        ctx.fillPath()
        // Beamed eighth notes.
        ctx.saveGState()
        setShadow(ctx, offset: .zero, blur: 34, color: color(0xA7F3D0, 0.55))
        ctx.setFillColor(color(0xFFFFFF))
        for (cx, cy) in [(CGFloat(430), CGFloat(420)), (CGFloat(640), CGFloat(470))] {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: 0.38)
            ctx.fillEllipse(in: CGRect(x: -70, y: -50, width: 140, height: 100))
            ctx.restoreGState()
            ctx.fill(CGRect(x: cx + 48, y: cy + 8, width: 26, height: 330))
        }
        let beam = CGMutablePath()
        beam.move(to: CGPoint(x: 478, y: 758))
        beam.addLine(to: CGPoint(x: 714, y: 808))
        beam.addLine(to: CGPoint(x: 714, y: 740))
        beam.addLine(to: CGPoint(x: 478, y: 690))
        beam.closeSubpath()
        ctx.addPath(beam)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// A loudspeaker cone on warm coral.
func drawSpeaker(_ ctx: CGContext) {
    tile(ctx, gradient([color(0xFFA06B), color(0xF25C3C), color(0xC9302C)], [0, 0.5, 1])) {
        let c = CGPoint(x: 512, y: 512)
        func disc(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }
        // Frame.
        ctx.saveGState()
        setShadow(ctx, offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x5B1210, 0.55))
        ctx.addEllipse(in: disc(336))
        ctx.setFillColor(color(0x2A1714))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: disc(336))
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0x6E4A42), color(0x1E110E)]), start: CGPoint(x: 300, y: 848), end: CGPoint(x: 724, y: 176), options: [])
        ctx.restoreGState()
        // Rubber surround.
        ctx.saveGState()
        ctx.addEllipse(in: disc(304))
        ctx.clip()
        ctx.drawRadialGradient(gradient([color(0x120A08), color(0x3A2722), color(0x150C0A)], [0.82, 0.92, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 304, options: [])
        ctx.restoreGState()
        // Cone with faint ridges.
        ctx.saveGState()
        ctx.addEllipse(in: disc(256))
        ctx.clip()
        ctx.drawRadialGradient(gradient([color(0x0E0807), color(0x2B1C18), color(0x3C2823)], [0.3, 0.8, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 256, options: [])
        ctx.setLineWidth(2)
        for r in stride(from: CGFloat(240), through: 130, by: -22) {
            ctx.setStrokeColor(color(0xFFFFFF, 0.06))
            ctx.strokeEllipse(in: disc(r))
        }
        ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]), start: CGPoint(x: 330, y: 700), end: CGPoint(x: 512, y: 512), options: [])
        ctx.restoreGState()
        // Dust cap.
        ctx.saveGState()
        setShadow(ctx, offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.6))
        ctx.addEllipse(in: disc(104))
        ctx.clip()
        ctx.drawRadialGradient(gradient([color(0x8A6A60), color(0x3A2620), color(0x150C0A)], [0, 0.55, 1]),
                               startCenter: CGPoint(x: c.x - 36, y: c.y + 40), startRadius: 0, endCenter: c, endRadius: 104, options: [])
        ctx.restoreGState()
        ctx.setFillColor(color(0xFFFFFF, 0.28))
        ctx.fillEllipse(in: CGRect(x: c.x - 64, y: c.y + 26, width: 54, height: 30))
        // Highlight along the frame's upper left.
        ctx.addArc(center: c, radius: 320, startAngle: .pi * 0.58, endAngle: .pi * 0.95, clockwise: false)
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color(0xFFFFFF, 0.22))
        ctx.strokePath()
    }
}

/// An "A" whose crossbar is a sound wave, on a coral-to-magenta tile.
func drawMonogram(_ ctx: CGContext) {
    tile(ctx, gradient([color(0xFF8A3D), color(0xF0446B), color(0xB0177F)], [0, 0.5, 1])) {
        let glow = gradient([color(0xFFFFFF, 0.25), color(0xFFFFFF, 0)])
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 560, options: [])
        ctx.saveGState()
        setShadow(ctx, offset: CGSize(width: 0, height: -12), blur: 26, color: color(0x5A0A3A, 0.4))
        let letter = CGMutablePath()
        letter.move(to: CGPoint(x: 292, y: 252))
        letter.addLine(to: CGPoint(x: 512, y: 790))
        letter.addLine(to: CGPoint(x: 732, y: 252))
        ctx.addPath(letter)
        ctx.setLineWidth(112)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.strokePath()
        let wave = CGMutablePath()
        for i in 0...100 {
            let t = CGFloat(i) / 100
            let x = 352 + 320 * t
            let y = 430 + 34 * sin(t * .pi * 5) * sin(t * .pi)
            i == 0 ? wave.move(to: CGPoint(x: x, y: y)) : wave.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.addPath(wave)
        ctx.setLineWidth(42)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

let designs: [(name: String, title: String, draw: (CGContext) -> Void)] = [
    ("record", "Record", drawRecord),
    ("spectrum", "Spectrum", drawSpectrum),
    ("panes", "Three Panes", drawPanes),
    ("aurora", "Aurora", drawAurora),
    ("speaker", "Speaker (current)", drawSpeaker),
    ("monogram", "Monogram", drawMonogram),
]

func render(_ draw: (CGContext) -> Void, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Commands

var arguments = Array(CommandLine.arguments.dropFirst())

if let i = arguments.firstIndex(of: "--preview") {
    let dir = URL(fileURLWithPath: i + 1 < arguments.count ? arguments[i + 1] : "icon-preview")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for d in designs { try writePNG(render(d.draw, size: 1024), to: dir.appendingPathComponent("\(d.name).png")) }

    // Comparison sheet: each design large, then at Dock, Finder-list and menu sizes, on light and dark.
    let cellW = 380, cellH = 470, columns = 3
    let rows = (designs.count + columns - 1) / columns
    let width = cellW * columns, height = cellH * rows
    let sheet = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.scaleBy(x: 2, y: 2)
    sheet.setFillColor(color(0xEEF0F4))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
    for (n, d) in designs.enumerated() {
        let col = n % columns, row = n / columns
        let x = CGFloat(col * cellW), top = CGFloat(height - row * cellH)
        sheet.draw(render(d.draw, size: 512), in: CGRect(x: x + 50, y: top - 300, width: 280, height: 280))
        // Small sizes on a light and a dark strip.
        for (stripY, bg) in [(top - 370, color(0xFFFFFF)), (top - 430, color(0x1F2329))] {
            sheet.setFillColor(bg)
            sheet.fill(CGRect(x: x + 50, y: stripY, width: 280, height: 56))
            var cx = x + 64
            for s in [48, 32, 16] {
                sheet.draw(render(d.draw, size: s * 2), in: CGRect(x: cx, y: stripY + (56 - CGFloat(s)) / 2, width: CGFloat(s), height: CGFloat(s)))
                cx += CGFloat(s) + 26
            }
        }
        let label = "\(n + 1). \(d.title)" as NSString
        label.draw(at: NSPoint(x: x + 50, y: top - 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.current = nil
    try writePNG(sheet.makeImage()!, to: dir.appendingPathComponent("comparison.png"))
    print("wrote \(designs.count) designs and comparison.png to \(dir.path)")
    exit(0)
}

var designName = "speaker"
if let i = arguments.firstIndex(of: "--design"), i + 1 < arguments.count {
    designName = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
}
guard let design = designs.first(where: { $0.name == designName }) else {
    FileHandle.standardError.write("unknown design \(designName); choose from \(designs.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments.first ?? "Resources/Assets.xcassets/AppIcon.appiconset")
let slots: [(point: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for slot in slots {
    let name = "icon_\(slot.point)x\(slot.point)\(slot.scale == 2 ? "@2x" : "").png"
    try writePNG(render(design.draw, size: slot.point * slot.scale), to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.point)x\(slot.point)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("wrote the \(design.name) icon (\(slots.count) sizes) to \(output.path)")
