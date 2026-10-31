import Foundation

/// Makes text from tags, feeds and links safe to use in a file or folder name. Works on Unicode
/// scalars rather than characters, so a combining mark after a "/" can't hide the separator.
public enum PathComponent {
    /// `text` with every "/" replaced by `replacement` and control characters (NUL, line breaks,
    /// tabs…) removed.
    public static func withoutSeparators(_ text: String, replacement: String = "-") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "/" {
                scalars.append(contentsOf: replacement.unicodeScalars)
            } else if scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// A whole file or folder name: no separators or control characters, trimmed, a leading dot
    /// replaced by "_" (so it is neither hidden nor "." or ".."), and never empty.
    public static func sanitized(_ text: String) -> String {
        var name = withoutSeparators(text).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name.isEmpty ? "_" : name
    }
}
