import Foundation

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
