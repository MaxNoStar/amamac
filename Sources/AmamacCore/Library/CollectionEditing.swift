import Foundation
import GRDB

extension CollectionScanner {
    /// Re-reads the given files and updates their rows in place (id, date added and statistics
    /// are kept). Used after tag edits, so the change shows without waiting for a scan.
    @concurrent
    public nonisolated func refresh(paths: [String]) async throws {
        let roots = try await database.writer.read { try CollectionFolder.fetchAll($0) }
        var directories = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let tags = try? TagReader.read(url: url) else { continue }
            var track = tags.track
            let size = Int64(values.fileSize ?? 0)
            track.path = path
            track.fileSize = size
            track.mtime = values.contentModificationDate ?? Date()
            track.uniqueId = Self.uniqueId(for: url, size: size)
            track.folderId = roots.filter { path.hasPrefix($0.path) }.max { $0.path.count < $1.path.count }?.id
            let lyrics = tags.lyrics
            let fresh = track
            try await database.writer.write { db in
                guard let existing = try Track.fetchOne(db, sql: "SELECT * FROM track WHERE path = ?", arguments: [path]) else { return }
                var track = fresh
                track.id = existing.id
                track.dateAdded = existing.dateAdded
                try track.update(db)
                if let lyrics, let id = track.id {
                    let stored = try LyricsRecord.fetchOne(db, key: id)
                    if stored == nil || stored?.source == "tag" {
                        try LyricsRecord(trackId: id, text: lyrics, synced: LRCParser.looksSynced(lyrics), source: "tag").save(db)
                    }
                }
            }
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        try await applyCompilationHeuristic(directories: directories)
    }

    /// Points a track at its new location after the file was moved (Organize Files).
    public nonisolated func relocate(trackId: Int64, to newPath: String) async throws {
        let roots = try await database.writer.read { try CollectionFolder.fetchAll($0) }
        let folderId = roots.filter { newPath.hasPrefix($0.path) }.max { $0.path.count < $1.path.count }?.id
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE track SET path = ?, folderId = ? WHERE id = ?", arguments: [newPath, folderId, trackId])
        }
    }

    /// Removes tracks from the database (after their files were trashed or deleted).
    public nonisolated func forget(trackIds: [Int64]) async throws {
        guard !trackIds.isEmpty else { return }
        try await database.writer.write { db in
            for id in trackIds { _ = try Track.deleteOne(db, key: id) }
        }
    }
}

/// Writes tag changes to files and brings the collection up to date.
public enum TrackEditor {
    public struct Edit: Sendable {
        public var path: String
        public var changes: TagChanges
        public init(path: String, changes: TagChanges) {
            self.path = path
            self.changes = changes
        }
    }

    /// Returns the files that could not be written, with the reason.
    @concurrent
    public static func apply(_ edits: [Edit], scanner: CollectionScanner) async -> [String: String] {
        var failures: [String: String] = [:]
        var written: [String] = []
        for edit in edits where !edit.changes.isEmpty {
            do {
                try TagWriter.write(edit.changes, to: URL(fileURLWithPath: edit.path))
                written.append(edit.path)
            } catch {
                failures[edit.path] = error.localizedDescription
            }
        }
        try? await scanner.refresh(paths: written)
        return failures
    }
}

/// Organize Files: computes destinations from a naming pattern and moves the files.
public enum Organizer {
    public struct Move: Sendable, Equatable, Identifiable {
        public var trackId: Int64?
        public var source: String
        public var destination: String
        public var id: String { source }
        /// The destination exists already (moved only with "overwrite").
        public var conflict: Bool
        public var unchanged: Bool { source == destination }
    }

    public static func plan(_ tracks: [Track], root: String, pattern: FileNamingPattern, options: OrganizeOptions) -> [Move] {
        var claimed = Set<String>()
        return tracks.map { track in
            let destination = pattern.destination(for: track, collectionRoot: root, options: options)
            let exists = destination != track.path && (FileManager.default.fileExists(atPath: destination) || claimed.contains(destination))
            claimed.insert(destination)
            return Move(trackId: track.id, source: track.path, destination: destination, conflict: exists)
        }
    }

