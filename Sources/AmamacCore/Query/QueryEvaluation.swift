import Foundation

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

/// Date values in filters: relative ages (`2w`, `1y2m`), named periods, or absolute dates.
public enum QueryDateValue: Equatable, Sendable {
    /// A point in time computed as "now minus age".
    case relative(Date)
    /// An absolute calendar day starting at the given date.
    case day(Date)

    public static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> QueryDateValue? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        switch s.lowercased() {
        case "today": return .relative(calendar.startOfDay(for: now))
        case "yesterday": return .relative(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!)
        case "last week": return .relative(calendar.date(byAdding: .day, value: -7, to: now)!)
        case "last month": return .relative(calendar.date(byAdding: .month, value: -1, to: now)!)
        case "two months ago": return .relative(calendar.date(byAdding: .month, value: -2, to: now)!)
        case "three months ago": return .relative(calendar.date(byAdding: .month, value: -3, to: now)!)
        default: break
        }
        if let age = parseAge(s, now: now, calendar: calendar) { return .relative(age) }
        if let day = parseDay(s, now: now, calendar: calendar) { return .day(day) }
        return nil
    }

    /// Units (case sensitive, as in Amarok): y years, m months, w weeks, d days, h hours,
    /// M minutes, s seconds. Units can be combined: `1y2m`.
    static func parseAge(_ s: String, now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            guard let n = Int(number) else { return nil }
            number = ""
            sawUnit = true
            switch ch {
            case "y": components.year = (components.year ?? 0) - n
            case "m": components.month = (components.month ?? 0) - n
            case "w": components.day = (components.day ?? 0) - 7 * n
            case "d": components.day = (components.day ?? 0) - n
            case "h": components.hour = (components.hour ?? 0) - n
            case "M": components.minute = (components.minute ?? 0) - n
            case "s": components.second = (components.second ?? 0) - n
            default: return nil
            }
        }
        guard sawUnit, number.isEmpty else { return nil }
        return calendar.date(byAdding: components, to: now)
    }

    static func parseDay(_ s: String, now: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: now)
        var parts: [Int]
        var dayFirst = true
        if s.contains("-") {
            parts = s.split(separator: "-").compactMap { Int($0) }
            if let first = parts.first, first > 31 { dayFirst = false } // yyyy-mm-dd
        } else if s.contains(".") {
            parts = s.split(separator: ".").compactMap { Int($0) }
        } else if s.contains("/") {
            parts = s.split(separator: "/").compactMap { Int($0) }
        } else {
            return nil
        }
        var c = DateComponents()
        switch (parts.count, dayFirst) {
        case (3, true): c.day = parts[0]; c.month = parts[1]; c.year = parts[2]
        case (3, false): c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        case (2, true): c.day = parts[0]; c.month = parts[1]; c.year = year
        default: return nil
        }
        guard let date = calendar.date(from: c) else { return nil }
        return calendar.startOfDay(for: date)
    }
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

    /// In-memory evaluation, used by dynamic playlists and tests.
    public func matches(_ track: Track, statistics: TrackStatistics?, labels: [String] = [],
                        lyrics: String? = nil, now: Date = Date()) -> Bool {
        let ctx = QueryMatchContext(track: track, statistics: statistics, labels: labels, lyrics: lyrics, now: now)
        return groups.allSatisfy { group in group.isEmpty || group.contains { $0.matches(ctx) } }
    }
}

struct QueryMatchContext {
    var track: Track
    var statistics: TrackStatistics?
    var labels: [String]
    var lyrics: String?
    var now: Date
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

