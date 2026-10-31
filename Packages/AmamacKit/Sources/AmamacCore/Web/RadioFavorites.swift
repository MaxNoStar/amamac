import Foundation
import GRDB

public struct RadioStation: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "radio_station"
    public var id: Int64?
    public var stationUUID: String?
    public var name: String
    public var url: String
    public var homepage: String?
    public var favicon: String?
    public var tags: String?
    public var country: String?
    public var codec: String?
    public var bitrate: Int?
    public var added: Date

    public init(_ station: RadioBrowserStation) {
        stationUUID = station.stationuuid.isEmpty ? nil : station.stationuuid
        name = station.name
        url = station.streamURL?.absoluteString ?? station.url
        homepage = station.homepage
        favicon = station.favicon
        tags = station.tags
        country = station.country
        codec = station.hls == 1 ? "HLS" : station.codec
        bitrate = station.bitrate
        added = Date()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct RadioFavorites: Sendable {
    public static let changed = Notification.Name("amamacRadioFavoritesChanged")
    let database: LibraryDatabase

    public init(database: LibraryDatabase) { self.database = database }

    public func all() -> [RadioBrowserStation] {
        let records = (try? database.writer.read { try RadioStation.fetchAll($0, sql: "SELECT * FROM radio_station ORDER BY name COLLATE NOCASE") }) ?? []
        return records.map(RadioBrowserStation.init(record:))
    }

    public func contains(_ station: RadioBrowserStation) -> Bool {
        all().contains { $0.id == station.id || $0.streamURL == station.streamURL }
    }

    public func add(_ station: RadioBrowserStation) {
        guard !contains(station) else { return }
        try? database.writer.write { db in
            var record = RadioStation(station)
            try record.insert(db)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func remove(_ station: RadioBrowserStation) {
        try? database.writer.write { db in
            if !station.stationuuid.isEmpty {
                try db.execute(sql: "DELETE FROM radio_station WHERE stationUUID = ?", arguments: [station.stationuuid])
            }
            if let url = station.streamURL?.absoluteString {
                try db.execute(sql: "DELETE FROM radio_station WHERE url = ?", arguments: [url])
            }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
