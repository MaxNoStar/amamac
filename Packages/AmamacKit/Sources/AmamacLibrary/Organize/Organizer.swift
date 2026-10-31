import AmamacModels
import Foundation
import GRDB

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
