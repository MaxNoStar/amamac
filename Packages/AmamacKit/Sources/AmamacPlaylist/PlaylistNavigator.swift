import AmamacModels
import Foundation

/// Amarok's "Track Progression" modes.
public enum TrackProgression: String, CaseIterable, Sendable, Codable {
    case standard, onlyQueue, repeatTrack, repeatAlbum, repeatPlaylist, randomTracks, randomAlbums

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .onlyQueue: "Only Queue"
        case .repeatTrack: "Repeat Track"
        case .repeatAlbum: "Repeat Album"
        case .repeatPlaylist: "Repeat Playlist"
        case .randomTracks: "Random Tracks"
        case .randomAlbums: "Random Albums"
        }
    }

    public var isRandom: Bool { self == .randomTracks || self == .randomAlbums }
}

/// Bias for random modes ("Favor").
public enum FavorMode: String, CaseIterable, Sendable, Codable {
    case none, higherScores, higherRatings, notRecentlyPlayed

    public var displayName: String {
        switch self {
        case .none: "None"
        case .higherScores: "Higher Scores"
        case .higherRatings: "Higher Ratings"
        case .notRecentlyPlayed: "Not Recently Played"
        }
    }
}

/// Decides which item plays next. `peekNext()` is stable until the playlist, mode or queue
/// changes, so the engine can pre-enqueue it for gapless playback.
@MainActor
public final class PlaylistNavigator {
    public let proxy: PlaylistProxy
    public var model: PlaylistModel { proxy.model }

    public var progression: TrackProgression = .standard { didSet { if progression != oldValue { invalidate() } } }
    public var favor: FavorMode = .none { didSet { if favor != oldValue { invalidate() } } }
    public var now: () -> Date = Date.init

    private var rng: any RandomNumberGenerator
    /// Items played in the current random cycle.
    private var playedInCycle = Set<PlaylistItemID>()
    private var plannedTracks: [PlaylistItemID]?
    private var playedAlbums = Set<String>()
    private var plannedAlbums: [String]?
    /// Tracks of each album in visible order; rebuilt after the proxy changes.
    private var albumIndex: (tracks: [String: [PlaylistItemID]], order: [String])?
    /// Items played, most recent last (for Previous in random modes).
    public private(set) var history: [PlaylistItemID] = []
    private var listenerToken: UUID?

    public init(proxy: PlaylistProxy, rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.proxy = proxy
        self.rng = rng
        listenerToken = proxy.onChange { [weak self] in self?.invalidate() }
    }

    /// Drops planned random orders; called after structural changes.
    public func invalidate() {
        plannedTracks = nil
        plannedAlbums = nil
        albumIndex = nil
    }

    // MARK: Next / previous

    /// The item that should play after the active one, honouring the queue and stop-after.
    /// Returns nil when playback should stop.
    public func peekNext() -> PlaylistItemID? {
        if let active = model.activeID, model.stopAfterID == active { return nil }
        return nextIgnoringStopAfter()
    }

    /// The item the Next button / a skip moves to.
    public func nextIgnoringStopAfter() -> PlaylistItemID? {
        if let queued = model.queue.first { return queued }
        let visible = proxy.visible
        guard !visible.isEmpty else { return nil }
        let activeRow = currentRow()

        switch progression {
        case .onlyQueue:
            return nil
        case .standard:
            guard let row = activeRow else {
                return orphanFollower() ?? hiddenActiveFollower() ?? (model.activeID == nil ? visible.first : nil)
            }
            return row + 1 < visible.count ? visible[row + 1] : nil
        case .repeatTrack:
            return model.activeID.flatMap { model.item($0) != nil ? $0 : nil } ?? visible.first
        case .repeatPlaylist:
            guard let row = activeRow else { return orphanFollower() ?? hiddenActiveFollower() ?? visible.first }
            return row + 1 < visible.count ? visible[row + 1] : visible.first
        case .repeatAlbum:
            guard let row = activeRow, let active = proxy.item(at: row) else {
                return orphanFollower() ?? hiddenActiveFollower() ?? visible.first
            }
            let range = albumRun(containing: row, key: active.albumKey)
            return row + 1 < range.upperBound ? visible[row + 1] : visible[range.lowerBound]
        case .randomTracks:
            return planTracks().first
        case .randomAlbums:
            return nextRandomAlbumItem(activeRow: activeRow)
        }
    }

    public func peekPrevious() -> PlaylistItemID? {
        let visible = proxy.visible
        guard !visible.isEmpty else { return nil }
        if progression.isRandom {
            return history.dropLast(model.activeID == history.last ? 1 : 0).last
        }
        guard let row = currentRow() else { return visible.first }
        if progression == .repeatTrack { return visible[row] }
        if row > 0 { return visible[row - 1] }
        return progression == .repeatPlaylist ? visible.last : nil
    }

    /// Records that `id` became the playing item. `backward` is true when the user pressed Previous.
    public func commitAdvance(to id: PlaylistItemID, backward: Bool = false) {
        model.popQueueFront(ifEqual: id)
        if backward {
            if history.last == model.activeID { history.removeLast() }
        } else {
            history.append(id)
            if history.count > 500 { history.removeFirst(history.count - 500) }
        }
        playedInCycle.insert(id)
        if let planned = plannedTracks, let i = planned.firstIndex(of: id) {
            plannedTracks!.remove(at: i)
            if planned.count == 1 { plannedTracks = nil }
        }
        if let item = model.item(id) {
            playedAlbums.insert(item.albumKey)
            if let planned = plannedAlbums, let i = planned.firstIndex(of: item.albumKey) {
                plannedAlbums!.remove(at: i)
            }
        }
        model.setActive(id)
    }

