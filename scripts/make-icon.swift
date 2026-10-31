#!/usr/bin/env swift
// Draws Amamac's app icon (an original design: a record with a wave-shaped groove and a play
// mark on a deep blue tile) and writes every size the asset catalog needs.
//
//   swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Tile: the macOS icon grid's 824 pt body with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x10204A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x2B5BD7), color(0x152C6E), color(0x0B1638)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
    // A soft highlight in the upper left.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 800), startRadius: 0, endCenter: CGPoint(x: 300, y: 800), endRadius: 520, options: [])

    // The record.
    let center = CGPoint(x: 512, y: 500)
    let radius: CGFloat = 318
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.setFillColor(color(0x0A0D16))
    ctx.fillPath()
    ctx.restoreGState()

    // Grooves, with a sheen across them.
    ctx.setLineWidth(3)
    for r in stride(from: radius - 24, through: 140, by: -17) {
        ctx.setStrokeColor(color(0x2A3350, r.truncatingRemainder(dividingBy: 34) < 17 ? 0.9 : 0.55))
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0), color(0xB8D4FF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0.3, 0.5, 0.7])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    ctx.restoreGState()

    // A sound wave running round one groove.
    let wave = CGMutablePath()
    let waveRadius: CGFloat = 238
    for i in 0...360 {
        let a = CGFloat(i) * .pi / 180
        let r = waveRadius + 16 * sin(a * 9) * max(0, sin(a / 2))
        let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        i == 0 ? wave.move(to: p) : wave.addLine(to: p)
    }
    ctx.addPath(wave)
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0x5EC8FF, 0.95))
    ctx.strokePath()

    // Label with a play mark.
    let label: CGFloat = 118
    let labelRect = CGRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2)
    ctx.saveGState()
    ctx.addEllipse(in: labelRect)
    ctx.clip()
    let labelGradient = CGGradient(colorsSpace: space, colors: [color(0xFFB547), color(0xF0731E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(labelGradient, start: CGPoint(x: labelRect.minX, y: labelRect.maxY), end: CGPoint(x: labelRect.maxX, y: labelRect.minY), options: [])
    ctx.restoreGState()
    let play = CGMutablePath()
    play.move(to: CGPoint(x: center.x - 34, y: center.y + 52))
    play.addLine(to: CGPoint(x: center.x + 58, y: center.y))
    play.addLine(to: CGPoint(x: center.x - 34, y: center.y - 52))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Thin rim light on the tile.
    ctx.addPath(tile)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.strokePath()
    return ctx.makeImage()!
}

let slots: [(point: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for slot in slots {
    let pixels = slot.point * slot.scale
    let name = "icon_\(slot.point)x\(slot.point)\(slot.scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: pixels))
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.point)x\(slot.point)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(slots.count) icon sizes to \(output.path)")
