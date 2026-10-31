import Foundation
import GRDB

/// A dynamic playlist rule (Amarok's "biases"). Biases form a tree; each node narrows which
/// collection tracks may come next.
public indirect enum Bias: Codable, Sendable, Equatable, Hashable {
    /// Any track.
    case random
    /// Tracks matching every child.
    case and([Bias])
    /// Tracks matching any child.
    case or([Bias])
    /// Tracks not matching the child.
    case not(Bias)
    /// Children chosen in proportion to their weights.
    case partition([WeightedBias])
    /// The first child that matches any track.
    case ifElse([Bias])
    /// Tracks matching a collection filter (same syntax as the collection search).
    case search(String)
    /// Keeps albums together, relative to the previous track.
    case albumPlay(AlbumPlayMode)
    /// The first letter of a field must equal the last letter of the previous track's field.
    case quizPlay(QuizField)

    public enum AlbumPlayMode: String, Codable, Sendable, CaseIterable, Hashable {
        case directlyFollows, follows, sameAlbum
        public var displayName: String {
            switch self {
            case .directlyFollows: "Track directly follows the previous track in the album"
            case .follows: "Track comes after the previous track in the album"
            case .sameAlbum: "Track is from the same album as the previous track"
            }
        }

        public var shortName: String {
            switch self {
            case .directlyFollows: "next track"
            case .follows: "a later track"
            case .sameAlbum: "same album"
            }
        }
    }

    public enum QuizField: String, Codable, Sendable, CaseIterable, Hashable {
        case title, artist, album
    }

    public struct WeightedBias: Codable, Sendable, Equatable, Hashable {
        public var weight: Double
        public var bias: Bias
        public init(weight: Double, bias: Bias) {
            self.weight = weight
            self.bias = bias
        }
    }

    public var displayName: String {
        switch self {
        case .random: "Random"
        case .and: "Match all"
        case .or: "Match any"
        case .not: "Not"
        case .partition: "Partition"
        case .ifElse: "If / Else"
        case .search(let q): "Search: \(q)"
        case .albumPlay(let mode): "Album play (\(mode.rawValue))"
        case .quizPlay(let field): "Quiz play (\(field.rawValue))"
        }
    }

    /// One line describing the whole tree, e.g. `“genre:rock” or “genre:pop”`.
    public var summary: String {
        switch self {
        case .random: return "Random"
        case .and(let c): return c.isEmpty ? "Any track" : c.map(\.nestedSummary).joined(separator: " and ")
        case .or(let c): return c.isEmpty ? "Any track" : c.map(\.nestedSummary).joined(separator: " or ")
        case .not(let b): return "not " + b.nestedSummary
        case .partition(let parts):
            let total = parts.reduce(0) { $0 + max(0, $1.weight) }
            return parts.map { "\(total > 0 ? Int((max(0, $0.weight) / total * 100).rounded()) : 0)% \($0.bias.nestedSummary)" }
                .joined(separator: " + ")
        case .ifElse(let c): return c.map(\.nestedSummary).joined(separator: ", else ")
        case .search(let q): return q.isEmpty ? "Any track" : "“\(q)”"
        case .albumPlay(let mode): return "Album play: \(mode.shortName)"
        case .quizPlay(let field): return "Quiz play on \(field.rawValue)"
        }
    }

    private var nestedSummary: String {
        switch self {
        case .and, .or, .partition, .ifElse: "(\(summary))"
        default: summary
        }
    }

    public var children: [Bias] {
        switch self {
        case .and(let c), .or(let c), .ifElse(let c): c
        case .not(let b): [b]
        case .partition(let parts): parts.map(\.bias)
        default: []
        }
    }

    /// Every search query in the tree (evaluated up front with SQL).
    public var searchQueries: Set<String> {
        if case .search(let q) = self { return [q] }
        return children.reduce(into: Set<String>()) { $0.formUnion($1.searchQueries) }
    }
}

/// What the generator needs to know about a collection track.
public struct TrackFacts: Sendable, Hashable {
    public var id: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var albumKey: String
    public var discNumber: Int
    public var trackNumber: Int
    public var durationMs: Int
    public var fileSize: Int64

    public init(id: Int64, title: String, artist: String, album: String, albumKey: String, discNumber: Int, trackNumber: Int,
                durationMs: Int, fileSize: Int64) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.durationMs = durationMs
        self.fileSize = fileSize
    }

    var albumOrder: Int { discNumber * 1000 + trackNumber }
}

/// The collection as seen by dynamic playlists and the playlist generator.
public struct TrackUniverse: Sendable {
    public var tracks: [TrackFacts]
    public var byId: [Int64: TrackFacts]
    /// Matching ids for each filter query.
    public var searches: [String: Set<Int64>]

    public init(tracks: [TrackFacts], searches: [String: Set<Int64>]) {
        self.tracks = tracks
        byId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.searches = searches
    }

