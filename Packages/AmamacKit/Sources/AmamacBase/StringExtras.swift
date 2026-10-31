extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension String {
    /// The text on one line: line and paragraph breaks become spaces. For line-based file formats
    /// such as M3U and PLS, where a break would start a new entry.
    public var singleLine: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar in
            switch scalar {
            case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": " "
            default: scalar
            }
        }))
    }
}
