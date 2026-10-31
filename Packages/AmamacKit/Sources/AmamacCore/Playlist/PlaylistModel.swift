import Foundation

/// A change to the playlist, in source-order indexes.
public enum PlaylistChange: Sendable, Equatable {
    case inserted(IndexSet)
    case removed(IndexSet)
    /// Items were reordered or replaced wholesale; views should reload.
    case reloaded
    /// Metadata of existing items changed (indexes are still valid).
    case updated(IndexSet)
    case activeChanged
    case queueChanged
    case stopAfterChanged

    /// Whether the change alters which items are in the playlist or their order.
    public var isStructural: Bool {
        switch self {
        case .inserted, .removed, .reloaded: true
        default: false
        }
    }
}

/// The current playlist: ordered items, active item, queue, stop-after marker and undo history.
@MainActor
public final class PlaylistModel {
    public static let undoLimit = 30

    public private(set) var order: [PlaylistItemID] = []
    private var store: [PlaylistItemID: PlaylistItem] = [:]
    private var indexCache: [PlaylistItemID: Int]?

    public private(set) var activeID: PlaylistItemID?
    /// Index the active item had before it was removed from the playlist (Amarok keeps playing a
    /// removed track and continues from where it was).
    public private(set) var orphanIndex: Int?
    public private(set) var queue: [PlaylistItemID] = []
    public private(set) var stopAfterID: PlaylistItemID?

    private var undoStack: [[PlaylistItemID]] = []
    private var redoStack: [[PlaylistItemID]] = []

    private var observers: [UUID: (PlaylistChange) -> Void] = [:]

    public init() {}

    // MARK: Observation

    @discardableResult
    public func observe(_ handler: @escaping (PlaylistChange) -> Void) -> PlaylistObservation {
        let token = UUID()
        observers[token] = handler
        return PlaylistObservation { [weak self] in self?.observers[token] = nil }
    }

    private func notify(_ change: PlaylistChange) {
        for handler in observers.values { handler(change) }
    }

