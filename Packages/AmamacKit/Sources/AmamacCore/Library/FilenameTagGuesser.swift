import Foundation

/// Guesses tags from a file path using a pattern such as `%artist%/%album%/%track% - %title%`.
public enum FilenameTagGuesser {
    public static let presets = [
        "%track% - %title%",
        "%track% - %artist% - %title%",
        "%artist% - %title%",
        "%artist%/%album%/%track% - %title%",
        "%albumartist%/%album% (%year%)/%track% - %title%",
        "%track%. %title%",
    ]

    static let numeric: Set<String> = ["track", "discnumber", "year"]
    static let known: Set<String> = ["title", "artist", "albumartist", "album", "genre", "composer", "comment", "track", "discnumber", "year"]

    /// Field name → value for the fields in `pattern`, or nil when the path does not match.
    public static func guess(path: String, pattern: String) -> [String: String]? {
        var regex = ""
        var fields: [String] = []
        var rest = Substring(pattern)
        while let start = rest.firstIndex(of: "%") {
            regex += NSRegularExpression.escapedPattern(for: String(rest[..<start]))
            let after = rest[rest.index(after: start)...]
            guard let end = after.firstIndex(of: "%") else { return nil }
            let name = String(after[..<end]).lowercased()
            guard known.contains(name) else { return nil }
            fields.append(name)
            regex += numeric.contains(name) ? "(\\d+)" : "([^/]+?)"
            rest = after[after.index(after: end)...]
        }
        regex += NSRegularExpression.escapedPattern(for: String(rest))
        let components = pattern.split(separator: "/").count
        let tail = path.split(separator: "/").suffix(components).joined(separator: "/")
        let stem = (tail as NSString).deletingPathExtension
        guard let re = try? NSRegularExpression(pattern: "^" + regex + "$"),
              let match = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { return nil }
        var result: [String: String] = [:]
        for (i, name) in fields.enumerated() {
            guard let range = Range(match.range(at: i + 1), in: stem) else { continue }
            var value = String(stem[range]).trimmingCharacters(in: .whitespaces)
            if numeric.contains(name) { value = String(Int(value) ?? 0) }
            result[name] = value
        }
        return result
    }
}
