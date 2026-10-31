import Foundation
import GRDB

/// Where the Lyrics applet's text comes from, in order: lyrics the user saved, lyrics read from
/// the file's tags, then LRCLIB (fetched once and stored).
public struct LyricsService: Sendable {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var synced: Bool
        public var source: String
        public var instrumental: Bool { source == "lrclib" && text.isEmpty }
    }

    let database: LibraryDatabase
    let lrclib: LRCLIBClient

    public init(database: LibraryDatabase, http: HTTPClient) {
        self.database = database
        lrclib = LRCLIBClient(http: http)
    }

    /// Stored lyrics, or nil when none were saved, tagged or fetched yet.
    public func stored(trackId: Int64) async -> Result? {
        guard let record = try? await database.writer.read({ try CollectionQueries.lyrics($0, trackId: trackId) }) else { return nil }
        return Result(text: record.text, synced: record.synced, source: record.source)
    }

    /// Stored lyrics or, failing that (or when `refetch` is set), LRCLIB's. Returns nil when
    /// nothing was found; LRCLIB results for collection tracks are stored.
    public func lyrics(for track: Track, refetch: Bool = false) async throws -> Result? {
        if !refetch, let id = track.id, let stored = await stored(trackId: id) { return stored }
        guard let found = try await lrclib.lyrics(title: track.title, artist: track.artist, album: track.album,
                                                  duration: track.duration) else { return nil }
        let result = Result(text: found.instrumental ? "" : found.text, synced: found.synced, source: "lrclib")
        if let id = track.id {
            // Never replace what the user typed.
            try? await database.writer.write { db in
                if let existing = try LyricsRecord.fetchOne(db, key: id), existing.source == "user" { return }
                try LyricsRecord(trackId: id, text: result.text, synced: result.synced, source: result.source).save(db)
            }
        }
        return result
    }

    public func save(_ text: String, trackId: Int64) async throws {
        try await database.writer.write { db in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                _ = try LyricsRecord.deleteOne(db, key: trackId)
            } else {
                try LyricsRecord(trackId: trackId, text: trimmed, synced: LRCParser.looksSynced(trimmed), source: "user").save(db)
            }
        }
    }
}
