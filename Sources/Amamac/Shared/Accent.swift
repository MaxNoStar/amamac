import AppKit
import SwiftUI

extension NSColor {
    /// Amamac's neon orange, from the AccentColor asset. The asset is also the app's global accent
    /// colour, so standard controls and selections use it while the system accent is Multicolor;
    /// custom drawing uses this directly so the player stays orange under any system accent.
    nonisolated static let amamacAccent = NSColor(named: "AccentColor") ?? NSColor(srgbRed: 1, green: 0.416, blue: 0.051, alpha: 1)
}

extension Color {
    nonisolated static let amamacAccent = Color(nsColor: .amamacAccent)
    /// A darker orange for fills behind white text (#C2410C, 5.2:1); the bright accent is only
    /// 2.9:1 against white, so it never carries small text.
    nonisolated static let amamacAccentFill = Color(.sRGB, red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255)
}
