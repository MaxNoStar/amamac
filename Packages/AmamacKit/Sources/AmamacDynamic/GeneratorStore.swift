import AmamacDatabase
import Foundation
import GRDB

/// Dynamic playlists and generator presets stored in the database (presets seeded on first use).
public struct GeneratorStore: Sendable {
    let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    private var dynamicTable: DefinitionTable<Bias> { DefinitionTable(database: database, table: "dynamic_playlist") }
    private var presetTable: DefinitionTable<GeneratorConstraint> { DefinitionTable(database: database, table: "apg_preset") }

    public func dynamicPlaylists() -> [DynamicPlaylist] {
        guard let entries = dynamicTable.entries() else {
            for preset in DynamicPlaylist.presets { _ = save(preset) }
            return dynamicPlaylists()
        }
        return entries.map { DynamicPlaylist(id: $0.id, name: $0.name, bias: $0.value) }
    }

    @discardableResult
    public func save(_ playlist: DynamicPlaylist) -> DynamicPlaylist {
        var saved = playlist
        saved.id = dynamicTable.save(id: playlist.id, name: playlist.name, value: playlist.bias, fallbackJSON: "\"random\"")
        return saved
    }

    public func deleteDynamicPlaylist(id: Int64) { dynamicTable.delete(id: id) }

    public func generatorPresets() -> [GeneratorPreset] {
        guard let entries = presetTable.entries() else {
            for preset in GeneratorPreset.presets { _ = save(preset) }
            return generatorPresets()
        }
        return entries.map { GeneratorPreset(id: $0.id, name: $0.name, root: $0.value) }
    }

    @discardableResult
    public func save(_ preset: GeneratorPreset) -> GeneratorPreset {
        var saved = preset
        saved.id = presetTable.save(id: preset.id, name: preset.name, value: preset.root, fallbackJSON: "")
        return saved
    }

    public func deleteGeneratorPreset(id: Int64) { presetTable.delete(id: id) }
}

/// A table of named JSON definitions with `id`, `name` and `definition` columns.
private struct DefinitionTable<Value: Codable> {
    let database: LibraryDatabase
    let table: String

    /// Rows that decode, or nil when the table has no rows at all (so callers can seed presets).
    func entries() -> [(id: Int64?, name: String, value: Value)]? {
        let rows = (try? database.writer.read { try Row.fetchAll($0, sql: "SELECT id, name, definition FROM \(table) ORDER BY id") }) ?? []
        if rows.isEmpty { return nil }
        return rows.compactMap { row in
            guard let json: String = row["definition"], let value = try? JSONDecoder().decode(Value.self, from: Data(json.utf8)) else { return nil }
            return (row["id"], row["name"], value)
        }
    }

    /// Inserts or updates a row; returns its id (nil when an insert failed).
    func save(id: Int64?, name: String, value: Value, fallbackJSON: String) -> Int64? {
        let json = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? fallbackJSON
        var savedID = id
        try? database.writer.write { db in
            if let id {
                try db.execute(sql: "UPDATE \(table) SET name = ?, definition = ? WHERE id = ?", arguments: [name, json, id])
            } else {
                try db.execute(sql: "INSERT INTO \(table) (name, definition) VALUES (?, ?)", arguments: [name, json])
                savedID = db.lastInsertedRowID
            }
        }
        return savedID
    }

    func delete(id: Int64) {
        try? database.writer.write { try $0.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id]) }
    }
}
