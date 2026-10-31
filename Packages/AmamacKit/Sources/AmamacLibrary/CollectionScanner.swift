import AmamacBase
import AmamacDatabase
import AmamacModels
import Foundation
import GRDB

public struct ScanProgress: Sendable {
    public var phase: String
    public var done: Int
    public var total: Int
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

public struct ScanResult: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var moved = 0
    public var removed = 0
    public var unchanged = 0
    public var failed: [String] = []
    /// Collection roots that could not be read (unplugged drive, missing permission). Their tracks
    /// are kept.
    public var unreachableRoots: [String] = []
    public var playlistFiles: [String] = []
    /// True when the request was ignored because a scan was already running.
    public var skipped = false

    public var changed: Bool { added + updated + moved + removed > 0 }
}

/// Scans collection folders into the database. Incremental by modification time; tracks under
/// unreachable roots are never removed; moved files keep their id and statistics.
public actor CollectionScanner {
    public let database: LibraryDatabase
    private var isScanning = false

    public init(database: LibraryDatabase) {
        self.database = database
    }

    public static let maxConcurrentReads = 8

    struct FileInfo: Sendable {
        var path: String
        var mtime: Date
        var size: Int64
    }

    struct Existing: Sendable {
        var id: Int64
        var mtime: Date
        var size: Int64
        var uniqueId: String
    }

    /// Scans all configured folders (or only `onlyPaths` sub-directories when given).
    /// Returns an empty result with `skipped` set when another scan is running.
    public nonisolated func scan(full: Bool = false, onlyPaths: [String]? = nil,
                                 progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult {
        guard await beginScan() else {
            var r = ScanResult()
            r.skipped = true
            return r
        }
        do {
            let result = try await performScan(full: full, onlyPaths: onlyPaths, progress: progress)
            await endScan()
            return result
        } catch {
            await endScan()
            throw error
        }
    }

    @concurrent
    nonisolated func performScan(full: Bool, onlyPaths: [String]?,
                                 progress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanResult {

        let folders = try await database.writer.read { db in try CollectionFolder.fetchAll(db) }
        var result = ScanResult()
        var found: [FileInfo] = []
        var reachableRoots: [CollectionFolder] = []

        progress?(ScanProgress(phase: "Searching for files", done: 0, total: 0))
        for folder in folders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: folder.path) else {
                result.unreachableRoots.append(folder.path)
                continue
            }
            reachableRoots.append(folder)
            let roots = onlyPaths?.filter { $0.hasPrefix(folder.path) } ?? [folder.path]
            for root in roots {
                let (audio, playlists) = Self.enumerate(root: root, recursive: folder.recursive)
                found.append(contentsOf: audio)
                result.playlistFiles.append(contentsOf: playlists)
            }
        }

        // Existing tracks below the reachable roots (or the scanned sub-paths).
        let scopes = onlyPaths ?? reachableRoots.map(\.path)
        let existing: [String: Existing] = try await database.writer.read { db in
            var map: [String: Existing] = [:]
            for scope in scopes {
                let prefix = scope.hasSuffix("/") ? scope : scope + "/"
                let rows = try Row.fetchAll(db, sql: "SELECT id, path, mtime, fileSize, uniqueId FROM track WHERE path LIKE ? ESCAPE '\\'",
                                            arguments: [TextFolding.likeEscaped(prefix) + "%"])
                for row in rows {
                    map[row["path"]] = Existing(id: row["id"], mtime: row["mtime"], size: row["fileSize"], uniqueId: row["uniqueId"])
                }
            }
            return map
        }

        let foundPaths = Set(found.map(\.path))
        var toRead: [FileInfo] = []
        for file in found {
            if let e = existing[file.path], !full, abs(e.mtime.timeIntervalSince(file.mtime)) < 0.002, e.size == file.size {
                result.unchanged += 1
            } else {
                toRead.append(file)
            }
        }
        var missing = existing.filter { !foundPaths.contains($0.key) }

        // Read tags concurrently.
        let total = toRead.count
        var reads: [(FileInfo, TagReadResult?, String)] = []
        reads.reserveCapacity(total)
        try await withThrowingTaskGroup(of: (FileInfo, TagReadResult?, String).self) { group in
            var iterator = toRead.makeIterator()
            var inFlight = 0
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    let url = URL(fileURLWithPath: file.path)
                    let tags = try? TagReader.read(url: url)
                    let uid = Self.uniqueId(for: url, size: file.size)
                    return (file, tags, uid)
                }
                return true
            }
            while inFlight < Self.maxConcurrentReads, addNext() { inFlight += 1 }
            var done = 0
            while let r = try await group.next() {
                reads.append(r)
                done += 1
                if done % 25 == 0 || done == total {
                    progress?(ScanProgress(phase: "Reading tags", done: done, total: total))
                }
                if !addNext() { inFlight -= 1 }
            }
        }

        // Match moved files by unique id.
        var missingByUID: [String: (path: String, existing: Existing)] = [:]
        for (path, e) in missing where !e.uniqueId.isEmpty { missingByUID[e.uniqueId] = (path, e) }

        let roots = reachableRoots
        let folderForPath: @Sendable (String) -> Int64? = { path in roots.folderId(containing: path) }

        let now = Date()
        var touchedDirectories = Set<String>()
        let batches = stride(from: 0, to: reads.count, by: 200).map { Array(reads[$0..<min($0 + 200, reads.count)]) }
        for batch in batches {
            let movedLookup = missingByUID
            let batchResult = try await database.writer.write { db -> (ScanResult, [String]) in
                var r = ScanResult()
                var movedPaths: [String] = []
                for (file, tags, uid) in batch {
                    guard let tags else {
                        r.failed.append(file.path)
                        continue
                    }
                    var track = tags.track
                    track.uniqueId = uid
                    track.folderId = folderForPath(file.path)
                    track.mtime = file.mtime
                    track.fileSize = file.size
                    if let e = existing[file.path] {
                        track.id = e.id
                        track.dateAdded = try Date.fetchOne(db, sql: "SELECT dateAdded FROM track WHERE id = ?", arguments: [e.id]) ?? now
                        try track.update(db)
                        r.updated += 1
                    } else if let moved = movedLookup[uid] {
                        track.id = moved.existing.id
                        track.dateAdded = try Date.fetchOne(db, sql: "SELECT dateAdded FROM track WHERE id = ?", arguments: [moved.existing.id]) ?? now
                        try track.update(db)
                        movedPaths.append(moved.path)
                        r.moved += 1
                    } else {
                        track.dateAdded = now
                        try track.insert(db)
                        r.added += 1
                        if tags.rating != nil || tags.playCount != nil, let id = track.id {
                            var stats = TrackStatistics(trackId: id)
                            stats.rating = tags.rating ?? 0
                            stats.playCount = tags.playCount ?? 0
                            try stats.save(db)
                        }
                    }
                    if let lyrics = tags.lyrics, let id = track.id {
                        try LyricsRecord.storeFromTag(lyrics, trackId: id, in: db)
                    }
                }
                return (r, movedPaths)
            }
            result.added += batchResult.0.added
            result.updated += batchResult.0.updated
            result.moved += batchResult.0.moved
            result.failed += batchResult.0.failed
            for path in batchResult.1 {
                missing[path] = nil
                if let uid = existing[path]?.uniqueId { missingByUID[uid] = nil }
            }
            for (file, _, _) in batch { touchedDirectories.insert((file.path as NSString).deletingLastPathComponent) }
        }

        // Remove tracks whose files are gone (only below reachable roots).
        if !missing.isEmpty {
            let ids = Array(missing.values.map(\.id))
            try await database.writer.write { db in
                for chunk in stride(from: 0, to: ids.count, by: 500) {
                    let slice = Array(ids[chunk..<min(chunk + 500, ids.count)])
                    let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                    try db.execute(sql: "DELETE FROM track WHERE id IN (\(placeholders))", arguments: StatementArguments(slice))
                }
            }
            result.removed = missing.count
        }

        if !touchedDirectories.isEmpty {
            try await applyCompilationHeuristic(directories: touchedDirectories)
        }
        progress?(ScanProgress(phase: "Done", done: total, total: total))
        return result
    }

    private func beginScan() -> Bool {
        if isScanning { return false }
        isScanning = true
        return true
    }

    private func endScan() { isScanning = false }
}
