// Rasterizes the mascot SVGs in docs/images/mascot with macOS's own SVG renderer and composes
// the GitHub social preview. `make mascot` runs it; nothing needs installing.
//   swift scripts/render-mascot.swift                 → all PNGs in docs/images/mascot
//   swift scripts/render-mascot.swift FILE.svg OUT.png WIDTH [BACKGROUND_HEX]   → one preview
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// A transparent sRGB canvas of `width`×`height` pixels drawn by `draw` (origin bottom left).
func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func svg(_ url: URL) -> NSImage {
    guard let image = NSImage(contentsOf: url), image.size.width > 0 else { fatalError("cannot read \(url.path)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print("\(url.lastPathComponent): \(image.width)×\(image.height), \(size / 1024) KB")
}

/// `file` scaled to `width` pixels wide, on `background` (transparent when nil).
func render(_ file: URL, width: Int, background: NSColor? = nil) -> CGImage {
    let image = svg(file)
    let height = Int((image.size.height * CGFloat(width) / image.size.width).rounded())
    return canvas(width, height) { ctx in
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    }
}

/// `mascot.svg` for dark pages: a soft stage light behind him and a lighter jacket and jeans, so his
/// dark mustache, quiff and jacket don't sink into the background. The drawing itself stays in one file.
func darkVariant(of source: String) -> String {
    let spotlight = """
          <radialGradient id="spotlight" cx="0.5" cy="0.5" r="0.5">
            <stop offset="0" stop-color="#4E3D5E" stop-opacity="0.95"/>
            <stop offset="0.65" stop-color="#3A2D48" stop-opacity="0.7"/>
            <stop offset="1" stop-color="#3A2D48" stop-opacity="0"/>
          </radialGradient>
        </defs>

        <!-- Stage light (dark variant only) -->
        <ellipse cx="256" cy="282" rx="262" ry="282" fill="url(#spotlight)"/>
      """
    var dark = source.replacingOccurrences(of: "  </defs>", with: spotlight)
    for (light, lifted) in [("#3D3550", "#4D4470"), ("#574D6E", "#6B6090"), ("#34406B", "#43538F")] {
        dark = dark.replacingOccurrences(of: light, with: lifted)
    }
    return dark.replacingOccurrences(of: "Amamac's mascot:", with: "Amamac's mascot (for dark backgrounds):")
}

/// 1280×640: the mascot on the right, wordmark and tagline on the left, on a dark stage.
func socialPreview(mascot: URL) -> CGImage {
    canvas(1280, 640) { ctx in
        let stage = NSGradient(colors: [color("2A1E2E"), color("140F1A")])!
        stage.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 640), angle: -90)
        let glow = NSGradient(colors: [color("F26B3A", alpha: 0.38), color("F26B3A", alpha: 0)])!
        glow.draw(fromCenter: NSPoint(x: 930, y: 300), radius: 0, toCenter: NSPoint(x: 930, y: 300), radius: 360, options: [])
        let image = svg(mascot)
        let height: CGFloat = 580, width = image.size.width * height / image.size.height
        image.draw(in: NSRect(x: 930 - width / 2, y: 26, width: width, height: height))

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, at point: NSPoint) {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: textColor]).draw(at: point)
        }
        text("Amamac", size: 132, weight: .heavy, color: .white, at: NSPoint(x: 84, y: 318))
        text("A music player for macOS", size: 40, weight: .semibold, color: color("FFD1DC"), at: NSPoint(x: 90, y: 252))
        text("in the spirit of Amarok", size: 40, weight: .semibold, color: color("FFD1DC"), at: NSPoint(x: 90, y: 202))
        text("Apple Silicon  ·  MIT", size: 26, weight: .medium, color: color("FFFFFF", alpha: 0.6), at: NSPoint(x: 92, y: 120))
    }
}

let args = CommandLine.arguments.dropFirst()
if args.count >= 3 {
    let a = Array(args)
    writePNG(render(URL(fileURLWithPath: a[0]), width: Int(a[2]) ?? 800, background: a.count > 3 ? color(a[3]) : nil),
             to: URL(fileURLWithPath: a[1]))
} else {
    let dir = URL(fileURLWithPath: args.first ?? "docs/images/mascot")
    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    let master = try! String(contentsOf: file("mascot.svg"), encoding: .utf8)
    try! darkVariant(of: master).write(to: file("mascot-dark.svg"), atomically: true, encoding: .utf8)
    print("mascot-dark.svg: derived from mascot.svg")
    writePNG(render(file("mascot.svg"), width: 800), to: file("mascot@2x.png"))
    writePNG(render(file("badge.svg"), width: 256), to: file("badge-256.png"))
    writePNG(render(file("badge.svg"), width: 64), to: file("badge-64.png"))
    writePNG(socialPreview(mascot: file("mascot-dark.svg")), to: file("social-preview.png"))
}
