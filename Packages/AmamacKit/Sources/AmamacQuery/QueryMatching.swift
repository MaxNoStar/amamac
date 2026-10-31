import AmamacBase
import AmamacModels
import Foundation

extension CollectionQuery {
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
    /// Converts the user's number into the column's unit.
    package func numericValue(_ field: QueryField) -> Double? {
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

    /// Converts the term into a date range check `(lower, upper)`; either may be nil.
    package func dateRange(now: Date) -> (lower: Date?, upper: Date?)? {
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
