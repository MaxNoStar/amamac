import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacModels
@testable import AmamacPlaylist

@MainActor
struct PlaylistModelTests {
    @Test func insertRemoveMoveUndo() {
        let model = PlaylistModel()
        let items = (1...5).map { makeItem("T\($0)", track: $0) }
        model.append(items)
        #expect(model.count == 5)
        model.remove([items[1].id, items[3].id])
        #expect(model.items.map(\.track.title) == ["T1", "T3", "T5"])
        model.move([items[4].id], to: 0)
        #expect(model.items.map(\.track.title) == ["T5", "T1", "T3"])
        model.undo()
        #expect(model.items.map(\.track.title) == ["T1", "T3", "T5"])
        model.undo()
        #expect(model.count == 5)
        model.redo()
        #expect(model.items.map(\.track.title) == ["T1", "T3", "T5"])
        model.clear()
        #expect(model.isEmpty)
        model.undo()
        #expect(model.count == 3)
    }

    @Test func moveToEndAndMiddle() {
        let model = PlaylistModel()
        let items = (1...4).map { makeItem("T\($0)", track: $0) }
        model.append(items)
        model.move([items[0].id], to: 4)
        #expect(model.items.map(\.track.title) == ["T2", "T3", "T4", "T1"])
        // Current order T2 T3 T4 T1; move T2 and T4 (kept in order) to row 1 → before T3.
        model.move([items[3].id, items[1].id], to: 1)
        #expect(model.items.map(\.track.title) == ["T2", "T4", "T3", "T1"])
    }

    @Test func undoLimit() {
        let model = PlaylistModel()
        for i in 0..<40 { model.append([makeItem("T\(i)")]) }
        var undos = 0
        while model.canUndo { model.undo(); undos += 1 }
        #expect(undos == PlaylistModel.undoLimit)
    }

    @Test func queueFollowsRemovals() {
        let model = PlaylistModel()
        let items = (1...3).map { makeItem("T\($0)", track: $0) }
        model.append(items)
        model.enqueue([items[2].id, items[0].id])
        #expect(model.queuePosition(items[2].id) == 1)
        model.remove([items[2].id])
        #expect(model.queue == [items[0].id])
    }

    @Test func duplicatesAndDeadEntries() {
        let model = PlaylistModel()
        let a = makeItem("A")
        var b = makeItem("B"); b.track.path = a.track.path; b.url = a.url
        let c = makeItem("C", track: 3)
        model.append([a, b, c])
        let removed = model.removeDuplicatesAndDead { $0 != c.url }
        #expect(removed == 2)
        #expect(model.items.map(\.track.title) == ["A"])
    }
}

@MainActor
struct NavigatorTests {
    func setup(_ count: Int = 5, albums: [String]? = nil) -> (PlaylistModel, PlaylistProxy, PlaylistNavigator, [PlaylistItem]) {
        let model = PlaylistModel()
        let items = (0..<count).map { i in makeItem("T\(i)", album: albums?[i] ?? "Album", track: i + 1) }
        model.append(items)
        let proxy = PlaylistProxy(model: model)
        let nav = PlaylistNavigator(proxy: proxy, rng: SplitMix64(seed: 42))
        return (model, proxy, nav, items)
    }

    @Test func standardStopsAtEnd() {
        let (model, _, nav, items) = setup(3)
        #expect(nav.peekNext() == items[0].id)
        nav.commitAdvance(to: items[0].id)
        #expect(nav.peekNext() == items[1].id)
        nav.commitAdvance(to: items[2].id)
        #expect(nav.peekNext() == nil)
        #expect(nav.peekPrevious() == items[1].id)
        #expect(model.activeID == items[2].id)
    }

    @Test func repeatModes() {
        let (_, _, nav, items) = setup(4, albums: ["A", "A", "B", "B"])
        nav.commitAdvance(to: items[3].id)
        nav.progression = .repeatPlaylist
        #expect(nav.peekNext() == items[0].id)
        nav.progression = .repeatTrack
        #expect(nav.peekNext() == items[3].id)
        nav.progression = .repeatAlbum
        #expect(nav.peekNext() == items[2].id)
        nav.commitAdvance(to: items[0].id)
        #expect(nav.peekNext() == items[1].id)
        nav.commitAdvance(to: items[1].id)
        #expect(nav.peekNext() == items[0].id)
    }

    @Test func queueTakesPrecedenceAndIsConsumed() {
        let (model, _, nav, items) = setup(5)
        nav.commitAdvance(to: items[0].id)
        model.enqueue([items[3].id])
        #expect(nav.peekNext() == items[3].id)
        nav.commitAdvance(to: items[3].id)
        #expect(model.queue.isEmpty)
        #expect(nav.peekNext() == items[4].id)
        nav.progression = .onlyQueue
        #expect(nav.peekNext() == nil)
    }

    @Test func stopAfter() {
        let (model, _, nav, items) = setup(3)
        nav.commitAdvance(to: items[0].id)
        model.setStopAfter(items[0].id)
        #expect(nav.peekNext() == nil)
        #expect(nav.nextIgnoringStopAfter() == items[1].id)
    }

