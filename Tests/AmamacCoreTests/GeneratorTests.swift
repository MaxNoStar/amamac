import Foundation
import GRDB
import Testing
@testable import AmamacCore

struct GeneratorTests {
    /// 3 albums × 4 tracks of 3 minutes; artist names chosen for quiz play.
    static func universe(searches: [String: Set<Int64>] = [:]) -> TrackUniverse {
        var tracks: [TrackFacts] = []
        let artists = ["Abba", "Anna", "Bob"]
        var id: Int64 = 1
        for (a, artist) in artists.enumerated() {
            for n in 1...4 {
                tracks.append(TrackFacts(id: id, title: "\(artist) song \(n)", artist: artist, album: "Album \(a)", albumKey: "album\(a)",
                                         discNumber: 0, trackNumber: n, durationMs: 180_000, fileSize: 5_000_000))
                id += 1
            }
        }
        return TrackUniverse(tracks: tracks, searches: searches)
    }

    @Test func albumPlayFollowsTheAlbum() {
        var rng = SplitMix64(seed: 1)
        let generator = DynamicGenerator(bias: .albumPlay(.directlyFollows), universe: Self.universe())
        #expect(generator.generate(count: 3, history: [5], existing: [], allowDuplicates: false, rng: &rng) == [6, 7, 8])
        // Without history, albums start at their first track.
        let first = generator.next(after: [], exclude: [], rng: &rng)
        #expect([1, 5, 9].contains(first))
    }

    @Test func quizPlayChainsLetters() {
        var rng = SplitMix64(seed: 2)
        let generator = DynamicGenerator(bias: .quizPlay(.artist), universe: Self.universe())
        // "Abba" ends in "a" → next artist starts with "a" (Abba or Anna).
        for _ in 0..<20 {
            let next = generator.next(after: [1], exclude: [1], rng: &rng)!
            #expect(next <= 8)
        }
    }

    @Test func searchCombinatorsNarrowCandidates() {
        let u = Self.universe(searches: ["a": [1, 2, 3, 4], "b": [3, 4, 5, 6], "none": []])
        var rng = SplitMix64(seed: 3)
        func set(_ bias: Bias) -> Set<Int64>? { DynamicGenerator(bias: bias, universe: u).candidates(bias, previous: nil, rng: &rng) }
        #expect(set(.and([.search("a"), .search("b")])) == [3, 4])
        #expect(set(.or([.search("a"), .search("b")])) == [1, 2, 3, 4, 5, 6])
        #expect(set(.not(.search("a"))) == Set(5...12))
        #expect(set(.ifElse([.search("none"), .search("b")])) == [3, 4, 5, 6])
        #expect(set(.random) == nil)
    }

    @Test func partitionFollowsWeights() {
        let u = Self.universe(searches: ["a": [1], "b": [12]])
        var rng = SplitMix64(seed: 4)
        let generator = DynamicGenerator(bias: .partition([.init(weight: 3, bias: .search("a")), .init(weight: 1, bias: .search("b"))]), universe: u)
        let picks = (0..<400).map { _ in generator.next(after: [], exclude: [], rng: &rng)! }
        let ratio = Double(picks.filter { $0 == 1 }.count) / Double(picks.count)
        #expect(ratio > 0.65 && ratio < 0.85, "ratio \(ratio)")
    }

    @Test func generationAvoidsDuplicatesAndFallsBack() {
        var rng = SplitMix64(seed: 5)
        let u = Self.universe(searches: ["none": []])
        let ids = DynamicGenerator(bias: .random, universe: u).generate(count: 12, history: [], existing: [], allowDuplicates: false, rng: &rng)
        #expect(Set(ids).count == 12)
        // Nothing matches → any track (Amarok's fallback).
        let fallback = DynamicGenerator(bias: .search("none"), universe: u).generate(count: 2, history: [], existing: [], allowDuplicates: false, rng: &rng)
        #expect(fallback.count == 2)
    }

    @Test func generatorMeetsDurationAndTagConstraints() {
        let u = Self.universe(searches: ["artist:abba OR artist:anna": Set(1...8)])
        let root = GeneratorConstraint.group(matchAll: true, [
            .duration(seconds: 15 * 60, comparison: .about, strength: 1),
            .matchTags(query: "artist:abba OR artist:anna", invert: false, strength: 1),
            .preventDuplicates(.track),
        ])
        var rng = SplitMix64(seed: 6)
        let result = PlaylistGenerator(root: root, universe: u).run(rng: &rng)
        #expect(result.trackIds.count == 5)
        #expect(Set(result.trackIds).count == result.trackIds.count)
        #expect(result.trackIds.allSatisfy { $0 <= 8 })
        #expect(result.quality > 0.95)
    }

