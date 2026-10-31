
import AmamacBase
import AmamacQuery
import Foundation
import GRDB

/// A value bound to a generated SQL fragment.
public enum SQLValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case double(Double)
    case date(Date)
}

/// A piece of SQL with `?` placeholders. Column references use the aliases `t` (track) and
/// `s` (statistics, LEFT JOINed).
public struct SQLFragment: Sendable, Equatable {
    public var sql: String
    public var arguments: [SQLValue]

    public init(_ sql: String, _ arguments: [SQLValue] = []) {
        self.sql = sql
        self.arguments = arguments
    }

    public static let alwaysTrue = SQLFragment("1")
}

extension CollectionQuery {
    /// SQL condition for this query. `now` anchors relative dates.
    public func sql(now: Date = Date()) -> SQLFragment {
        let groupFragments = groups.compactMap { group -> SQLFragment? in
            let parts = group.map { $0.sql(now: now) }
            guard !parts.isEmpty else { return nil }
            if parts.count == 1 { return parts[0] }
            return SQLFragment("(" + parts.map(\.sql).joined(separator: " OR ") + ")", parts.flatMap(\.arguments))
        }
        guard !groupFragments.isEmpty else { return .alwaysTrue }
        return SQLFragment(groupFragments.map(\.sql).joined(separator: " AND "), groupFragments.flatMap(\.arguments))
    }
}

extension QueryTerm {
    static let labelExists = "EXISTS (SELECT 1 FROM track_label tl JOIN label l ON l.id = tl.labelId WHERE tl.trackId = t.id AND amamac_fold(l.name) LIKE ? ESCAPE '\\')"
    static let lyricsExists = "EXISTS (SELECT 1 FROM lyrics ly WHERE ly.trackId = t.id AND amamac_fold(ly.text) LIKE ? ESCAPE '\\')"

    public func sql(now: Date) -> SQLFragment {
        let base = positiveSQL(now: now)
        return negated ? SQLFragment("NOT (\(base.sql))", base.arguments) : base
    }

    private func likePattern(_ value: String) -> String {
        "%" + TextFolding.likeEscaped(TextFolding.fold(value)) + "%"
    }

    private func positiveSQL(now: Date) -> SQLFragment {
        guard let field else {
            let p = likePattern(value)
            return SQLFragment("(t.searchFolded LIKE ? ESCAPE '\\' OR \(Self.labelExists))", [.text(p), .text(p)])
        }
        switch field.kind {
        case .text: return textSQL(field)
        case .number: return numberSQL(field)
        case .date: return dateSQL(field, now: now)
        }
    }

    private func textColumn(_ field: QueryField) -> String? {
        switch field {
        case .title: "t.title"
        case .artist: "t.artist"
        case .album: "t.album"
        case .albumartist: "t.albumArtist"
        case .genre: "t.genre"
        case .composer: "t.composer"
        case .comment: "t.comment"
        case .filename: "t.path"
        case .format: "t.format"
        default: nil
        }
    }

    private func textSQL(_ field: QueryField) -> SQLFragment {
        if field == .label {
            if op == .equals && value.isEmpty {
                return SQLFragment("NOT EXISTS (SELECT 1 FROM track_label tl WHERE tl.trackId = t.id)")
            }
            let pattern = op == .equals ? TextFolding.likeEscaped(TextFolding.fold(value)) : likePattern(value)
            return SQLFragment(Self.labelExists, [.text(pattern)])
        }
        if field == .lyrics {
            if op == .equals && value.isEmpty {
                return SQLFragment("NOT EXISTS (SELECT 1 FROM lyrics ly WHERE ly.trackId = t.id AND ly.text <> '')")
            }
            return SQLFragment(Self.lyricsExists, [.text(likePattern(value))])
        }
        let column = textColumn(field)!
        // Pre-folded columns avoid calling the fold function per row.
        let foldedColumn: String? = switch field {
        case .artist: "t.artistKey"
        case .genre: "t.genreKey"
        case .composer: "t.composerKey"
        default: nil
        }
        if let foldedColumn { return comparisonFolded(foldedColumn) }
        if field == .albumartist {
            // Album artist filters also match the artist when no album artist is set.
            let expr = "(CASE WHEN t.albumArtist = '' THEN t.artist ELSE t.albumArtist END)"
            return comparisonText(expr)
        }
        return comparisonText(column)
    }

