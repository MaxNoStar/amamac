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
}
