import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacDatabase
@testable import AmamacPlaylist
@testable import AmamacQuery
@testable import AmamacTestSupport

/// Timings on the 20,000-track synthetic library. Limits are generous (CI machines vary); the
/// printed numbers are what the performance pass looks at.
@MainActor
struct PlaylistPerformanceTests {
    static func library() throws -> (LibraryDatabase, [TrackWithStatistics]) {
        let db = try LibraryDatabase.inMemory()
        try SyntheticLibrary.populate(db, trackCount: 20_000)
        let tracks = try db.writer.read { try CollectionQueries.tracks($0, constraints: [], filter: CollectionQuery(groups: [])) }
        return (db, tracks)
    }

    func time(_ label: String, limit: Duration, _ body: () throws -> Void) rethrows {
        let elapsed = try ContinuousClock().measure(body)
        print("perf: \(label): \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        #expect(elapsed < limit, "\(label) took \(elapsed)")
    }

    @Test func twentyThousandItemPlaylist() throws {
        let (db, tracks) = try Self.library()
        #expect(tracks.count == 20_000)
        let model = PlaylistModel()
        let proxy = PlaylistProxy(model: model)
        let navigator = PlaylistNavigator(proxy: proxy, rng: SplitMix64(seed: 1))
        let items = tracks.map { $0.playlistItem() }

        try time("replace with 20k items + grouping", limit: .seconds(2)) { model.replace(with: items) }
        #expect(proxy.count == 20_000)
        time("sort by artist, album", limit: .seconds(2)) {
            proxy.sortLevels = [PlaylistSortLevel(column: .artist), PlaylistSortLevel(column: .album)]
        }
        time("filter “night”", limit: .seconds(2)) { proxy.filter = PlaylistSearch(text: "night") }
        time("clear filter and sort", limit: .seconds(2)) {
            proxy.filter = nil
            proxy.sortLevels = []
        }
        time("search matches", limit: .seconds(1)) { _ = proxy.matchingRows(PlaylistSearch(text: "love")) }
        model.setActive(model.order[10_000])
        time("random tracks: plan + 200 advances", limit: .seconds(2)) {
            navigator.progression = .randomTracks
            for _ in 0..<200 {
                guard let next = navigator.peekNext() else { break }
                navigator.commitAdvance(to: next)
                model.setActive(next)
            }
        }
        time("random albums with favor: 50 advances", limit: .seconds(3)) {
            navigator.progression = .randomAlbums
            navigator.favor = .higherScores
            for _ in 0..<50 {
                guard let next = navigator.peekNext() else { break }
                navigator.commitAdvance(to: next)
                model.setActive(next)
            }
        }
        time("remove 1,000 items", limit: .seconds(1)) { model.remove(Set(model.order.prefix(1_000))) }
        time("undo", limit: .seconds(1)) { model.undo() }
        time("index lookups ×20k", limit: .seconds(1)) {
            for id in model.order { _ = model.index(of: id) }
        }
        let session = PlaylistLoader.Session(model: model, position: 12, wasPlaying: false)
        try time("save session", limit: .seconds(2)) { try PlaylistLoader.saveSession(session, database: db) }
    }

    @Test func sessionRestoreOf20kItems() async throws {
        let (db, tracks) = try Self.library()
        let model = PlaylistModel()
        model.replace(with: tracks.map { $0.playlistItem() })
        try PlaylistLoader.saveSession(PlaylistLoader.Session(model: model, position: nil, wasPlaying: false), database: db)
        let clock = ContinuousClock()
        let start = clock.now
        let session = try #require(PlaylistLoader.loadSession(database: db))
        let items = await PlaylistLoader.items(for: session, database: db)
        let elapsed = clock.now - start
        print("perf: restore 20k-item session: \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        #expect(items.count == 20_000)
        #expect(elapsed < .seconds(5))
    }
}