    @Test func randomTracksVisitsEveryTrackOncePerCycle() {
        let (_, _, nav, items) = setup(8)
        nav.progression = .randomTracks
        var seen: [PlaylistItemID] = []
        for _ in 0..<8 {
            let next = nav.peekNext()!
            #expect(nav.peekNext() == next, "peekNext must be stable")
            seen.append(next)
            nav.commitAdvance(to: next)
        }
        #expect(Set(seen) == Set(items.map(\.id)))
        #expect(nav.peekNext() != nil)
    }

    @Test func randomAlbumsPlaysAlbumsInOrder() {
        let albums = ["A", "A", "A", "B", "B", "C"]
        let (_, _, nav, items) = setup(6, albums: albums)
        nav.progression = .randomAlbums
        var played: [String] = []
        for _ in 0..<6 {
            let next = nav.peekNext()!
            played.append(items.first { $0.id == next }!.track.title)
            nav.commitAdvance(to: next)
        }
        // Each album's tracks are contiguous and in order.
        let indexes = played.map { Int($0.dropFirst())! }
        for (album, members) in Dictionary(grouping: indexes, by: { albums[$0] }) {
            let positions = members.map { indexes.firstIndex(of: $0)! }
            #expect(positions == Array(positions.min()!...positions.max()!), "album \(album) not contiguous")
            #expect(members == members.sorted())
        }
    }

    @Test func removedActiveTrackContinuesFromFormerPosition() {
        let (model, _, nav, items) = setup(4)
        nav.commitAdvance(to: items[1].id)
        model.remove([items[1].id])
        #expect(model.activeID == items[1].id)
        #expect(nav.peekNext() == items[2].id)
    }

    @Test func favorHigherRatingsPrefersRatedTracks() {
        let model = PlaylistModel()
        let good = PlaylistItem(track: makeTrack("Good"), statistics: TrackStatistics(trackId: 1, rating: 10))
        let bad = (0..<5).map { i in PlaylistItem(track: makeTrack("Bad\(i)", track: i + 2), statistics: TrackStatistics(trackId: Int64(i + 2), rating: 1)) }
        model.append([good] + bad)
        let proxy = PlaylistProxy(model: model)
        var firstPicks = 0
        for seed in 0..<200 {
            let nav = PlaylistNavigator(proxy: proxy, rng: SplitMix64(seed: UInt64(seed)))
            nav.progression = .randomTracks
            nav.favor = .higherRatings
            if nav.peekNext() == good.id { firstPicks += 1 }
        }
        #expect(firstPicks > 200 / 6 * 2, "rated track should be favoured (\(firstPicks))")
    }
    @Test func favorAppliesToRandomAlbums() {
        let model = PlaylistModel()
        let loved = (0..<3).map { i in PlaylistItem(track: makeTrack("Loved\(i)", album: "Loved", track: i + 1),
                                                    statistics: TrackStatistics(trackId: Int64(i + 1), rating: 10)) }
        let others = (0..<5).flatMap { a in (0..<3).map { i in
            PlaylistItem(track: makeTrack("O\(a)-\(i)", album: "Other \(a)", track: i + 1),
                         statistics: TrackStatistics(trackId: Int64(100 + a * 10 + i), rating: 1))
        } }
        model.append(loved + others)
        let proxy = PlaylistProxy(model: model)
        var lovedFirst = 0
        for seed in 0..<200 {
            let nav = PlaylistNavigator(proxy: proxy, rng: SplitMix64(seed: UInt64(seed)))
            nav.progression = .randomAlbums
            nav.favor = .higherRatings
            if nav.peekNext() == loved[0].id { lovedFirst += 1 }
        }
        #expect(lovedFirst > 200 / 6 * 2, "the well-rated album should come first more often (\(lovedFirst))")
    }
}

@MainActor
struct ProxyTests {
    @Test func sortFilterAndGroups() {
        let model = PlaylistModel()
        let items = [makeItem("Zebra", album: "B", track: 2), makeItem("Apple", album: "A", track: 1),
                     makeItem("Mango", album: "B", track: 1)]
        model.append(items)
        let proxy = PlaylistProxy(model: model)
        #expect(proxy.groupHeads == [true, true, true])
        proxy.sortLevels = [PlaylistSortLevel(column: .album), PlaylistSortLevel(column: .trackNumber)]
        #expect(proxy.visible == [items[1].id, items[2].id, items[0].id])
        #expect(proxy.groupHeads == [true, true, false])
        #expect(proxy.groupRange(containing: 2) == 1..<3)
        proxy.filter = PlaylistSearch(text: "an")
        #expect(proxy.visible == [items[2].id])
        proxy.filter = nil
        proxy.sortLevels = []
        #expect(proxy.visible == model.order)
        #expect(proxy.isIdentity)
    }

    @Test func progressiveSearchFields() {
        let item = makeItem("Song", album: "Album X", artist: "Someone")
        #expect(PlaylistSearch(text: "album x").matches(item))
        #expect(!PlaylistSearch(text: "album x", fields: [.tracks]).matches(item))
        #expect(PlaylistSearch(text: "rock", fields: [.genre]).matches(item))
    }
}
