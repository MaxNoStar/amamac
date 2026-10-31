public enum XMLText {
    /// Escapes text for XML element content and double-quoted attributes, dropping characters XML
    /// doesn't allow at all (most control characters), which would make the whole file unreadable.
    public static func escape(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter(isAllowed)))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// XML 1.0's Char production (Swift strings never hold surrogates).
    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }
}
