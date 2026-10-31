import Foundation

/// Fields understood by the collection filter language (Amarok's keywords).
public enum QueryField: String, CaseIterable, Sendable, Codable {
    case title, artist, album, albumartist, genre, composer, comment, filename, label, lyrics, format
    case year, tracknumber, discnumber, bpm, length, bitrate, samplerate, filesize, score, playcount, rating
    case added, firstplay, lastplay, modified

    public enum Kind: Sendable { case text, number, date }

    public var kind: Kind {
        switch self {
        case .title, .artist, .album, .albumartist, .genre, .composer, .comment, .filename, .label, .lyrics, .format:
            return .text
        case .year, .tracknumber, .discnumber, .bpm, .length, .bitrate, .samplerate, .filesize, .score,
             .playcount, .rating:
            return .number
        case .added, .firstplay, .lastplay, .modified:
            return .date
        }
    }

    /// Human readable name used by the Edit Filter dialog.
    public var displayName: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumartist: "Album Artist"
        case .genre: "Genre"
        case .composer: "Composer"
        case .comment: "Comment"
        case .filename: "File Name"
        case .label: "Label"
        case .lyrics: "Lyrics"
        case .format: "Format"
        case .year: "Year"
        case .tracknumber: "Track Number"
        case .discnumber: "Disc Number"
        case .bpm: "BPM"
        case .length: "Length"
        case .bitrate: "Bit Rate"
        case .samplerate: "Sample Rate"
        case .filesize: "File Size"
        case .score: "Score"
        case .playcount: "Play Count"
        case .rating: "Rating"
        case .added: "Added"
        case .firstplay: "First Played"
        case .lastplay: "Last Played"
        case .modified: "Modified"
        }
    }

    static func lookup(_ keyword: String) -> QueryField? {
        let k = keyword.lowercased()
        if let f = QueryField(rawValue: k) { return f }
        switch k {
        case "codec", "type": return .format
        case "first": return .firstplay
        case "played": return .lastplay
        case "track": return .tracknumber
        case "disc": return .discnumber
        case "size": return .filesize
        case "time": return .length
        default: return nil
        }
    }
}

public enum QueryOperator: String, Sendable, Codable {
    /// `field:value` — substring for text, equality for numbers, "within" for relative dates.
    case contains
    case equals
    case greater
    case less

    var symbol: String {
        switch self {
        case .contains: ""
        case .equals: "="
        case .greater: ">"
        case .less: "<"
        }
    }
}

public struct QueryTerm: Sendable, Equatable, Codable {
    public var negated: Bool
    /// `nil` means free text that matches title, artist, album, album artist, composer, genre,
    /// year, file name and labels.
    public var field: QueryField?
    public var op: QueryOperator
    public var value: String

    public init(negated: Bool = false, field: QueryField? = nil, op: QueryOperator = .contains, value: String) {
        self.negated = negated
        self.field = field
        self.op = op
        self.value = value
    }

    /// Serializes back to filter syntax.
    public var text: String {
        let quoted = value.contains(" ") || value.isEmpty ? "\"\(value)\"" : value
        let body = field.map { "\($0.rawValue):\(op.symbol)\(quoted)" } ?? quoted
        return (negated ? "-" : "") + body
    }
}

/// A parsed filter. Like Amarok, terms separated by whitespace are ANDed and `OR` joins its
/// neighbours into one group, so `a b OR c` means `a AND (b OR c)`.
public struct CollectionQuery: Sendable, Equatable, Codable {
    public var groups: [[QueryTerm]]

    public init(groups: [[QueryTerm]] = []) { self.groups = groups }

    public var isEmpty: Bool { groups.allSatisfy(\.isEmpty) }

    public var text: String {
        groups.map { $0.map(\.text).joined(separator: " OR ") }.joined(separator: " ")
    }

    public static func parse(_ input: String) -> CollectionQuery {
        var groups: [[QueryTerm]] = []
        var pendingOr = false
        for token in tokenize(input) {
            if !token.quoted && token.text == "OR" { pendingOr = !groups.isEmpty; continue }
            if !token.quoted && token.text == "AND" { pendingOr = false; continue }
            guard let term = parseTerm(token) else { continue }
            if pendingOr, !groups.isEmpty {
                groups[groups.count - 1].append(term)
            } else {
                groups.append([term])
            }
            pendingOr = false
        }
        return CollectionQuery(groups: groups)
    }

    struct Token: Equatable {
        var text: String
        var quoted: Bool
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var sawQuote = false
        for ch in input {
            if ch == "\"" {
                inQuotes.toggle()
                sawQuote = true
                current.append(ch)
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty || sawQuote { tokens.append(Token(text: current, quoted: sawQuote)) }
                current = ""
                sawQuote = false
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty || sawQuote { tokens.append(Token(text: current, quoted: sawQuote)) }
        return tokens
    }

    static func parseTerm(_ token: Token) -> QueryTerm? {
        var text = Substring(token.text)
        var negated = false
        if text.hasPrefix("-"), text.count > 1 {
            negated = true
            text = text.dropFirst()
        }
        if let colon = text.firstIndex(of: ":"), colon != text.startIndex,
           !text[..<colon].contains("\""),
           let field = QueryField.lookup(String(text[..<colon])) {
            var rest = text[text.index(after: colon)...]
            var op = QueryOperator.contains
            if let first = rest.first {
                switch first {
                case "=": op = .equals; rest = rest.dropFirst()
                case ">": op = .greater; rest = rest.dropFirst()
                case "<": op = .less; rest = rest.dropFirst()
                default: break
                }
            }
            return QueryTerm(negated: negated, field: field, op: op, value: unquote(rest))
        }
        let value = unquote(text)
        if value.isEmpty { return nil }
        return QueryTerm(negated: negated, field: nil, op: .contains, value: value)
    }

    static func unquote(_ s: Substring) -> String {
        String(s.filter { $0 != "\"" })
    }
}
