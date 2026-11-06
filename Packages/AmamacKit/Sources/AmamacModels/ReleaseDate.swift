import Foundation

/// A release date at the precision a tag gives it: a year, a month or a day.
///
/// Parses `1998`, `1998-03`, `1998-03-12`, ISO timestamps (`1998-03-12T08:00:00Z`) and slash or dot
/// dates (`12/03/1998`, `12.03.1998`, `1998/03/12`), and prints ISO at its own precision. Slash dates
/// are read day first unless the second number cannot be a month (`03/25/1998`).
public struct ReleaseDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum Precision: Int, Sendable, Comparable {
        case year, month, day

        public static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }
    }

    public let year: Int
    /// 1...12, or nil at year precision.
    public let month: Int?
    /// 1...31, or nil at year or month precision.
    public let day: Int?

    /// A date with the given parts; nil when a part is out of range or a day is given without a month.
    public init?(year: Int, month: Int? = nil, day: Int? = nil) {
        guard (1...9999).contains(year) else { return nil }
        if let month, !(1...12).contains(month) { return nil }
        if let day {
            guard let month, (1...Self.days(inMonth: month, year: year)).contains(day) else { return nil }
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strict parsing, as used for typed input: the whole text must be one of the accepted forms.
    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= 40, let parsed = Self.parseISO(s) ?? Self.parseNumeric(s) else { return nil }
        self = parsed
    }

    /// Lenient parsing for tags written by other software: strict parsing first, then the first
    /// run of exactly four digits as a year ("Spring 1998", "1998 (remaster)").
    public static func lenient(_ text: String?) -> ReleaseDate? {
        guard let text else { return nil }
        if let date = ReleaseDate(text) { return date }
        var run = 0
        var value = 0
        for byte in text.utf8.prefix(200) {
            if byte >= 0x30 && byte <= 0x39 {
                run += 1
                value = run <= 4 ? value * 10 + Int(byte - 0x30) : value
            } else {
                if run == 4, let date = ReleaseDate(year: value) { return date }
                run = 0
                value = 0
            }
        }
        return run == 4 ? ReleaseDate(year: value) : nil
    }

    public var precision: Precision {
        day != nil ? .day : month != nil ? .month : .year
    }

    /// `1998`, `1998-03` or `1998-03-12`.
    public var isoString: String {
        var s = Self.pad(year, 4)
        if let month { s += "-" + Self.pad(month, 2) }
        if let day { s += "-" + Self.pad(day, 2) }
        return s
    }

    public var description: String { isoString }

    /// Earlier dates first; a year sorts before any month or day within it.
    public static func < (a: ReleaseDate, b: ReleaseDate) -> Bool {
        (a.year, a.month ?? 0, a.day ?? 0) < (b.year, b.month ?? 0, b.day ?? 0)
    }

    /// Amamac 0.1.6 and earlier wrote year-only dates to ID3 tags as this timestamp.
    static func isLegacyYearStamp(month: Int, day: Int, time: Substring) -> Bool {
        month == 7 && day == 1 && time == "12:00:00Z"
    }

    // MARK: Parsing

    private static func parseISO(_ s: String) -> ReleaseDate? {
        var datePart = Substring(s)
        var time: Substring?
        if let t = s.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) {
            datePart = s[..<t]
            time = s[s.index(after: t)...]
        }
        let fields = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count), fields[0].count == 4,
              fields.dropFirst().allSatisfy({ (1...2).contains($0.count) }),
              let numbers = numbers(fields) else { return nil }
        if let time {
            guard fields.count == 3, isTime(time) else { return nil }
            if isLegacyYearStamp(month: numbers[1], day: numbers[2], time: time) { return ReleaseDate(year: numbers[0]) }
        }
        return make(year: numbers[0], month: numbers.count > 1 ? numbers[1] : nil, day: numbers.count > 2 ? numbers[2] : nil)
    }

    /// `12/03/1998`, `12.03.1998`, `03/1998`, `1998/03/12`.
    private static func parseNumeric(_ s: String) -> ReleaseDate? {
        let separator: Character = s.contains("/") ? "/" : "."
        let fields = s.split(separator: separator, omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), fields.allSatisfy({ (1...4).contains($0.count) }),
              let numbers = numbers(fields) else { return nil }
        if fields[0].count == 4 {
            guard fields.dropFirst().allSatisfy({ $0.count <= 2 }) else { return nil }
            return make(year: numbers[0], month: numbers[1], day: numbers.count > 2 ? numbers[2] : nil)
        }
        guard fields.last?.count == 4, fields.dropLast().allSatisfy({ $0.count <= 2 }) else { return nil }
        if numbers.count == 2 { return make(year: numbers[1], month: numbers[0], day: nil) }
        let monthFirst = separator == "/" && numbers[1] > 12 && numbers[0] <= 12
        return make(year: numbers[2], month: monthFirst ? numbers[0] : numbers[1], day: monthFirst ? numbers[1] : numbers[0])
    }

    /// Zero months and days ("1998-00-00") mean the part is unknown.
    private static func make(year: Int, month: Int?, day: Int?) -> ReleaseDate? {
        let month = month == 0 ? nil : month
        let day = month == nil || day == 0 ? nil : day
        return ReleaseDate(year: year, month: month, day: day)
    }

    private static func numbers(_ fields: [Substring]) -> [Int]? {
        var out: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(field) else { return nil }
            out.append(n)
        }
        return out
    }

    /// `HH`, `HH:mm`, `HH:mm:ss` or `HH:mm:ss.fff`, optionally followed by `Z` or an offset.
    private static func isTime(_ time: Substring) -> Bool {
        var body = time
        if body.hasSuffix("Z") || body.hasSuffix("z") {
            body = body.dropLast()
        } else if let sign = body.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let offset = body[body.index(after: sign)...].filter { $0 != ":" }
            guard offset.count == 2 || offset.count == 4, offset.allSatisfy(\.isASCIIDigit) else { return false }
            body = body[..<sign]
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        let limits = [23, 59, 60]
        for (i, part) in parts.enumerated() {
            let whole = i == 2 ? part.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false) : [part]
            guard whole[0].count == 2, whole.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
                  let value = Int(whole[0]), value <= limits[i] else { return false }
        }
        return true
    }

    private static func days(inMonth month: Int, year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
