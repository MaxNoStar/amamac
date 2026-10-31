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
            track.folderId = roots.folderId(containing: path)
            let lyrics = tags.lyrics
            let fresh = track
            try await database.writer.write { db in
                guard let existing = try Track.fetchOne(db, sql: "SELECT * FROM track WHERE path = ?", arguments: [path]) else { return }
                var track = fresh
                track.id = existing.id
                track.dateAdded = existing.dateAdded
                try track.update(db)
                if let lyrics, let id = track.id {
                    try LyricsRecord.storeFromTag(lyrics, trackId: id, in: db)
                }
            }
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        try await applyCompilationHeuristic(directories: directories)
    }

    /// Points a track at its new location after the file was moved (Organize Files).
    public nonisolated func relocate(trackId: Int64, to newPath: String) async throws {
        let roots = try await database.writer.read { try CollectionFolder.fetchAll($0) }
        let folderId = roots.folderId(containing: newPath)
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