    public static func load(_ database: LibraryDatabase, queries: Set<String>, now: Date = Date()) async throws -> TrackUniverse {
        try await database.writer.read { db in
            let tracks = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, album, albumKey, discNumber, trackNumber, durationMs, fileSize FROM track
                """).map { row in
                TrackFacts(id: row["id"], title: row["title"], artist: row["artist"], album: row["album"], albumKey: row["albumKey"],
                           discNumber: row["discNumber"], trackNumber: row["trackNumber"], durationMs: row["durationMs"],
                           fileSize: row["fileSize"])
            }
            var searches: [String: Set<Int64>] = [:]
            for query in queries {
                let filter = CollectionQuery.parse(query)
                searches[query] = Set(try CollectionQueries.tracks(db, constraints: [], filter: filter, now: now).compactMap(\.track.id))
            }
            return TrackUniverse(tracks: tracks, searches: searches)
        }
    }
}

/// Picks the next tracks for dynamic mode.
public struct DynamicGenerator {
    public let bias: Bias
    public let universe: TrackUniverse

    public init(bias: Bias, universe: TrackUniverse) {
        self.bias = bias
        self.universe = universe
    }

    /// Candidate ids for `bias` given the previous track; nil means "any track".
    func candidates(_ bias: Bias, previous: TrackFacts?, rng: inout some RandomNumberGenerator) -> Set<Int64>? {
        switch bias {
        case .random:
            return nil
        case .search(let q):
            return universe.searches[q] ?? []
        case .and(let children):
            var result: Set<Int64>?
            for child in children {
                guard let set = candidates(child, previous: previous, rng: &rng) else { continue }
                result = result.map { $0.intersection(set) } ?? set
            }
            return result
        case .or(let children):
            var result = Set<Int64>()
            for child in children {
                guard let set = candidates(child, previous: previous, rng: &rng) else { return nil }
                result.formUnion(set)
            }
            return result
        case .not(let child):
            guard let set = candidates(child, previous: previous, rng: &rng) else { return [] }
            return Set(universe.tracks.map(\.id)).subtracting(set)
        case .partition(let parts):
            let total = parts.reduce(0) { $0 + max(0, $1.weight) }
            guard total > 0 else { return nil }
            var pick = Double.random(in: 0..<total, using: &rng)
            for part in parts {
                pick -= max(0, part.weight)
                if pick < 0 { return candidates(part.bias, previous: previous, rng: &rng) }
            }
            return candidates(parts[parts.count - 1].bias, previous: previous, rng: &rng)
        case .ifElse(let children):
            for child in children {
                let set = candidates(child, previous: previous, rng: &rng)
                if set == nil || !(set!.isEmpty) { return set }
            }
            return []
        case .albumPlay(let mode):
            guard let previous, !previous.album.isEmpty else {
                // Start albums at their first track.
                let firsts = Dictionary(grouping: universe.tracks.filter { !$0.album.isEmpty }, by: \.albumKey)
                    .compactMap { $0.value.min { $0.albumOrder < $1.albumOrder }?.id }
                return Set(firsts)
            }
            let album = universe.tracks.filter { $0.albumKey == previous.albumKey && $0.id != previous.id }
            switch mode {
            case .sameAlbum:
                return Set(album.map(\.id))
            case .follows:
                return Set(album.filter { $0.albumOrder > previous.albumOrder }.map(\.id))
            case .directlyFollows:
                let next = album.filter { $0.albumOrder > previous.albumOrder }.min { $0.albumOrder < $1.albumOrder }
                return next.map { [$0.id] } ?? []
            }
        case .quizPlay(let field):
            guard let previous else { return nil }
            func value(_ t: TrackFacts) -> String {
                TextFolding.fold(field == .title ? t.title : (field == .artist ? t.artist : t.album)).filter(\.isLetter)
            }
            guard let last = value(previous).last else { return nil }
            return Set(universe.tracks.filter { $0.id != previous.id && value($0).first == last }.map(\.id))
        }
    }

    /// The next track after `history` (most recent last). Tracks in `exclude` are skipped; when
    /// nothing satisfies the bias, any track is used (as Amarok does).
    public func next(after history: [Int64], exclude: Set<Int64>, rng: inout some RandomNumberGenerator) -> Int64? {
        let previous = history.last.flatMap { universe.byId[$0] }
        let allowed = candidates(bias, previous: previous, rng: &rng)
        if let allowed {
            let pool = allowed.subtracting(exclude)
            if !pool.isEmpty { return pool.randomElement(using: &rng) }
        }
        let fallback = universe.tracks.lazy.map(\.id).filter { !exclude.contains($0) }
        let array = Array(fallback)
        return array.randomElement(using: &rng)
    }

    /// `count` tracks following `history`. Without `allowDuplicates`, tracks already in
    /// `history` or `existing` are not chosen again (unless the collection runs out).
    public func generate(count: Int, history: [Int64], existing: Set<Int64>, allowDuplicates: Bool,
                         rng: inout some RandomNumberGenerator) -> [Int64] {
        var result: [Int64] = []
        var context = history
        var used = allowDuplicates ? Set<Int64>() : existing.union(history)
        for _ in 0..<count {
            var pick = next(after: context, exclude: used, rng: &rng)
            if pick == nil && !used.isEmpty { pick = next(after: context, exclude: [], rng: &rng) }
            guard let id = pick else { break }
            result.append(id)
            context.append(id)
            if !allowDuplicates { used.insert(id) }
        }
        return result
    }
}

/// A named dynamic playlist definition.
public struct DynamicPlaylist: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var name: String
    public var bias: Bias

    public init(id: Int64? = nil, name: String, bias: Bias) {
        self.id = id
        self.name = name
        self.bias = bias
    }

    public static let presets: [DynamicPlaylist] = [
        DynamicPlaylist(name: "Random", bias: .random),
        DynamicPlaylist(name: "Rock and Pop", bias: .or([.search("genre:rock"), .search("genre:pop")])),
        DynamicPlaylist(name: "Album Play", bias: .albumPlay(.directlyFollows)),
        DynamicPlaylist(name: "Highly Rated", bias: .partition([.init(weight: 2, bias: .search("rating:>3")), .init(weight: 1, bias: .random)])),
        DynamicPlaylist(name: "Quiz Play", bias: .quizPlay(.artist)),
        DynamicPlaylist(name: "Never Played", bias: .ifElse([.search("playcount:0"), .random])),
    ]
}

/// Dynamic playlists and generator presets stored in the database (presets seeded on first use).
public struct GeneratorStore: Sendable {
    let database: LibraryDatabase
    public init(database: LibraryDatabase) { self.database = database }

    public func dynamicPlaylists() -> [DynamicPlaylist] {
        let rows = (try? database.writer.read { try Row.fetchAll($0, sql: "SELECT id, name, definition FROM dynamic_playlist ORDER BY id") }) ?? []
        if rows.isEmpty {
            for preset in DynamicPlaylist.presets { _ = save(preset) }
            return dynamicPlaylists()
        }
        return rows.compactMap { row in
            guard let json: String = row["definition"], let bias = try? JSONDecoder().decode(Bias.self, from: Data(json.utf8)) else { return nil }
            return DynamicPlaylist(id: row["id"], name: row["name"], bias: bias)
        }
    }

    @discardableResult
    public func save(_ playlist: DynamicPlaylist) -> DynamicPlaylist {
        var saved = playlist
        let json = String(decoding: (try? JSONEncoder().encode(playlist.bias)) ?? Data("\"random\"".utf8), as: UTF8.self)
        try? database.writer.write { db in
            if let id = playlist.id {
                try db.execute(sql: "UPDATE dynamic_playlist SET name = ?, definition = ? WHERE id = ?", arguments: [playlist.name, json, id])
            } else {
                try db.execute(sql: "INSERT INTO dynamic_playlist (name, definition) VALUES (?, ?)", arguments: [playlist.name, json])
                saved.id = db.lastInsertedRowID
            }
        }
        return saved
    }

    public func deleteDynamicPlaylist(id: Int64) {
        try? database.writer.write { try $0.execute(sql: "DELETE FROM dynamic_playlist WHERE id = ?", arguments: [id]) }
    }

    public func generatorPresets() -> [GeneratorPreset] {
        let rows = (try? database.writer.read { try Row.fetchAll($0, sql: "SELECT id, name, definition FROM apg_preset ORDER BY id") }) ?? []
        if rows.isEmpty {
            for preset in GeneratorPreset.presets { _ = save(preset) }
            return generatorPresets()
        }
        return rows.compactMap { row in
            guard let json: String = row["definition"],
                  let root = try? JSONDecoder().decode(GeneratorConstraint.self, from: Data(json.utf8)) else { return nil }
            return GeneratorPreset(id: row["id"], name: row["name"], root: root)
        }
    }

    @discardableResult
    public func save(_ preset: GeneratorPreset) -> GeneratorPreset {
        var saved = preset
        let json = String(decoding: (try? JSONEncoder().encode(preset.root)) ?? Data(), as: UTF8.self)
        try? database.writer.write { db in
            if let id = preset.id {
                try db.execute(sql: "UPDATE apg_preset SET name = ?, definition = ? WHERE id = ?", arguments: [preset.name, json, id])
            } else {
                try db.execute(sql: "INSERT INTO apg_preset (name, definition) VALUES (?, ?)", arguments: [preset.name, json])
                saved.id = db.lastInsertedRowID
            }
        }
        return saved
    }

    public func deleteGeneratorPreset(id: Int64) {
        try? database.writer.write { try $0.execute(sql: "DELETE FROM apg_preset WHERE id = ?", arguments: [id]) }
    }
}
