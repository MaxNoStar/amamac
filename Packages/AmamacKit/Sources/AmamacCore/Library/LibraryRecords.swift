import Foundation
import GRDB

extension LyricsRecord {
    /// Stores lyrics read from a file's tag, unless the user saved their own for the track.
    static func storeFromTag(_ text: String, trackId: Int64, in db: Database) throws {
        let stored = try LyricsRecord.fetchOne(db, key: trackId)
        if stored == nil || stored?.source == "tag" {
            try LyricsRecord(trackId: trackId, text: text, synced: LRCParser.looksSynced(text), source: "tag").save(db)
        }
    }
}

extension Array where Element == CollectionFolder {
    /// The innermost collection folder that contains `path`.
    func folderId(containing path: String) -> Int64? {
        filter { path.hasPrefix($0.path) }.max { $0.path.count < $1.path.count }?.id
    }
}