    // MARK: Access

    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }
    public var items: [PlaylistItem] { order.compactMap { store[$0] } }

    public subscript(index: Int) -> PlaylistItem { store[order[index]]! }

    public func item(_ id: PlaylistItemID) -> PlaylistItem? { store[id] }

    public func index(of id: PlaylistItemID) -> Int? {
        if indexCache == nil {
            var cache: [PlaylistItemID: Int] = [:]
            cache.reserveCapacity(order.count)
            for (i, id) in order.enumerated() { cache[id] = i }
            indexCache = cache
        }
        return indexCache?[id]
    }

    public func contains(_ id: PlaylistItemID) -> Bool { index(of: id) != nil }

    public var activeItem: PlaylistItem? { activeID.flatMap { store[$0] } }
    public var activeIndex: Int? { activeID.flatMap { index(of: $0) } }

    public var totalDuration: TimeInterval { order.reduce(0) { $0 + (store[$1]?.duration ?? 0) } }
    public var queueDuration: TimeInterval { queue.reduce(0) { $0 + (store[$1]?.duration ?? 0) } }
    public var totalFileSize: Int64 { order.reduce(0) { $0 + (store[$1]?.track.fileSize ?? 0) } }

    // MARK: Undoable edits

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(order)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    private func setOrder(_ newOrder: [PlaylistItemID]) {
        let removedActive = activeID.map { id in index(of: id) != nil && !newOrder.contains(id) } ?? false
        let oldActiveIndex = activeIndex
        order = newOrder
        indexCache = nil
        if removedActive {
            orphanIndex = oldActiveIndex
        } else if let activeID, index(of: activeID) != nil {
            orphanIndex = nil
        }
        let present = Set(newOrder)
        let oldQueue = queue
        queue.removeAll { !present.contains($0) }
        if let s = stopAfterID, !present.contains(s), s != activeID { stopAfterID = nil }
        if queue != oldQueue { notify(.queueChanged) }
        pruneStore()
    }

    /// Inserts items at `index` (appends when nil). Returns the inserted IDs.
    @discardableResult
    public func insert(_ newItems: [PlaylistItem], at index: Int? = nil) -> [PlaylistItemID] {
        guard !newItems.isEmpty else { return [] }
        pushUndo()
        let position = min(max(index ?? order.count, 0), order.count)
        for item in newItems { store[item.id] = item }
        var newOrder = order
        newOrder.insert(contentsOf: newItems.map(\.id), at: position)
        setOrder(newOrder)
        notify(.inserted(IndexSet(integersIn: position..<(position + newItems.count))))
        return newItems.map(\.id)
    }

    @discardableResult
    public func append(_ newItems: [PlaylistItem]) -> [PlaylistItemID] { insert(newItems, at: nil) }

    public func remove(_ ids: Set<PlaylistItemID>) {
        let indexes = IndexSet(ids.compactMap { index(of: $0) })
        guard !indexes.isEmpty else { return }
        pushUndo()
        let newOrder = order.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        setOrder(newOrder)
        notify(.removed(indexes))
    }

    /// Moves the given items (kept in their current relative order) so they start at `destination`,
    /// where `destination` is an index in the current order (like `NSTableView` drop rows).
    public func move(_ ids: [PlaylistItemID], to destination: Int) {
        let moving = ids.filter { index(of: $0) != nil }.sorted { index(of: $0)! < index(of: $1)! }
        guard !moving.isEmpty else { return }
        let movingSet = Set(moving)
        let before = order[..<min(max(destination, 0), order.count)].filter { !movingSet.contains($0) }.count
        var remaining = order.filter { !movingSet.contains($0) }
        remaining.insert(contentsOf: moving, at: before)
        guard remaining != order else { return }
        pushUndo()
        setOrder(remaining)
        notify(.reloaded)
    }

    public func clear() {
        guard !order.isEmpty else { return }
        pushUndo()
        setOrder([])
        notify(.reloaded)
    }

    /// Replaces the playlist contents (undoable).
    public func replace(with newItems: [PlaylistItem]) {
        pushUndo()
        for item in newItems { store[item.id] = item }
        setOrder(newItems.map(\.id))
        notify(.reloaded)
    }

    /// Permanently reorders the playlist randomly (Playlist ▸ Shuffle).
    public func shuffle<G: RandomNumberGenerator>(using rng: inout G) {
        guard order.count > 1 else { return }
        pushUndo()
        setOrder(order.shuffled(using: &rng))
        notify(.reloaded)
    }

    /// Removes later duplicates of the same file and entries whose local file no longer exists.
    @discardableResult
    public func removeDuplicatesAndDead(fileExists: (URL) -> Bool) -> Int {
        var seen = Set<String>()
        var keep: [PlaylistItemID] = []
        for id in order {
            guard let item = store[id] else { continue }
            let key = item.url.isFileURL ? item.url.standardizedFileURL.path : item.url.absoluteString
            if seen.contains(key) { continue }
            if item.url.isFileURL && !fileExists(item.url) { continue }
            seen.insert(key)
            keep.append(id)
        }
        let removed = order.count - keep.count
        guard removed > 0 else { return 0 }
        pushUndo()
        setOrder(keep)
        notify(.reloaded)
        return removed
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(order)
        setOrder(previous)
        notify(.reloaded)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(order)
        setOrder(next)
        notify(.reloaded)
    }

    // MARK: Non-undoable state

    public func setActive(_ id: PlaylistItemID?) {
        guard id != activeID else { return }
        activeID = id
        orphanIndex = nil
        notify(.activeChanged)
    }

    /// Updates metadata snapshots (e.g. after statistics or tag changes).
    public func updateItems(where predicate: (PlaylistItem) -> Bool, _ transform: (inout PlaylistItem) -> Void) {
        var changed = IndexSet()
        for (id, var item) in store where predicate(item) {
            transform(&item)
            store[id] = item
            if let i = index(of: id) { changed.insert(i) }
        }
        if !changed.isEmpty { notify(.updated(changed)) }
    }

    public func updateTrack(id trackId: Int64, _ transform: (inout PlaylistItem) -> Void) {
        updateItems(where: { $0.track.id == trackId }, transform)
    }

    public func updateItem(_ id: PlaylistItemID, _ transform: (inout PlaylistItem) -> Void) {
        guard var item = store[id] else { return }
        transform(&item)
        store[id] = item
        if let i = index(of: id) { notify(.updated(IndexSet(integer: i))) }
    }

    // MARK: Queue

    public func isQueued(_ id: PlaylistItemID) -> Bool { queue.contains(id) }

    /// 1-based queue position, or nil.
    public func queuePosition(_ id: PlaylistItemID) -> Int? { queue.firstIndex(of: id).map { $0 + 1 } }

    public func enqueue(_ ids: [PlaylistItemID]) {
        let new = ids.filter { contains($0) && !queue.contains($0) }
        guard !new.isEmpty else { return }
        queue.append(contentsOf: new)
        notify(.queueChanged)
    }

    public func dequeue(_ ids: Set<PlaylistItemID>) {
        let before = queue.count
        queue.removeAll { ids.contains($0) }
        if queue.count != before { notify(.queueChanged) }
    }

    /// Toggles queueing for the given items (Queue / Dequeue Track).
    public func toggleQueue(_ ids: [PlaylistItemID]) {
        if ids.allSatisfy(isQueued) { dequeue(Set(ids)) } else { enqueue(ids.filter { !isQueued($0) }) }
    }

    public func setQueue(_ ids: [PlaylistItemID]) {
        let filtered = ids.filter(contains)
        guard filtered != queue else { return }
        queue = filtered
        notify(.queueChanged)
    }

    public func popQueueFront(ifEqual id: PlaylistItemID) {
        if queue.first == id {
            queue.removeFirst()
            notify(.queueChanged)
        } else if let i = queue.firstIndex(of: id) {
            queue.remove(at: i)
            notify(.queueChanged)
        }
    }

    // MARK: Stop after

    public func setStopAfter(_ id: PlaylistItemID?) {
        guard id != stopAfterID else { return }
        stopAfterID = id
        notify(.stopAfterChanged)
    }

    // MARK: Restore

    /// Restores a saved session without recording undo history.
    public func restore(items: [PlaylistItem], activeID: PlaylistItemID?, queue: [PlaylistItemID],
                        stopAfterID: PlaylistItemID?) {
        store = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        order = items.map(\.id)
        indexCache = nil
        undoStack.removeAll()
        redoStack.removeAll()
        self.activeID = activeID.flatMap { store[$0] != nil ? $0 : nil }
        orphanIndex = nil
        self.queue = queue.filter { store[$0] != nil }
        self.stopAfterID = stopAfterID.flatMap { store[$0] != nil ? $0 : nil }
        notify(.reloaded)
        notify(.activeChanged)
        notify(.queueChanged)
    }

    private func pruneStore() {
        guard store.count > order.count * 2 + 512 else { return }
        var referenced = Set(order)
        for snapshot in undoStack { referenced.formUnion(snapshot) }
        for snapshot in redoStack { referenced.formUnion(snapshot) }
        if let activeID { referenced.insert(activeID) }
        store = store.filter { referenced.contains($0.key) }
    }
}

/// Cancels a `PlaylistModel.observe` registration when cancelled or deallocated.
public final class PlaylistObservation {
    private var cancelAction: (@MainActor () -> Void)?
    init(_ cancel: @escaping @MainActor () -> Void) { cancelAction = cancel }
    @MainActor public func cancel() { cancelAction?(); cancelAction = nil }
}
