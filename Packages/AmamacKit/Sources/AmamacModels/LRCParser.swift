import Foundation

/// A lyrics line with an optional timestamp (from LRC).
public struct LyricsLine: Sendable, Equatable {
    public var time: TimeInterval?
    public var text: String
}

/// Parses LRC ("[mm:ss.xx] text") synced lyrics.
public enum LRCParser {
    static let timestamp = try! NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")

    public static func looksSynced(_ text: String) -> Bool {
        let ns = text as NSString
        return timestamp.numberOfMatches(in: text, range: NSRange(location: 0, length: min(ns.length, 2000))) >= 2
    }

    /// Returns lines sorted by time. Lines with several timestamps are repeated; metadata tags such
    /// as `[ar:…]` are dropped. Unsynced text yields lines without times.
    public static func parse(_ text: String) -> [LyricsLine] {
        guard looksSynced(text) else {
            return text.components(separatedBy: .newlines).map { LyricsLine(time: nil, text: $0) }
        }
        var lines: [LyricsLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = timestamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let end = matches.last!.range.location + matches.last!.range.length
            let body = ns.substring(from: end).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    fraction = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                lines.append(LyricsLine(time: minutes * 60 + seconds + fraction, text: body))
            }
        }
        return lines.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    /// Index of the line being sung at `time`.
    public static func currentLine(_ lines: [LyricsLine], at time: TimeInterval) -> Int? {
        var current: Int?
        for (i, line) in lines.enumerated() {
            guard let t = line.time else { return nil }
            if t <= time + 0.15 { current = i } else { break }
        }
        return current
    }

    /// Plain text without timestamps.
    public static func plainText(_ text: String) -> String {
        guard looksSynced(text) else { return text }
        let ns = text as NSString
        return timestamp.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
}
