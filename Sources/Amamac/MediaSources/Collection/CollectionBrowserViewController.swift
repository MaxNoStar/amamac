import AmamacBase
import AmamacDatabase
import AmamacModels
import AmamacQuery
import AppKit

/// A node of the collection tree. Identity is its path so expansion survives reloads.
nonisolated final class CollectionNode: NSObject {
    enum Kind {
        case group(CollectionGroup)
        case track(TrackWithStatistics)
        case disc(Int)
    }

    let kind: Kind
    /// Constraints that select this node's tracks.
    let constraints: [CollectionConstraint]
    let depth: Int
    let path: String
    var children: [CollectionNode]?

    init(kind: Kind, constraints: [CollectionConstraint], depth: Int, path: String) {
        self.kind = kind
        self.constraints = constraints
        self.depth = depth
        self.path = path
    }

    override func isEqual(_ object: Any?) -> Bool { (object as? CollectionNode)?.path == path }
    override var hash: Int { path.hashValue }

    var group: CollectionGroup? { if case .group(let g) = kind { g } else { nil } }
    var track: TrackWithStatistics? { if case .track(let t) = kind { t } else { nil } }
    var isExpandable: Bool { group != nil }
}

/// "Local Music": the collection tree with search, filter presets and Sort Options.
final class CollectionBrowserViewController: NSViewController, MediaSourcePage, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate {
    var crumbTitle: String { "Local Music" }
    var crumbSymbol: String { "music.note.house" }

    let env: AppEnvironment
    let outline = CollectionOutlineView()
    let searchField = NSSearchField()
    private var roots: [CollectionNode] = []
    private var filter = CollectionQuery()
    private var filterTimer: Timer?
    private var reloadPending = false

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var grouping: CollectionGrouping { env.settings.collectionGrouping }

    override func loadView() {
        let root = NSView()
        root.identifier = NSUserInterfaceItemIdentifier("collectionBrowser")
        searchField.placeholderString = "Search collection"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.toolTip = "Filter the collection. Examples: artist:beatles  year:>1990  rating:>3  added:<2w  -genre:pop"

        let presets = NSPopUpButton(frame: .zero, pullsDown: true)
        presets.addItem(withTitle: "")
        presets.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter presets")
        for (title, query) in Self.presets {
            let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.representedObject = query
            item.target = self
            presets.menu?.addItem(item)
        }
        presets.menu?.addItem(.separator())
        let editFilter = NSMenuItem(title: "Edit Filter…", action: #selector(editFilter(_:)), keyEquivalent: "")
        editFilter.target = self
        presets.menu?.addItem(editFilter)
        presets.isBordered = false
        presets.toolTip = "Filter presets"
        (presets.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
        sortButton.addItem(withTitle: "")
        sortButton.item(at: 0)?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Sort Options")
        sortButton.menu?.delegate = self
        sortButton.isBordered = false
        sortButton.toolTip = "Sort Options"
        (sortButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        sortMenu = sortButton.menu

        let bar = NSStackView(views: [searchField, presets, sortButton])
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 4)

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.target = self
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onReturn = { [weak self] in self?.playSelection() }
        outline.onMiddleClick = { [weak self] row in self?.middleClicked(row: row) }
        outline.setAccessibilityLabel("Collection")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for v in [bar, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        reload()
        NotificationCenter.default.addObserver(forName: AppEnvironment.coverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let outline = self?.outline else { return }
                let visible = outline.rows(in: outline.visibleRect)
                guard visible.length > 0 else { return }
                outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
            }
        }
        NotificationCenter.default.addObserver(forName: AppEnvironment.collectionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    private var sortMenu: NSMenu?

    static let presets: [(String, String)] = [
        ("Added This Hour", "added:<1h"),
        ("Added Today", "added:<1d"),
        ("Added This Week", "added:<1w"),
        ("Added This Month", "added:<1m"),
        ("Never Played", "playcount:0"),
    ]

    // MARK: Loading

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reload(keepExpansion: true)
            }
        }
    }

    func reload(keepExpansion: Bool = false) {
        let expanded = keepExpansion ? expandedPaths() : []
        roots = loadChildren(of: nil)
        outline.reloadData()
        if keepExpansion {
            restoreExpansion(expanded, nodes: roots)
        } else if !filter.isEmpty {
            autoExpand()
        }
    }

    private func expandedPaths() -> Set<String> {
        var paths = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? CollectionNode, outline.isItemExpanded(node) { paths.insert(node.path) }
        }
        return paths
    }

