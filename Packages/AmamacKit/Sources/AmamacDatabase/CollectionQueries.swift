import AmamacBase
import AmamacModels
import AmamacQuery
import Foundation
import GRDB

public enum CollectionQueries {
    struct WhereClause {
        var sql: String
        var arguments: [any DatabaseValueConvertible]
        var needsLabelJoin: Bool
    }

    static func whereClause(filter: CollectionQuery, constraints: [CollectionConstraint], now: Date,
                            extraLevel: CollectionLevel? = nil) -> WhereClause {
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        let filterSQL = filter.sql(now: now)
        if filterSQL != .alwaysTrue {
            parts.append(filterSQL.sql)
            args.append(contentsOf: filterSQL.arguments.map(\.databaseValue))
        }
        for c in constraints {
            if c.level == .label {
                if c.key.isEmpty {
                    parts.append("NOT EXISTS (SELECT 1 FROM track_label x WHERE x.trackId = t.id)")
                } else {
                    parts.append("EXISTS (SELECT 1 FROM track_label x JOIN label xl ON xl.id = x.labelId WHERE x.trackId = t.id AND amamac_fold(xl.name) = ?)")
                    args.append(c.key)
                }
                continue
            }
            parts.append("\(c.level.keyExpression) = ?")
            if c.level == .year { args.append(Int(c.key) ?? 0) } else { args.append(c.key) }
        }
        return WhereClause(sql: parts.isEmpty ? "1" : parts.joined(separator: " AND "), arguments: args,
                           needsLabelJoin: extraLevel == .label)
    }

