import AmamacBase
import AmamacModels
import Foundation
import GRDB

/// Organize Files: computes destinations from a naming pattern and moves the files. Destinations
/// never leave the collection folder, whatever the tags say.
public enum Organizer {
    public struct Move: Sendable, Equatable, Identifiable {
        public var trackId: Int64?
        public var source: String
        public var destination: String
        public var id: String { source }
        /// The destination exists already (moved only with "overwrite").
        public var conflict: Bool
        /// Why the file won't be moved at all, such as a destination outside the collection folder.
        public var refused: String?
        /// The collection folder the move stays in; emptied folders are removed up to it, never it.
        public var root: String
        public var unchanged: Bool { source == destination }
    }

    public static func plan(_ tracks: [Track], root: String, pattern: FileNamingPattern, options: OrganizeOptions) -> [Move] {
        // Compared without case: most Mac volumes ignore it, so "Song" and "song" are one file.
        var claimed = Set<String>()
        return tracks.map { track in
            let destination = Paths.normalized(pattern.destination(for: track, collectionRoot: root, options: options))
            var move = Move(trackId: track.id, source: track.path, destination: destination, conflict: false, root: root)
            guard staysInside(destination, root: root) else {
                move.refused = "The new location would be outside the collection folder."
                return move
            }
            let key = destination.lowercased()
            let renamesItself = key == track.path.lowercased()
            move.conflict = !renamesItself && (FileManager.default.fileExists(atPath: destination) || claimed.contains(key))
            claimed.insert(key)
            return move
        }
    }

    /// Whether `path` lies below `root`, also after following folders that exist already and might
    /// be symbolic links to somewhere else.
    static func staysInside(_ path: String, root: String) -> Bool {
        guard Paths.isInside(path, folder: root), Paths.normalized(path) != Paths.normalized(root) else { return false }
        var existing = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: existing) { existing = (existing as NSString).deletingLastPathComponent }
        let resolvedRoot = URL(fileURLWithPath: Paths.normalized(root)).resolvingSymlinksInPath().path
        return Paths.isInside(URL(fileURLWithPath: existing).resolvingSymlinksInPath().path, folder: resolvedRoot)
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
        var emptied: [String: String] = [:]
        var movedHere = Set<String>()
        for move in moves where !move.unchanged {
            if let refused = move.refused {
                result.failures[move.source] = refused
                continue
            }
            do {
                if move.conflict {
                    guard overwrite else {
                        result.failures[move.source] = "A file already exists at the destination."
                        continue
                    }
                    // Overwrite replaces files that were there before, never one this run just moved.
                    guard !movedHere.contains(move.destination.lowercased()) else {
                        result.failures[move.source] = "Another track gets the same name."
                        continue
                    }
                    try? fm.trashItem(at: URL(fileURLWithPath: move.destination), resultingItemURL: nil)
                }
                try fm.createDirectory(atPath: (move.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: move.source, toPath: move.destination)
                if let id = move.trackId { try await scanner.relocate(trackId: id, to: move.destination) }
                result.moved.append(move)
                movedHere.insert(move.destination.lowercased())
                emptied[(move.source as NSString).deletingLastPathComponent] = move.root
            } catch {
                result.failures[move.source] = error.localizedDescription
            }
        }
        for (dir, root) in emptied.sorted(by: { $0.key.count > $1.key.count }) { removeIfEmpty(dir, root: root) }
        return result
    }

    /// Removes `dir` and up to two empty parents (ignoring .DS_Store), but never `root` or anything
    /// outside it. `rmdir` only removes empty folders, so files added meanwhile are safe.
    static func removeIfEmpty(_ dir: String, root: String) {
        let fm = FileManager.default
        let root = Paths.normalized(root)
        var current = Paths.normalized(dir)
        for _ in 0..<3 {
            guard current != root, Paths.isInside(current, folder: root),
                  let contents = try? fm.contentsOfDirectory(atPath: current),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            if !contents.isEmpty { try? fm.removeItem(atPath: (current as NSString).appendingPathComponent(".DS_Store")) }
            guard rmdir(current) == 0 else { return }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
