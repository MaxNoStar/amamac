import Foundation

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
