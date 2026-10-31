import AmamacBase
import AmamacDatabase
import AmamacModels
import Foundation
import GRDB

/// Imports ratings, play counts and play dates from a Music app library export
/// (File › Library › Export Library…, an XML property list).
public enum AppleMusicImporter {
    public struct Entry: Sendable, Equatable {
        public var path: String?
        public var title: String
        public var artist: String
        public var album: String
        public var playCount: Int
        /// 0...100 in the export; converted to 0...10.
        public var rating: Int
        public var lastPlayed: Date?
        public var dateAdded: Date?
    }

    public struct Report: Sendable, Equatable {
        public var entries = 0
        public var matched = 0
        public var updated = 0
        public var unmatched = 0
    }

    public static func parse(_ url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: [String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return tracks.values.compactMap { t in
            guard t["Kind"] as? String != "Internet audio stream" else { return nil }
            let location = (t["Location"] as? String).flatMap(URL.init(string:))
            let ratingComputed = t["Rating Computed"] as? Bool ?? false
            return Entry(path: location?.isFileURL == true ? location?.standardizedFileURL.path : nil,
                         title: t["Name"] as? String ?? "", artist: t["Artist"] as? String ?? "",
                         album: t["Album"] as? String ?? "", playCount: t["Play Count"] as? Int ?? 0,
                         rating: ratingComputed ? 0 : (t["Rating"] as? Int ?? 0) / 10,
                         lastPlayed: t["Play Date UTC"] as? Date, dateAdded: t["Date Added"] as? Date)
        }
    }

    /// Matches by file path, then by artist + title + album. Play counts and dates only ever grow;
    /// ratings are taken where the collection has none (or always with `overwriteRatings`).
    public static func apply(_ entries: [Entry], to database: LibraryDatabase, overwriteRatings: Bool = false) async throws -> Report {
        try await database.writer.write { db in
            var report = Report(entries: entries.count)
            var byPath: [String: Int64] = [:]
            var byTags: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, path, title, artist, album FROM track") {
                let id: Int64 = row["id"]
                byPath[row["path"]] = id
                byTags[key(row["artist"], row["title"], row["album"])] = id
            }
            for entry in entries {
                guard let id = entry.path.flatMap({ byPath[$0] }) ?? byTags[key(entry.artist, entry.title, entry.album)] else {
                    report.unmatched += 1
                    continue
                }
                report.matched += 1
                var stats = try TrackStatistics.fetchOne(db, key: id) ?? TrackStatistics(trackId: id)
                let before = stats
                if entry.rating > 0 && (stats.rating == 0 || overwriteRatings) { stats.rating = min(10, entry.rating) }
                if entry.playCount > stats.playCount { stats.playCount = entry.playCount }
                if let last = entry.lastPlayed, last > (stats.lastPlayed ?? .distantPast) { stats.lastPlayed = last }
                if stats.firstPlayed == nil, stats.playCount > 0 { stats.firstPlayed = entry.dateAdded ?? stats.lastPlayed }
                if stats != before {
                    try stats.save(db)
                    report.updated += 1
                }
            }
            return report
        }
    }

    static func key(_ artist: String, _ title: String, _ album: String) -> String {
        [artist, title, album].map(TextFolding.fold).joined(separator: "\u{1F}")
    }
}