    private func comparisonFolded(_ column: String) -> SQLFragment {
        switch op {
        case .equals: return SQLFragment("\(column) = ?", [.text(TextFolding.fold(value))])
        case .greater: return SQLFragment("\(column) > ?", [.text(TextFolding.fold(value))])
        case .less: return SQLFragment("\(column) < ?", [.text(TextFolding.fold(value))])
        case .contains:
            if value.isEmpty { return .alwaysTrue }
            return SQLFragment("\(column) LIKE ? ESCAPE '\\'", [.text(likePattern(value))])
        }
    }

    private func comparisonText(_ expr: String) -> SQLFragment {
        switch op {
        case .equals:
            if value.isEmpty { return SQLFragment("\(expr) = ''") }
            return SQLFragment("amamac_fold(\(expr)) = ?", [.text(TextFolding.fold(value))])
        case .greater:
            return SQLFragment("amamac_fold(\(expr)) > ?", [.text(TextFolding.fold(value))])
        case .less:
            return SQLFragment("amamac_fold(\(expr)) < ?", [.text(TextFolding.fold(value))])
        case .contains:
            if value.isEmpty { return .alwaysTrue }
            return SQLFragment("amamac_fold(\(expr)) LIKE ? ESCAPE '\\'", [.text(likePattern(value))])
        }
    }

    private func numberExpression(_ field: QueryField) -> String {
        switch field {
        case .year: "t.year"
        case .tracknumber: "t.trackNumber"
        case .discnumber: "t.discNumber"
        case .bpm: "t.bpm"
        case .length: "(t.durationMs / 1000)"
        case .bitrate: "t.bitrate"
        case .samplerate: "t.sampleRate"
        case .filesize: "t.fileSize"
        case .score: "COALESCE(s.score, 0)"
        case .playcount: "COALESCE(s.playCount, 0)"
        case .rating: "COALESCE(s.rating, 0)"
        default: "0"
        }
    }


    private func numberSQL(_ field: QueryField) -> SQLFragment {
        let expr = numberExpression(field)
        if op == .equals && value.isEmpty { return SQLFragment("\(expr) = 0") }
        guard let n = numericValue(field) else { return SQLFragment("0") }
        switch op {
        case .greater: return SQLFragment("\(expr) > ?", [.double(n)])
        case .less: return SQLFragment("\(expr) < ?", [.double(n)])
        case .equals, .contains:
            if field == .filesize {
                let half = 512.0 * 1024
                return SQLFragment("\(expr) BETWEEN ? AND ?", [.double(n - half), .double(n + half)])
            }
            return SQLFragment("\(expr) = ?", [.double(n)])
        }
    }

    private func dateExpression(_ field: QueryField) -> String {
        switch field {
        case .added: "t.dateAdded"
        case .modified: "t.mtime"
        case .firstplay: "s.firstPlayed"
        case .lastplay: "s.lastPlayed"
        default: "NULL"
        }
    }


    private func dateSQL(_ field: QueryField, now: Date) -> SQLFragment {
        let expr = dateExpression(field)
        if op == .equals && value.isEmpty { return SQLFragment("\(expr) IS NULL") }
        guard let range = dateRange(now: now) else { return SQLFragment("0") }
        var clauses: [String] = []
        var args: [SQLValue] = []
        if let lower = range.lower { clauses.append("\(expr) >= ?"); args.append(.date(lower)) }
        if let upper = range.upper { clauses.append("\(expr) < ?"); args.append(.date(upper)) }
        return SQLFragment("(" + clauses.joined(separator: " AND ") + ")", args)
    }
}

extension SQLValue {
    var databaseValue: any DatabaseValueConvertible {
        switch self {
        case .text(let s): s
        case .int(let i): i
        case .double(let d): d
        case .date(let d): d
        }
    }
}

extension SQLFragment {
    var statementArguments: StatementArguments {
        StatementArguments(arguments.map(\.databaseValue))
    }
}
