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