    /// Converts the user's number into the column's unit.
    func numericValue(_ field: QueryField) -> Double? {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .length:
            // Seconds, "m:ss" or "h:mm:ss".
            let parts = v.split(separator: ":").map { Double($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1! }
        case .rating:
            return Double(v).map { $0 * 2 }
        case .filesize:
            return Double(v).map { $0 * 1024 * 1024 }
        default:
            return Double(v)
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

    /// Converts the term into a date range check `(lower, upper)`; either may be nil.
    func dateRange(now: Date) -> (lower: Date?, upper: Date?)? {
        guard let parsed = QueryDateValue.parse(value, now: now) else { return nil }
        switch parsed {
        case .relative(let point):
            switch op {
            case .less, .contains: return (point, nil)      // newer than: "less time ago"
            case .greater: return (nil, point)              // older than
            case .equals: return (point.addingTimeInterval(-86_400), point.addingTimeInterval(86_400))
            }
        case .day(let day):
            let next = day.addingTimeInterval(86_400)
            switch op {
            case .less: return (nil, day)
            case .greater: return (next, nil)
            case .equals, .contains: return (day, next)
            }
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

    // MARK: In-memory matching

    func matches(_ ctx: QueryMatchContext) -> Bool {
        let result = positiveMatch(ctx)
        return negated ? !result : result
    }

    private func positiveMatch(_ ctx: QueryMatchContext) -> Bool {
        let t = ctx.track
        guard let field else {
            let needle = TextFolding.fold(value)
            return t.searchFolded.contains(needle) || ctx.labels.contains { TextFolding.fold($0).contains(needle) }
        }
        switch field.kind {
        case .text:
            let haystacks: [String]
            switch field {
            case .title: haystacks = [t.title]
            case .artist: haystacks = [t.artist]
            case .album: haystacks = [t.album]
            case .albumartist: haystacks = [t.albumArtist.isEmpty ? t.artist : t.albumArtist]
            case .genre: haystacks = [t.genre]
            case .composer: haystacks = [t.composer]
            case .comment: haystacks = [t.comment]
            case .filename: haystacks = [t.path]
            case .format: haystacks = [t.format]
            case .label: haystacks = ctx.labels
            case .lyrics: haystacks = [ctx.lyrics ?? ""]
            default: haystacks = []
            }
            let needle = TextFolding.fold(value)
            switch op {
            case .contains: return value.isEmpty || haystacks.contains { TextFolding.fold($0).contains(needle) }
            case .equals:
                if value.isEmpty { return haystacks.allSatisfy(\.isEmpty) }
                return haystacks.contains { TextFolding.fold($0) == needle }
            case .greater: return haystacks.contains { TextFolding.fold($0) > needle }
            case .less: return haystacks.contains { TextFolding.fold($0) < needle }
            }
        case .number:
            let s = ctx.statistics
            let actual: Double
            switch field {
            case .year: actual = Double(t.year)
            case .tracknumber: actual = Double(t.trackNumber)
            case .discnumber: actual = Double(t.discNumber)
            case .bpm: actual = Double(t.bpm)
            case .length: actual = Double(t.durationMs / 1000)
            case .bitrate: actual = Double(t.bitrate)
            case .samplerate: actual = Double(t.sampleRate)
            case .filesize: actual = Double(t.fileSize)
            case .score: actual = s?.score ?? 0
            case .playcount: actual = Double(s?.playCount ?? 0)
            case .rating: actual = Double(s?.rating ?? 0)
            default: actual = 0
            }
            if op == .equals && value.isEmpty { return actual == 0 }
            guard let n = numericValue(field) else { return false }
            switch op {
            case .greater: return actual > n
            case .less: return actual < n
            case .equals, .contains:
                if field == .filesize { return abs(actual - n) <= 512 * 1024 }
                return actual == n
            }
        case .date:
            let actual: Date?
            switch field {
            case .added: actual = t.dateAdded
            case .modified: actual = t.mtime
            case .firstplay: actual = ctx.statistics?.firstPlayed
            case .lastplay: actual = ctx.statistics?.lastPlayed
            default: actual = nil
            }
            if op == .equals && value.isEmpty { return actual == nil }
            guard let actual, let range = dateRange(now: ctx.now) else { return false }
            if let lower = range.lower, actual < lower { return false }
            if let upper = range.upper, actual >= upper { return false }
            return true
        }
    }
}
