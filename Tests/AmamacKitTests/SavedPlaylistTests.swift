import Foundation
import GRDB
import Testing
@testable import AmamacDatabase
@testable import AmamacModels
@testable import AmamacPlaylist

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
