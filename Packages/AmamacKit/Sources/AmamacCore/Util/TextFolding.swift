import Foundation

/// Case- and diacritic-insensitive text folding used for searching and sorting.
public enum TextFolding {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Sort key: folded, with a leading English article moved out of the way
    /// ("The Beatles" sorts as "beatles").
    public static func sortKey(_ s: String) -> String {
        let folded = fold(s.trimmingCharacters(in: .whitespaces))
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) && folded.count > article.count {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    /// Escapes `%`, `_` and `\` for a SQL `LIKE ... ESCAPE '\'` pattern.
    public static func likeEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

public enum TimeFormatting {
    /// "m:ss" or "h:mm:ss".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func durationMs(_ ms: Int) -> String { duration(TimeInterval(ms) / 1000) }

    /// Relative description such as "3 days ago" or "Never".
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
