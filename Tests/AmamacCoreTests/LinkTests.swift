import Foundation
import Testing
@testable import AmamacCore

struct LinkTests {
    @Test func parsesAndBuildsLinks() {
        #expect(AmamacLink(url: URL(string: "amamac://navigate/position?track=42&pos=83")!) == .position(trackId: 42, seconds: 83))
        let view = AmamacLink.collection(filter: "genre:rock year:>1990 +live", levels: ["genre", "albumArtist"])
        #expect(AmamacLink(url: view.url) == view)
        let files = AmamacLink.category("files", path: "/Volumes/Music/Jazz & Blues")
        #expect(AmamacLink(url: files.url) == files)
        #expect(AmamacLink(url: URL(string: "amamac://navigate/playlists")!) == .category("playlists", path: nil))
        #expect(AmamacLink(url: URL(string: "amamac://navigate/position?pos=3")!) == nil)
        #expect(AmamacLink(url: URL(string: "https://navigate/position?track=1")!) == nil)
    }

    @Test func storesViewBookmarks() throws {
        let db = try LibraryDatabase.inMemory()
        let store = BookmarkStore(database: db)
        let saved = store.addView(name: "Rock", link: .collection(filter: "genre:rock", levels: ["album"]))
        #expect(saved?.kind == .view)
        #expect(store.all().map(\.url).compactMap { URL(string: $0).flatMap(AmamacLink.init(url:)) } == [.collection(filter: "genre:rock", levels: ["album"])])
    }
}