    public struct Result: Sendable {
        public var moved: [Move] = []
        public var failures: [String: String] = [:]
    }

    /// Moves files, updating the collection. Emptied source folders are removed.
    @concurrent
    public static func execute(_ moves: [Move], overwrite: Bool, scanner: CollectionScanner) async -> Result {
        var result = Result()
        let fm = FileManager.default
        var emptied = Set<String>()
        for move in moves where !move.unchanged {
            do {
                if move.conflict {
                    guard overwrite else {
                        result.failures[move.source] = "A file already exists at the destination."
                        continue
                    }
                    try? fm.trashItem(at: URL(fileURLWithPath: move.destination), resultingItemURL: nil)
                }
                try fm.createDirectory(atPath: (move.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: move.source, toPath: move.destination)
                if let id = move.trackId { try await scanner.relocate(trackId: id, to: move.destination) }
                result.moved.append(move)
                emptied.insert((move.source as NSString).deletingLastPathComponent)
            } catch {
                result.failures[move.source] = error.localizedDescription
            }
        }
        for dir in emptied.sorted(by: { $0.count > $1.count }) { removeIfEmpty(dir) }
        return result
    }

    /// Removes `dir` and empty parents, ignoring .DS_Store.
    static func removeIfEmpty(_ dir: String) {
        let fm = FileManager.default
        var current = dir
        for _ in 0..<3 {
            guard let contents = try? fm.contentsOfDirectory(atPath: current),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? fm.removeItem(atPath: current)
            current = (current as NSString).deletingLastPathComponent
        }
    }
}

/// Guesses tags from a file path using a pattern such as `%artist%/%album%/%track% - %title%`.
public enum FilenameTagGuesser {
    public static let presets = [
        "%track% - %title%",
        "%track% - %artist% - %title%",
        "%artist% - %title%",
        "%artist%/%album%/%track% - %title%",
        "%albumartist%/%album% (%year%)/%track% - %title%",
        "%track%. %title%",
    ]

    static let numeric: Set<String> = ["track", "discnumber", "year"]
    static let known: Set<String> = ["title", "artist", "albumartist", "album", "genre", "composer", "comment", "track", "discnumber", "year"]

    /// Field name → value for the fields in `pattern`, or nil when the path does not match.
    public static func guess(path: String, pattern: String) -> [String: String]? {
        var regex = ""
        var fields: [String] = []
        var rest = Substring(pattern)
        while let start = rest.firstIndex(of: "%") {
            regex += NSRegularExpression.escapedPattern(for: String(rest[..<start]))
            let after = rest[rest.index(after: start)...]
            guard let end = after.firstIndex(of: "%") else { return nil }
            let name = String(after[..<end]).lowercased()
            guard known.contains(name) else { return nil }
            fields.append(name)
            regex += numeric.contains(name) ? "(\\d+)" : "([^/]+?)"
            rest = after[after.index(after: end)...]
        }
        regex += NSRegularExpression.escapedPattern(for: String(rest))
        let components = pattern.split(separator: "/").count
        let tail = path.split(separator: "/").suffix(components).joined(separator: "/")
        let stem = (tail as NSString).deletingPathExtension
        guard let re = try? NSRegularExpression(pattern: "^" + regex + "$"),
              let match = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { return nil }
        var result: [String: String] = [:]
        for (i, name) in fields.enumerated() {
            guard let range = Range(match.range(at: i + 1), in: stem) else { continue }
            var value = String(stem[range]).trimmingCharacters(in: .whitespaces)
            if numeric.contains(name) { value = String(Int(value) ?? 0) }
            result[name] = value
        }
        return result
    }
}

/// Writes rating and play count into files (FMPS tags) when the user enabled it.
public enum StatisticsTagWriter {
    @concurrent
    public static func write(rating: Int?, playCount: Int?, to path: String) async {
        var changes = TagChanges()
        changes.rating = rating
        changes.playCount = playCount
        guard !changes.isEmpty else { return }
        try? TagWriter.write(changes, to: URL(fileURLWithPath: path))
    }
}