    /// Child groups at `level` under `constraints`, matching `filter`.
    public static func groups(_ db: Database, level: CollectionLevel, constraints: [CollectionConstraint],
                              filter: CollectionQuery, sortAlbumsByYear: Bool = false, now: Date = Date()) throws -> [CollectionGroup] {
        let w = whereClause(filter: filter, constraints: constraints, now: now, extraLevel: level)
        let join = w.needsLabelJoin ? "LEFT JOIN track_label tl ON tl.trackId = t.id LEFT JOIN label l ON l.id = tl.labelId" : ""
        let sortExpr: String
        switch level {
        case .albumArtist: sortExpr = "MIN(CASE WHEN t.compilation THEN '' ELSE t.albumArtistSort END)"
        case .artist: sortExpr = "MIN(t.artistSort)"
        case .album: sortExpr = sortAlbumsByYear ? "printf('%04d', MAX(t.year)) || MIN(t.albumSort)" : "MIN(t.albumSort)"
        case .year: sortExpr = "MAX(t.year)"
        default: sortExpr = "MIN(\(level.keyExpression))"
        }
        let sql = """
            SELECT \(level.keyExpression) AS k, MIN(\(level.valueExpression)) AS name, COUNT(DISTINCT t.id) AS n,
                   MAX(t.year) AS year, MIN(t.albumKey) AS albumKey,
                   MIN\(CollectionLevel.albumArtist.valueExpression) AS albumArtist,
                   MAX(t.compilation) AS compilation, \(sortExpr) AS sortKey
            FROM track t LEFT JOIN statistics s ON s.trackId = t.id \(join)
            WHERE \(w.sql)
            GROUP BY k
            ORDER BY (CASE WHEN MIN(\(level.valueExpression)) = '' THEN 1 ELSE 0 END), sortKey
            """
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(w.arguments)).map { row in
            let key: String
            if level == .year { key = String(row["k"] as Int? ?? 0) } else { key = row["k"] ?? "" }
            var name: String
            if level == .year {
                let y: Int = row["name"] ?? 0
                name = y > 0 ? String(y) : ""
            } else {
                name = row["name"] ?? ""
            }
            if level == .albumArtist && (row["compilation"] as Bool? ?? false) && key == TextFolding.fold(TrackText.variousArtists) {
                name = TrackText.variousArtists
            }
            return CollectionGroup(level: level, key: key, name: name, trackCount: row["n"],
                                   year: row["year"] ?? 0,
                                   albumKey: level == .album ? row["albumKey"] : nil,
                                   albumArtist: level == .album ? row["albumArtist"] : nil,
                                   isCompilation: row["compilation"] ?? false)
        }
    }

    /// Tracks under `constraints` matching `filter`, in album order.
    public static func tracks(_ db: Database, constraints: [CollectionConstraint], filter: CollectionQuery,
                              limit: Int? = nil, now: Date = Date()) throws -> [TrackWithStatistics] {
        let w = whereClause(filter: filter, constraints: constraints, now: now)
        var sql = """
            SELECT t.*, \(TrackWithStatistics.statisticsColumns)
            FROM track t LEFT JOIN statistics s ON s.trackId = t.id
            WHERE \(w.sql)
            ORDER BY t.albumArtistSort, t.albumSort, t.albumKey, t.discNumber, t.trackNumber, t.titleSort
            """
        if let limit { sql += " LIMIT \(limit)" }
        return try TrackWithStatistics.fetchAll(db, sql: sql, arguments: StatementArguments(w.arguments))
    }

    /// Number of tracks matching `filter`.
    public static func count(_ db: Database, filter: CollectionQuery, now: Date = Date()) throws -> Int {
        let w = whereClause(filter: filter, constraints: [], now: now)
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track t LEFT JOIN statistics s ON s.trackId = t.id WHERE \(w.sql)",
                                arguments: StatementArguments(w.arguments)) ?? 0
    }

    public static func tracks(_ db: Database, ids: [Int64]) throws -> [TrackWithStatistics] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try TrackWithStatistics.fetchAll(db, sql: """
            SELECT t.*, \(TrackWithStatistics.statisticsColumns)
            FROM track t LEFT JOIN statistics s ON s.trackId = t.id WHERE t.id IN (\(placeholders))
            """, arguments: StatementArguments(ids))
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.track.id!, $0) })
        return ids.compactMap { byId[$0] }
    }

    /// Collection tracks for the given file paths, keyed by path (missing paths are absent).
    public static func tracks(_ db: Database, paths: [String]) throws -> [String: TrackWithStatistics] {
        var result: [String: TrackWithStatistics] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 500).map({ Array(paths[$0..<min($0 + 500, paths.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try TrackWithStatistics.fetchAll(db, sql: """
                SELECT t.*, \(TrackWithStatistics.statisticsColumns)
                FROM track t LEFT JOIN statistics s ON s.trackId = t.id WHERE t.path IN (\(placeholders))
                """, arguments: StatementArguments(chunk))
            for row in rows { result[row.track.path] = row }
        }
        return result
    }

    public static func track(_ db: Database, path: String) throws -> TrackWithStatistics? {
        try TrackWithStatistics.fetchOne(db, sql: """
            SELECT t.*, \(TrackWithStatistics.statisticsColumns)
            FROM track t LEFT JOIN statistics s ON s.trackId = t.id WHERE t.path = ?
            """, arguments: [path])
    }

    /// Albums by an artist (Albums applet), newest first.
    public static func albums(_ db: Database, artist: String) throws -> [CollectionGroup] {
        let folded = TextFolding.fold(artist)
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.albumKey AS k, MIN(t.album) AS name, COUNT(*) AS n, MAX(t.year) AS year,
                   MAX(t.compilation) AS compilation,
                   MIN\(CollectionLevel.albumArtist.valueExpression) AS albumArtist
            FROM track t
            WHERE t.artistKey = ? OR t.albumArtistKey = ?
            GROUP BY t.albumKey ORDER BY MAX(t.year) DESC, MIN(t.albumSort)
            """, arguments: [folded, folded])
        return rows.map { row in
            CollectionGroup(level: .album, key: row["k"], name: row["name"] ?? "", trackCount: row["n"],
                            year: row["year"] ?? 0, albumKey: row["k"], albumArtist: row["albumArtist"],
                            isCompilation: row["compilation"] ?? false)
        }
    }

    /// Every album (Cover Manager), by album artist then title.
    public static func allAlbums(_ db: Database) throws -> [CollectionGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.albumKey AS k, MIN(t.album) AS name, COUNT(*) AS n, MAX(t.year) AS year,
                   MAX(t.compilation) AS compilation,
                   MIN\(CollectionLevel.albumArtist.valueExpression) AS albumArtist
            FROM track t WHERE t.album <> ''
            GROUP BY t.albumKey ORDER BY albumArtist COLLATE NOCASE, name COLLATE NOCASE
            """)
        return rows.map { row in
            CollectionGroup(level: .album, key: row["k"], name: row["name"] ?? "", trackCount: row["n"],
                            year: row["year"] ?? 0, albumKey: row["k"], albumArtist: row["albumArtist"],
                            isCompilation: row["compilation"] ?? false)
        }
    }

    /// Recently added albums (Current Track applet when stopped).
    public static func recentlyAddedAlbums(_ db: Database, limit: Int = 5) throws -> [CollectionGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.albumKey AS k, MIN(t.album) AS name, COUNT(*) AS n, MAX(t.year) AS year, MAX(t.dateAdded) AS added,
                   MAX(t.compilation) AS compilation,
                   MIN\(CollectionLevel.albumArtist.valueExpression) AS albumArtist
            FROM track t WHERE t.album <> ''
            GROUP BY t.albumKey ORDER BY added DESC LIMIT ?
            """, arguments: [limit])
        return rows.map { row in
            CollectionGroup(level: .album, key: row["k"], name: row["name"] ?? "", trackCount: row["n"],
                            year: row["year"] ?? 0, albumKey: row["k"], albumArtist: row["albumArtist"],
                            isCompilation: row["compilation"] ?? false)
        }
    }

    public static func labels(_ db: Database, trackId: Int64) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT l.name FROM label l JOIN track_label tl ON tl.labelId = l.id WHERE tl.trackId = ? ORDER BY l.name", arguments: [trackId])
    }

    public static func allLabels(_ db: Database) throws -> [(name: String, count: Int)] {
        try Row.fetchAll(db, sql: "SELECT l.name AS name, COUNT(tl.trackId) AS n FROM label l LEFT JOIN track_label tl ON tl.labelId = l.id GROUP BY l.id ORDER BY l.name")
            .map { ($0["name"], $0["n"]) }
    }

    public static func setLabels(_ db: Database, trackId: Int64, labels: [String]) throws {
        try db.execute(sql: "DELETE FROM track_label WHERE trackId = ?", arguments: [trackId])
        for name in Set(labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) {
            try db.execute(sql: "INSERT OR IGNORE INTO label (name) VALUES (?)", arguments: [name])
            try db.execute(sql: "INSERT OR IGNORE INTO track_label (trackId, labelId) SELECT ?, id FROM label WHERE name = ?",
                           arguments: [trackId, name])
        }
        try db.execute(sql: "DELETE FROM label WHERE id NOT IN (SELECT labelId FROM track_label)")
    }

    public static func statistics(_ db: Database, trackId: Int64) throws -> TrackStatistics? {
        try TrackStatistics.fetchOne(db, key: trackId)
    }

    public static func lyrics(_ db: Database, trackId: Int64) throws -> LyricsRecord? {
        try LyricsRecord.fetchOne(db, key: trackId)
    }

    /// Distinct values for completion in the tag editor.
    public static func distinctValues(_ db: Database, column: String, limit: Int = 2000) throws -> [String] {
        precondition(["artist", "albumArtist", "album", "genre", "composer"].contains(column))
        return try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM track WHERE \(column) <> '' ORDER BY \(column) COLLATE NOCASE LIMIT \(limit)")
    }

    /// Collection-wide totals for the status area.
    public static func totals(_ db: Database) throws -> (tracks: Int, albums: Int, artists: Int, durationMs: Int) {
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COUNT(DISTINCT albumKey) AS a, COUNT(DISTINCT artistKey) AS r, COALESCE(SUM(durationMs), 0) AS d FROM track")!
        return (row["n"], row["a"], row["r"], row["d"])
    }
}
