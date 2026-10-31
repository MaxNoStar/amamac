import AmamacBase
import AmamacDatabase
import AmamacModels
import Foundation
import GRDB

/// Track position markers and saved views (Amarok's Bookmark Manager).
public struct BookmarkStore: Sendable {
    public static let changed = Notification.Name("amamacBookmarksChanged")
    public let database: LibraryDatabase

    public init(database: LibraryDatabase) { self.database = database }

    public func positions(trackId: Int64) -> [TimeInterval] {
        (try? database.writer.read { db in
            try Double.fetchAll(db, sql: "SELECT position FROM bookmark WHERE kind = 'position' AND trackId = ? ORDER BY position", arguments: [trackId])
        }) ?? []
    }

    public func all() -> [BookmarkRecord] {
        (try? database.writer.read { db in
            try BookmarkRecord.fetchAll(db, sql: "SELECT * FROM bookmark ORDER BY kind, name, position")
        }) ?? []
    }

    @discardableResult
    public func addPosition(trackId: Int64, title: String, position: TimeInterval) -> BookmarkRecord? {
        let name = "\(title) – \(TimeFormatting.duration(position))"
        let url = AmamacLink.position(trackId: trackId, seconds: position).url.absoluteString
        return add(BookmarkRecord(kind: .position, name: name, url: url, trackId: trackId, position: position))
    }

    @discardableResult
    public func add(_ record: BookmarkRecord) -> BookmarkRecord? {
        var record = record
        do {
            try database.writer.write { db in try record.insert(db) }
        } catch { return nil }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return record
    }

    public func rename(id: Int64, to name: String) {
        try? database.writer.write { db in
            try db.execute(sql: "UPDATE bookmark SET name = ? WHERE id = ?", arguments: [name, id])
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func delete(ids: [Int64]) {
        try? database.writer.write { db in
            _ = try BookmarkRecord.deleteAll(db, keys: ids)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

extension BookmarkStore {
    /// Saves a Media Sources view as a bookmark.
    @discardableResult
    public func addView(name: String, link: AmamacLink) -> BookmarkRecord? {
        add(BookmarkRecord(kind: .view, name: name, url: link.url.absoluteString))
    }
}

public struct BookmarkRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookmark"
    public enum Kind: String, Codable, Sendable { case position, view, playlist }
    public var id: Int64?
    public var kind: Kind
    public var name: String
    public var url: String
    public var trackId: Int64?
    public var position: Double?
    public var created: Date

    public init(id: Int64? = nil, kind: Kind, name: String, url: String, trackId: Int64? = nil,
                position: Double? = nil, created: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.trackId = trackId
        self.position = position
        self.created = created
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
