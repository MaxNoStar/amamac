import Foundation

/// The view of the playlist the user sees: source order → "show only matches" filter →
/// multi-level sort → grouping. Navigators walk this order, as in Amarok.
@MainActor
public final class PlaylistProxy {
    public let model: PlaylistModel

    public var sortLevels: [PlaylistSortLevel] = [] { didSet { if sortLevels != oldValue { rebuild(); notify() } } }
    /// When set, only matching items are visible.
    public var filter: PlaylistSearch? { didSet { if filter != oldValue { rebuild(); notify() } } }
    public var grouping: PlaylistGrouping = .album { didSet { if grouping != oldValue { rebuildGroups(); notify() } } }
    /// Seed for the "Shuffle" sort level; changes when a shuffle level is (re)added.
    public var shuffleSeed: UInt64 = 0x5EED { didSet { if sortLevels.contains(.shuffle) { rebuild(); notify() } } }

    public private(set) var visible: [PlaylistItemID] = []
    /// `groupHeads[i]` is true when visible row `i` starts a new group.
    public private(set) var groupHeads: [Bool] = []
    private var indexCache: [PlaylistItemID: Int] = [:]
    private var observation: PlaylistObservation?
    private var listeners: [UUID: () -> Void] = [:]

    public init(model: PlaylistModel) {
        self.model = model
        rebuild()
        observation = model.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .inserted, .removed, .reloaded:
                self.rebuild()
            case .updated:
                // Metadata changes can affect sorting, filtering or grouping.
                if !self.sortLevels.isEmpty || self.filter != nil { self.rebuild() } else { self.rebuildGroups() }
            default:
                return
            }
            self.notify()
        }
    }

    /// Whether the visible order is exactly the source order (drag reordering is allowed).
    public var isIdentity: Bool { sortLevels.isEmpty && filter == nil }

    public var count: Int { visible.count }
    public subscript(row: Int) -> PlaylistItem { model.item(visible[row])! }
    public func item(at row: Int) -> PlaylistItem? { row >= 0 && row < visible.count ? model.item(visible[row]) : nil }
    public func row(of id: PlaylistItemID) -> Int? { indexCache[id] }

    /// Maps a visible row to the model's source index (for inserting dropped items).
    public func sourceIndex(forRow row: Int) -> Int {
        if row >= visible.count { return model.count }
        return model.index(of: visible[row]) ?? model.count
    }

    @discardableResult
    public func onChange(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    public func removeListener(_ token: UUID) { listeners[token] = nil }

    private func notify() { for l in listeners.values { l() } }

    public func rebuild() {
        var ids = model.order
        if let filter {
            ids = ids.filter { model.item($0).map(filter.matches) ?? false }
        }
        if !sortLevels.isEmpty {
            var randomKeys: [PlaylistItemID: UInt64] = [:]
            if sortLevels.contains(where: { $0.column == nil }) {
                var rng = SplitMix64(seed: shuffleSeed)
                for id in ids { randomKeys[id] = rng.next() }
            }
            let items = Dictionary(uniqueKeysWithValues: ids.compactMap { id in model.item(id).map { (id, $0) } })
            let position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            ids.sort { lhs, rhs in
                guard let a = items[lhs], let b = items[rhs] else { return false }
                for level in sortLevels {
                    let result: ComparisonResult
                    if let column = level.column {
                        result = column.compare(a, b)
                    } else {
                        let ka = randomKeys[lhs]!, kb = randomKeys[rhs]!
                        result = ka < kb ? .orderedAscending : (ka > kb ? .orderedDescending : .orderedSame)
                    }
                    if result != .orderedSame {
                        return level.ascending ? result == .orderedAscending : result == .orderedDescending
                    }
                }
                return position[lhs]! < position[rhs]!
            }
        }
        visible = ids
        indexCache = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        rebuildGroups()
    }

    private func rebuildGroups() {
        var heads = [Bool](repeating: false, count: visible.count)
        var previousKey: String?
        for (i, id) in visible.enumerated() {
            guard let item = model.item(id) else { continue }
            let key = grouping.key(for: item)
            heads[i] = grouping != .none && key != previousKey
            previousKey = key
        }
        groupHeads = heads
    }

    /// The range of visible rows in the group containing `row`.
    public func groupRange(containing row: Int) -> Range<Int> {
        guard row >= 0, row < visible.count, grouping != .none else { return row..<(row + 1) }
        var start = row
        while start > 0 && !groupHeads[start] { start -= 1 }
        var end = row + 1
        while end < visible.count && !groupHeads[end] { end += 1 }
        return start..<end
    }

    /// Visible rows matching a progressive search (for Previous/Next match).
    public func matchingRows(_ search: PlaylistSearch) -> [Int] {
        visible.enumerated().compactMap { model.item($0.element).map(search.matches) == true ? $0.offset : nil }
    }
}