    // MARK: Helpers

    private func currentRow() -> Int? {
        model.activeID.flatMap { proxy.row(of: $0) }
    }

    /// For a removed active item: the item that now occupies its former position.
    private func orphanFollower() -> PlaylistItemID? {
        guard let former = model.orphanIndex else { return nil }
        guard former < model.count else { return progression == .repeatPlaylist ? proxy.visible.first : nil }
        let id = model.order[former]
        return proxy.row(of: id) != nil ? id : nil
    }

    /// For an active item a search filter hides: the first shown item after it in the full playlist,
    /// so playback carries on through the matches instead of stopping.
    private func hiddenActiveFollower() -> PlaylistItemID? {
        guard let active = model.activeID, model.item(active) != nil,
              let index = model.order.firstIndex(of: active) else { return nil }
        return model.order[(index + 1)...].first { proxy.row(of: $0) != nil }
    }

    private func albumRun(containing row: Int, key: String) -> Range<Int> {
        let visible = proxy.visible
        var start = row
        while start > 0, proxy.item(at: start - 1)?.albumKey == key { start -= 1 }
        var end = row + 1
        while end < visible.count, proxy.item(at: end)?.albumKey == key { end += 1 }
        return start..<end
    }

    private func weight(_ item: PlaylistItem) -> Double {
        switch favor {
        case .none:
            return 1
        case .higherScores:
            return max(1, item.statistics?.score ?? 0)
        case .higherRatings:
            let rating = item.statistics?.rating ?? 0
            return rating == 0 ? 5 : Double(rating)   // unrated counts as 2.5 stars
        case .notRecentlyPlayed:
            guard let last = item.statistics?.lastPlayed else { return 366 }
            return min(365, max(0, now().timeIntervalSince(last) / 86_400)) + 1
        }
    }

    /// Weighted random order (Efraimidis–Spirakis).
    private func weightedShuffle(_ ids: [PlaylistItemID]) -> [PlaylistItemID] {
        if favor == .none { return ids.shuffled(using: &rng) }
        let keyed = ids.map { id -> (PlaylistItemID, Double) in
            let w = model.item(id).map(weight) ?? 1
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            return (id, pow(u, 1 / w))
        }
        return keyed.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func planTracks() -> [PlaylistItemID] {
        if let plannedTracks, !plannedTracks.isEmpty { return plannedTracks }
        let visible = proxy.visible
        var candidates = visible.filter { !playedInCycle.contains($0) && $0 != model.activeID }
        if candidates.isEmpty {
            // Start a new cycle; avoid repeating the current track immediately when possible.
            playedInCycle.removeAll()
            candidates = visible.filter { $0 != model.activeID }
            if candidates.isEmpty { candidates = visible }
        }
        let plan = weightedShuffle(candidates)
        plannedTracks = plan
        return plan
    }

    private func albumsInVisibleOrder() -> (tracks: [String: [PlaylistItemID]], order: [String]) {
        if let albumIndex { return albumIndex }
        var albums: [String: [PlaylistItemID]] = [:]
        var albumOrder: [String] = []
        for id in proxy.visible {
            guard let item = model.item(id) else { continue }
            if albums[item.albumKey] == nil { albumOrder.append(item.albumKey) }
            albums[item.albumKey, default: []].append(id)
        }
        albumIndex = (albums, albumOrder)
        return (albums, albumOrder)
    }

    /// Albums in random order; with a Favor mode, weighted by their tracks' average weight.
    private func shuffleAlbums(_ keys: [String], tracks: [String: [PlaylistItemID]]) -> [String] {
        if favor == .none { return keys.shuffled(using: &rng) }
        let keyed = keys.map { key -> (String, Double) in
            let items = (tracks[key] ?? []).compactMap { model.item($0) }
            let w = items.isEmpty ? 1 : items.map(weight).reduce(0, +) / Double(items.count)
            return (key, pow(Double.random(in: Double.ulpOfOne..<1, using: &rng), 1 / max(w, 0.0001)))
        }
        return keyed.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func nextRandomAlbumItem(activeRow: Int?) -> PlaylistItemID? {
        let (albums, albumOrder) = albumsInVisibleOrder()
        if let active = model.activeItem, let tracks = albums[active.albumKey],
           let pos = tracks.firstIndex(of: active.id), pos + 1 < tracks.count {
            return tracks[pos + 1]
        }
        if plannedAlbums == nil || plannedAlbums!.isEmpty {
            var candidates = albumOrder.filter { !playedAlbums.contains($0) && $0 != model.activeItem?.albumKey }
            if candidates.isEmpty {
                playedAlbums.removeAll()
                candidates = albumOrder.filter { $0 != model.activeItem?.albumKey }
                if candidates.isEmpty { candidates = albumOrder }
            }
            plannedAlbums = shuffleAlbums(candidates, tracks: albums)
        }
        while let key = plannedAlbums?.first {
            if let first = albums[key]?.first { return first }
            plannedAlbums?.removeFirst()
        }
        return nil
    }
}