    private func restoreExpansion(_ paths: Set<String>, nodes: [CollectionNode]) {
        for node in nodes where paths.contains(node.path) {
            outline.expandItem(node)
            restoreExpansion(paths, nodes: node.children ?? [])
        }
    }

    private func autoExpand() {
        let total = (try? env.database.count(filter: self.filter)) ?? 0
        if total <= 100 {
            outline.expandItem(nil, expandChildren: true)
            return
        }
        var nodes = roots
        while nodes.count == 1, let only = nodes.first, only.isExpandable {
            outline.expandItem(only)
            nodes = only.children ?? []
        }
    }

    func loadChildren(of node: CollectionNode?) -> [CollectionNode] {
        let levels = grouping.levels
        let depth = node.map { $0.depth + 1 } ?? 0
        let constraints = node?.constraints ?? []
        let filter = self.filter
        let byYear = env.settings.bool(AppSettings.Key.showYears)
        do {
            if depth < levels.count {
                let level = levels[depth]
                return try env.database.groups(level: level, constraints: constraints, filter: filter,
                                               sortAlbumsByYear: byYear && level == .album && depth > 0)
                    .map { g in
                        CollectionNode(kind: .group(g), constraints: constraints + [CollectionConstraint(level: level, key: g.key)],
                                       depth: depth, path: (node?.path ?? "") + "/" + g.id)
                    }
            }
            let tracks = try env.database.tracks(constraints: constraints, filter: filter)
            var result: [CollectionNode] = []
            let discs = Set(tracks.map(\.track.discNumber))
            var lastDisc: Int?
            for t in tracks {
                if discs.count > 1 && levels.last == .album && t.track.discNumber != lastDisc {
                    lastDisc = t.track.discNumber
                    result.append(CollectionNode(kind: .disc(t.track.discNumber), constraints: constraints, depth: depth,
                                                 path: (node?.path ?? "") + "/disc\(t.track.discNumber)"))
                }
                result.append(CollectionNode(kind: .track(t), constraints: constraints, depth: depth,
                                             path: (node?.path ?? "") + "/t\(t.track.id ?? 0)"))
            }
            return result
        } catch {
            env.status.showMessage("Collection query failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? CollectionNode else { return roots.count }
        if node.children == nil { node.children = loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? CollectionNode else { return roots[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? CollectionNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? CollectionNode else { return 20 }
        if let g = node.group, g.level == .album, env.settings.bool(AppSettings.Key.showCoverArt) { return 38 }
        if case .disc = node.kind { return 18 }
        return 20
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .disc = (item as? CollectionNode)?.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CollectionNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: CollectionCellView.identifier, owner: nil) as? CollectionCellView) ?? CollectionCellView()
        cell.configure(node: node, settings: env.settings, covers: env.coverImages, isVariousArtists: isUnderVariousArtists(node))
        return cell
    }

    private func isUnderVariousArtists(_ node: CollectionNode) -> Bool {
        node.constraints.contains { $0.level == .albumArtist && $0.key == TextFolding.fold(TrackText.variousArtists) }
            || (node.track?.track.compilation ?? false)
    }

    // MARK: Drag

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? CollectionNode else { return nil }
        if case .disc = node.kind { return nil }
        let pb = NSPasteboardItem()
        let ids = trackIds(for: [node])
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        pb.setData(data, forType: .amamacTracks)
        if let t = node.track { pb.setString(t.track.url.absoluteString, forType: .fileURL) }
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        env.router?.showDropTargets(for: session)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        env.router?.hideDropTargets()
    }

    // MARK: Track resolution

    func trackIds(for nodes: [CollectionNode]) -> [Int64] {
        tracks(for: nodes).compactMap(\.track.id)
    }

    func tracks(for nodes: [CollectionNode]) -> [TrackWithStatistics] {
        var seen = Set<Int64>()
        var result: [TrackWithStatistics] = []
        let filter = self.filter
        for node in nodes {
            let list: [TrackWithStatistics]
            if let t = node.track {
                list = [t]
            } else if node.group != nil {
                list = (try? env.database.tracks(constraints: node.constraints, filter: filter)) ?? []
            } else {
                list = []
            }
            for t in list where seen.insert(t.track.id ?? -1).inserted { result.append(t) }
        }
        return result
    }

    var selectedNodes: [CollectionNode] {
        let rows = outline.selectedRowIndexes.isEmpty && outline.clickedRow >= 0 ? IndexSet(integer: outline.clickedRow) : outline.selectedRowIndexes
        let nodes = rows.compactMap { outline.item(atRow: $0) as? CollectionNode }
        // Drop children of selected parents.
        let paths = Set(nodes.filter(\.isExpandable).map(\.path))
        return nodes.filter { node in !paths.contains { node.path != $0 && node.path.hasPrefix($0 + "/") } }
    }

    var contextNodes: [CollectionNode] {
        let clicked = outline.clickedRow
        if clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) {
            return [outline.item(atRow: clicked) as? CollectionNode].compactMap { $0 }
        }
        return selectedNodes
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? CollectionNode else { return }
        if node.isExpandable && node.track == nil {
            // Amarok 3.3: single click expands, double click adds to the playlist.
        }
        env.actions.addToPlaylist(tracks(for: [node]), mode: .append)
    }

    private func middleClicked(row: Int) {
        guard let node = outline.item(atRow: row) as? CollectionNode else { return }
        env.actions.addToPlaylist(tracks(for: [node]), mode: .appendAndPlay)
    }

    func playSelection() {
        env.actions.addToPlaylist(tracks(for: selectedNodes), mode: .appendAndPlay)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        filterTimer?.invalidate()
        filterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFilter(sender.stringValue) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        searchChanged(searchField)
    }

    func applyFilter(_ text: String) {
        let parsed = CollectionQuery.parse(text)
        guard parsed != filter else { return }
        filter = parsed
        reload()
    }

    func setFilterText(_ text: String) {
        searchField.stringValue = text
        applyFilter(text)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let query = sender.representedObject as? String else { return }
        setFilterText(query)
    }

    @objc private func editFilter(_ sender: Any?) {
        EditFilterDialog.show(initial: searchField.stringValue, relativeTo: view.window) { [weak self] text in
            self?.setFilterText(text)
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sortMenu { buildSortMenu(menu) } else if menu === outline.menu { buildContextMenu(menu) }
    }

    private func buildSortMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.items[0].image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Sort Options")
        for (title, preset) in CollectionGrouping.presets {
            let item = NSMenuItem(title: title, action: #selector(setGroupingPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.levels.map(\.rawValue)
            item.state = grouping == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, title) in ["First Level", "Second Level", "Third Level"].enumerated() {
            let sub = NSMenu()
            if index > 0 {
                let none = NSMenuItem(title: "None", action: #selector(setLevel(_:)), keyEquivalent: "")
                none.target = self
                none.tag = index * 100 + 99
                none.state = grouping.levels.count <= index ? .on : .off
                sub.addItem(none)
            }
            for (i, level) in CollectionLevel.allCases.enumerated() {
                let item = NSMenuItem(title: level.displayName, action: #selector(setLevel(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index * 100 + i
                item.state = grouping.levels.count > index && grouping.levels[index] == level ? .on : .off
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        for (title, key) in [("Show Years", AppSettings.Key.showYears), ("Show Track Numbers", AppSettings.Key.showTrackNumbers),
                             ("Show Artist for Various Artists", AppSettings.Key.showArtistForVarious),
                             ("Show Cover Art", AppSettings.Key.showCoverArt)] {
            let item = NSMenuItem(title: title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = env.settings.bool(key) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func setGroupingPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? [String] else { return }
        env.settings.collectionGrouping = CollectionGrouping(raw.compactMap(CollectionLevel.init(rawValue:)))
        reload()
    }

    @objc private func setLevel(_ sender: NSMenuItem) {
        let index = sender.tag / 100, choice = sender.tag % 100
        var levels = grouping.levels
        if choice == 99 {
            levels = Array(levels.prefix(index))
        } else {
            let level = CollectionLevel.allCases[choice]
            if index < levels.count { levels[index] = level } else { levels.append(level) }
        }
        // Remove duplicates while keeping order.
        var seen = Set<CollectionLevel>()
        levels = levels.filter { seen.insert($0).inserted }
        if levels.isEmpty { levels = [.albumArtist] }
        env.settings.collectionGrouping = CollectionGrouping(levels)
        reload()
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        env.settings.set(!env.settings.bool(key), key)
        reload(keepExpansion: true)
    }

    private func buildContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = contextNodes
        guard !nodes.isEmpty else { return }
        func add(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        add("Add to Playlist", #selector(menuAppend), symbol: "text.badge.plus")
        add("Replace Playlist", #selector(menuReplace), symbol: "arrow.triangle.2.circlepath")
        add("Play", #selector(menuPlay), symbol: "play")
        add("Queue Tracks", #selector(menuQueue), symbol: "list.number")
        add("Collapse All", #selector(collapseAll), symbol: "rectangle.compress.vertical")
        if let album = nodes.first?.group, album.level == .album, let key = album.albumKey {
            menu.addItem(.separator())
            let albumMenu = NSMenu()
            for (title, symbol, action) in [("Fetch Cover…", "arrow.down.circle", #selector(ToolsCommands.fetchCover(_:))),
                                            ("Display Cover", "photo", #selector(ToolsCommands.displayCover(_:))),
                                            ("Set Custom Cover…", "photo.badge.plus", #selector(ToolsCommands.setCustomCover(_:))),
                                            ("Unset Cover", "photo.badge.minus", #selector(ToolsCommands.unsetCover(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.representedObject = AlbumReference(albumKey: key, album: album.name, artist: album.albumArtist ?? "")
                albumMenu.addItem(item)
            }
            let albumItem = NSMenuItem(title: "Album", action: nil, keyEquivalent: "")
            albumItem.submenu = albumMenu
            menu.addItem(albumItem)
        }
        menu.addItem(.separator())
        if nodes.allSatisfy({ $0.track != nil }) {
            let ids = nodes.compactMap { $0.track?.track.id }
            let ratings = Set(nodes.map { $0.track?.statistics?.rating ?? 0 })
            menu.addItem(env.actions.ratingMenuItem(trackIds: ids, current: ratings.count == 1 ? ratings.first : nil))
        }
        add("Edit Track Details…", #selector(menuEdit), symbol: "pencil")
        add("Organize Files…", #selector(menuOrganize), symbol: "folder.badge.gearshape")
        add("Show in Finder", #selector(menuShowInFinder), symbol: "finder")
        menu.addItem(.separator())
        add("Move Tracks to Trash", #selector(menuTrash), symbol: "trash")
        add("Delete Tracks…", #selector(menuDelete), symbol: "xmark.bin")
    }

    @objc private func menuAppend() { env.actions.addToPlaylist(tracks(for: contextNodes), mode: .append) }
    @objc private func menuReplace() { env.actions.addToPlaylist(tracks(for: contextNodes), mode: .replace) }
    @objc private func menuPlay() { env.actions.addToPlaylist(tracks(for: contextNodes), mode: .appendAndPlay) }
    @objc private func menuQueue() { env.actions.addToPlaylist(tracks(for: contextNodes), mode: .queue) }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
    @objc private func menuEdit() { env.actions.editTrackDetails(tracks(for: contextNodes).map(\.track)) }
    @objc private func menuOrganize() { env.actions.organizeFiles(tracks(for: contextNodes).map(\.track)) }
    @objc private func menuShowInFinder() { env.actions.showInFinder(tracks(for: contextNodes).map(\.track.url)) }
    @objc private func menuTrash() { env.actions.moveToTrash(tracks(for: contextNodes).map(\.track)) }
    @objc private func menuDelete() { env.actions.deleteFiles(tracks(for: contextNodes).map(\.track)) }

    @objc func deleteSelection(_ sender: Any?) { env.actions.moveToTrash(tracks(for: selectedNodes).map(\.track)) }
}

/// Outline view with Return / middle-click / Delete handling.
final class CollectionOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onMiddleClick: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) } else { super.otherMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        // Single click on a group expands it (Amarok 3.3 behaviour).
        super.mouseDown(with: event)
        guard event.clickCount == 1, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) else { return }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let item = item(atRow: row), isExpandable(item), !isItemExpanded(item) { expandItem(item) }
    }
}

/// Collection row: optional cover / icon and text.
final class CollectionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CollectionCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    private var albumKey: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 2
        label.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 10)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [label, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        for v in [icon, texts] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(node: CollectionNode, settings: AppSettings, covers: CoverImageCache, isVariousArtists: Bool) {
        detail.isHidden = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        albumKey = nil
        switch node.kind {
        case .group(let g):
            label.stringValue = g.displayName
            label.toolTip = "\(g.displayName) — \(g.trackCount) track\(g.trackCount == 1 ? "" : "s")"
            if g.level == .album {
                if settings.bool(AppSettings.Key.showYears) && g.year > 0 { label.stringValue = "\(g.displayName) (\(g.year))" }
                if node.depth == 0, let artist = g.albumArtist, !artist.isEmpty {
                    detail.stringValue = artist
                    detail.isHidden = false
                }
                if settings.bool(AppSettings.Key.showCoverArt), let key = g.albumKey {
                    iconWidth.constant = 32
                    albumKey = key
                    icon.image = covers.image(albumKey: key, size: 32) { [weak self] image in
                        guard self?.albumKey == key else { return }
                        self?.icon.image = image ?? Self.placeholder
                    } ?? Self.placeholder
                    icon.contentTintColor = nil
                    return
                }
            }
            iconWidth.constant = 16
            icon.image = NSImage(systemSymbolName: Self.symbol(for: g.level), accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        case .track(let t):
            iconWidth.constant = 0
            icon.image = nil
            var text = t.track.displayTitle
            if settings.bool(AppSettings.Key.showTrackNumbers) && t.track.trackNumber > 0 {
                text = String(format: "%02d - ", t.track.trackNumber) + text
            }
            if isVariousArtists && settings.bool(AppSettings.Key.showArtistForVarious) && !t.track.artist.isEmpty {
                text += " - " + t.track.artist
            }
            label.stringValue = text
            label.toolTip = "\(t.track.displayTitle)\n\(t.track.displayArtist) — \(t.track.displayAlbum)\n\(TimeFormatting.durationMs(t.track.durationMs)) · \(t.track.format.uppercased())"
        case .disc(let n):
            iconWidth.constant = 12
            icon.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil)
            icon.contentTintColor = .tertiaryLabelColor
            label.stringValue = n > 0 ? "Disc \(n)" : "Disc"
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
    }

    /// Album without a cover: a soft tile with a faint disc, drawn per appearance.
    static let placeholder = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .light)
            .applying(.init(paletteColors: [.tertiaryLabelColor]))
        if let disc = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = disc.size
            disc.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        return true
    }

    static func symbol(for level: CollectionLevel) -> String {
        switch level {
        case .albumArtist, .artist: "person.fill"
        case .album: "opticaldisc"
        case .genre: "guitars"
        case .composer: "music.quarternote.3"
        case .label: "tag"
        case .year: "calendar"
        }
    }
}
