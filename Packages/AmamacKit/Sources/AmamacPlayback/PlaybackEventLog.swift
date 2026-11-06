import Foundation
import Synchronization
import os

/// The last 100 things that happened in playback (tracks starting and joining, early ends, failed
/// tracks, recoveries, output changes), oldest first, for Help › Diagnostics. Each entry also goes
/// to the unified log (subsystem `local.amamac`, category `engine`).
public final class PlaybackEventLog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let time: Date
        public let message: String
    }

    public static let capacity = 100
    private let entries = Mutex<[Entry]>([])
    private let log = Logger(subsystem: "local.amamac", category: "engine")

    public init() {}

    public func add(_ message: String, at time: Date = Date()) {
        log.notice("\(message, privacy: .private)")
        entries.withLock { entries in
            entries.append(Entry(time: time, message: message))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    public var all: [Entry] { entries.withLock { $0 } }

    /// One "HH:mm:ss.SSS message" line per entry.
    public func report() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return all.map { "\(formatter.string(from: $0.time)) \($0.message)" }.joined(separator: "\n")
    }
}