    @Test func spreadingKeepsArtistsApart() {
        let u = Self.universe()
        let root = GeneratorConstraint.group(matchAll: true, [
            .trackCount(6, comparison: .about, strength: 1), .spreadArtists(strength: 1), .preventDuplicates(.track),
        ])
        var rng = SplitMix64(seed: 7)
        let result = PlaylistGenerator(root: root, universe: u).run(rng: &rng)
        let artists = result.trackIds.map { u.byId[$0]!.artist }
        #expect(artists.count == 6)
        for i in artists.indices.dropFirst() { #expect(artists[i] != artists[i - 1]) }
    }

    @Test func summaryDescribesTheTree() {
        let bias = Bias.partition([.init(weight: 3, bias: .or([.search("genre:rock"), .search("genre:pop")])),
                                   .init(weight: 1, bias: .not(.albumPlay(.sameAlbum)))])
        #expect(bias.summary == "75% (“genre:rock” or “genre:pop”) + 25% not Album play: same album")
    }

        @Test func storesDefinitionsAndSeedsPresets() throws {
        let db = try LibraryDatabase.inMemory()
        let store = GeneratorStore(database: db)
        let seeded = store.dynamicPlaylists()
        #expect(seeded.map(\.name) == DynamicPlaylist.presets.map(\.name))
        var custom = store.save(DynamicPlaylist(name: "Mine", bias: .and([.search("year:>1990"), .not(.search("genre:jazz"))])))
        #expect(store.dynamicPlaylists().last == custom)
        custom.name = "Renamed"
        store.save(custom)
        #expect(store.dynamicPlaylists().last?.name == "Renamed")
        store.deleteDynamicPlaylist(id: custom.id!)
        #expect(store.dynamicPlaylists().count == DynamicPlaylist.presets.count)
        #expect(store.generatorPresets().map(\.root) == GeneratorPreset.presets.map(\.root))
    }

    @Test func universeEvaluatesSearchesWithSQL() async throws {
        let db = try LibraryDatabase.inMemory()
        try await db.writer.write { db in
            var a = makeTrack("One", artist: "Abba", genre: "Pop")
            var b = makeTrack("Two", artist: "Bob", genre: "Jazz")
            try a.insert(db)
            try b.insert(db)
        }
        let universe = try await TrackUniverse.load(db, queries: ["genre:pop"])
        #expect(universe.tracks.count == 2)
        #expect(universe.searches["genre:pop"]?.count == 1)
    }
}

@Suite(.serialized)
struct SavedPlaylistTests {
    @Test func savesLoadsRenamesAndDeletes() async throws {
        let db = try LibraryDatabase.inMemory()
        let tracks = try await db.writer.write { db -> [Track] in
            var a = makeTrack("One")
            var b = makeTrack("Two", track: 2)
            try a.insert(db)
            try b.insert(db)
            return [a, b]
        }
        let store = SavedPlaylistStore(database: db)
        let stream = PlaylistItem.stream(url: URL(string: "https://radio.example.org/live")!, title: "Live")
        let missing = PlaylistItem(track: Track(path: "/nowhere/gone.flac", title: "Gone"), source: .file)
        let items = tracks.map { PlaylistItem(track: $0) } + [stream, missing]
        let id = try store.save(name: "Mix", items: items)
        #expect(store.all().map(\.name) == ["Mix"])
        #expect(store.all().first?.trackCount == 4)

        let loaded = await store.items(playlistId: id)
        #expect(loaded.map(\.track.title) == ["One", "Two", "Live", "Gone"])
        #expect(loaded[0].source == .collection && loaded[2].isStream && loaded[3].source == .file)

        store.rename(id: id, to: "Renamed")
        #expect(store.all().first?.name == "Renamed")

        let file = temporaryDirectory().appendingPathComponent("mix.xspf")
        try await store.export(playlistId: id, to: file)
        let imported = try await store.importFile(file)
        #expect(await store.items(playlistId: imported).count == 3, "the missing file is skipped on import")

        store.delete(ids: [id, imported])
        #expect(store.all().isEmpty)
    }
}
