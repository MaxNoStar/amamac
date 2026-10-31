import AmamacBase
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// A playlist item UUID string (one per dragged row; internal reordering).
    static let amamacPlaylistItems = NSPasteboard.PasteboardType("local.amamac.playlist-item")
}

/// The right "Playlist" pane: sort breadcrumb, progressive search, the album-grouped table and
/// the bottom bar.
final class PlaylistPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                    NSMenuItemValidation {
    let env: AppEnvironment
    var model: PlaylistModel { env.playlist }
    var proxy: PlaylistProxy { env.proxy }

    let table = PlaylistTableView()
    private let scroll = NSScrollView()
    let sortBar = SortBreadcrumbBar()
    let searchBar = ProgressiveSearchBar()
    let bottomBar = PlaylistBottomBar()

    private(set) var layout: PlaylistLayout = .default
    /// Per visible row: how it renders, its index in its group, and the group's first row.
    private var kinds: [PlaylistRowKind] = []
    private var groupStart: [Int] = []
    private var groupStats: [Int: (count: Int, length: TimeInterval)] = [:]
    private var searchMatches: Set<PlaylistItemID> = []
    private var searchText = ""
    private var observation: PlaylistObservation?
    private var reloadScheduled = false

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.identifier = NSUserInterfaceItemIdentifier("playlistPane")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.backgroundColor = .controlBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([.amamacPlaylistItems, .amamacTracks, .fileURL, .URL, .string])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("playlistTable")
        table.setAccessibilityLabel("Playlist")
        table.onReturn = { [weak self] in self?.playSelected() }
        table.onDelete = { [weak self] in self?.removeSelected(nil) }
        table.onHeaderClick = { [weak self] row, extend in self?.selectGroup(containing: row, extend: extend) }
        table.headRectProvider = { [weak self] row in self?.headRect(forRow: row) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder

        let banner = NSHostingView(rootView: DynamicModeBanner(mode: env.dynamicMode))
        banner.sizingOptions = [.intrinsicContentSize]
        banner.safeAreaRegions = []
        for v in [sortBar, searchBar, banner, scroll, bottomBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sortBar.topAnchor.constraint(equalTo: root.topAnchor),
            sortBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sortBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: sortBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            banner.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        bindBars()
        applyLayout(named: env.settings.string(AppSettings.Key.playlistLayout) ?? PlaylistLayout.default.name)
        proxy.onChange { [weak self] in self?.scheduleReload() }
        observation = model.observe { [weak self] change in
            switch change {
            case .activeChanged, .queueChanged, .stopAfterChanged: self?.refreshVisibleRows()
            default: break
            }
            if change.isStructural || change == .activeChanged || change == .queueChanged { self?.updateSummary() }
        }
        env.player.addListener { [weak self] event in
            if event == .stateChanged || event == .trackChanged { self?.refreshVisibleRows() }
        }
        NotificationCenter.default.addObserver(forName: AppEnvironment.coverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleRows() }
        }
        reload()
    }

    // MARK: Layout

    func applyLayout(named name: String) {
        layout = PlaylistLayout.builtIn.first { $0.name == name } ?? .default
        proxy.grouping = layout.grouping
        env.settings.set(layout.name, AppSettings.Key.playlistLayout)
        reload()
    }

    private func recomputeRows() {
        let count = proxy.count
        kinds = Array(repeating: .single, count: count)
        groupStart = Array(repeating: 0, count: count)
        groupStats = [:]
        guard count > 0 else { return }
        let heads = proxy.groupHeads
        var start = 0
        var length: TimeInterval = 0
        func close(_ end: Int) {
            let size = end - start
            groupStats[start] = (size, length)
            if layout.grouping != .none && size > 1 {
                kinds[start] = .head
                for r in (start + 1)..<end { kinds[r] = .body }
            }
        }
        for row in 0..<count {
            if row > 0 && (layout.grouping == .none || heads[row]) {
                close(row)
                start = row
                length = 0
            }
            groupStart[row] = start
            length += proxy.item(at: row)?.duration ?? 0
        }
        close(count)
    }

    private func headRect(forRow row: Int) -> NSRect? {
        guard row >= 0, row < kinds.count, kinds[row] == .head else { return nil }
        return NSRect(x: 0, y: 0, width: table.bounds.width, height: PlaylistMetrics.headHeight(layout))
    }

    // MARK: Reloading

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    /// Full reload, keeping selection (by item) and the scroll position.
    func reload() {
        guard isViewLoaded else { return }
        let selectedIDs = table.selectedRowIndexes.compactMap { proxy.item(at: $0)?.id }
        let origin = scroll.contentView.bounds.origin
        recomputeRows()
        if !searchText.isEmpty { updateSearchMatches() }
        table.reloadData()
        let rows = IndexSet(selectedIDs.compactMap { proxy.row(of: $0) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateSummary()
        updateButtons()
    }

    /// Redraws visible rows after state changes (active track, queue, ratings) without reloading.
    func refreshVisibleRows() {
        guard isViewLoaded else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? PlaylistRowView {
                rowView.model = rowModel(row)
            }
        }
        updateButtons()
    }

    private func updateSummary() {
        let total = model.count
        let duration = model.totalDuration
        var text = "\(total) \(total == 1 ? "track" : "tracks") (\(TimeFormatting.duration(duration)))"
        if proxy.count != total { text = "\(proxy.count) of " + text }
        bottomBar.summary.stringValue = text
        let queued = model.queue.count
        bottomBar.summary.toolTip = queued == 0 ? "Total size: " + ByteCountFormatter.string(fromByteCount: model.totalFileSize, countStyle: .file)
            : "Queue: \(queued) \(queued == 1 ? "track" : "tracks") (\(TimeFormatting.duration(model.queueDuration)))"
    }

    private func updateButtons() {
        bottomBar.undo.isEnabled = model.canUndo
        bottomBar.redo.isEnabled = model.canRedo
        bottomBar.clear.isEnabled = !model.isEmpty
        bottomBar.showActive.isEnabled = model.activeID != nil
        bottomBar.progression.image = NSImage(systemSymbolName: env.navigator.progression.symbolName,
                                              accessibilityDescription: env.navigator.progression.displayName)
        bottomBar.progression.toolTip = "Track Progression: " + env.navigator.progression.displayName
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { proxy.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        PlaylistMetrics.height(kind: row < kinds.count ? kinds[row] : .single, layout: layout)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: PlaylistRowView.identifier, owner: nil) as? PlaylistRowView) ?? {
            let v = PlaylistRowView()
            v.identifier = PlaylistRowView.identifier
            return v
        }()
        view.model = rowModel(row)
        if let item = view.model?.item {
            view.setAccessibilityLabel([item.track.displayTitle, item.track.displayArtist, item.track.displayAlbum]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        }
        return view
    }

    private func rowModel(_ row: Int) -> PlaylistRowModel? {
        guard let item = proxy.item(at: row), row < kinds.count else { return nil }
        let kind = kinds[row]
        let start = groupStart[row]
        let stats = groupStats[start] ?? (1, item.duration)
        var cover: NSImage?
        if layout.showCover && (kind == .head || (kind == .single && layout.single.count > 1)) && !item.isStream {
            let id = item.id
            cover = env.coverImages.image(albumKey: item.albumKey, size: 48) { [weak self] image in
                guard image != nil, let self, let row = self.proxy.row(of: id),
                      let view = self.table.rowView(atRow: row, makeIfNecessary: false) as? PlaylistRowView else { return }
                view.model = self.rowModel(row)
            }
        }
        return PlaylistRowModel(item: item, kind: kind, layout: layout,
                                isActive: item.id == (env.player.isActive ? env.player.currentItem?.id : nil) ?? model.activeID,
                                playerState: env.player.state,
                                queuePosition: model.queuePosition(item.id),
                                isStopAfter: model.stopAfterID == item.id,
                                isSearchMatch: !searchBar.showOnlyMatches && searchMatches.contains(item.id),
                                indexInGroup: kind == .single && layout.grouping == .none ? row : row - start,
                                groupTrackCount: stats.count, groupLength: stats.length, cover: cover)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshVisibleRows()
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = proxy.item(at: row) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(item.id.description, forType: .amamacPlaylistItems)
        if item.url.isFileURL {
            pb.setString(item.url.absoluteString, forType: .fileURL)
        } else {
            pb.setString(item.url.absoluteString, forType: .URL)
        }
        return pb
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        let pb = info.draggingPasteboard
        if (info.draggingSource as? NSTableView) === table {
            // Reordering only makes sense when rows show the source order.
            return proxy.isIdentity ? .move : []
        }
        if pb.availableType(from: [.amamacTracks]) != nil { return .copy }
        if pb.canReadObject(forClasses: [NSURL.self], options: nil) { return .copy }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        let destination = proxy.sourceIndex(forRow: row)
        if (info.draggingSource as? NSTableView) === table {
            let ids = (pb.pasteboardItems ?? []).compactMap { item -> PlaylistItemID? in
                item.string(forType: .amamacPlaylistItems).flatMap(UUID.init(uuidString:)).map(PlaylistItemID.init(rawValue:))
            }
            guard proxy.isIdentity, !ids.isEmpty else { return false }
            model.move(ids, to: destination)
            let rows = IndexSet(ids.compactMap { proxy.row(of: $0) })
            DispatchQueue.main.async { self.table.selectRowIndexes(rows, byExtendingSelection: false) }
            return true
        }
        let tracks = Commands.tracks(fromPasteboard: pb)
        if !tracks.isEmpty {
            Commands.addToPlaylist(tracks, mode: .append, at: destination)
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            Commands.addURLs(urls, mode: .append, at: destination)
            return true
        }
        return false
    }

    // MARK: Selection helpers

    var selectedIDs: [PlaylistItemID] {
        table.selectedRowIndexes.compactMap { proxy.item(at: $0)?.id }
    }

    /// Rows the context menu acts on: the clicked row, or the selection when it was clicked.
    private var contextIDs: [PlaylistItemID] {
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) {
            return proxy.item(at: clicked).map { [$0.id] } ?? []
        }
        return selectedIDs
    }

    private func selectGroup(containing row: Int, extend: Bool) {
        let range = proxy.groupRange(containing: row)
        table.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: extend)
        view.window?.makeFirstResponder(table)
    }

    func scrollToActive() {
        guard let id = env.player.currentItem?.id ?? model.activeID, let row = proxy.row(of: id) else { return }
        // Centre the active row.
        let rect = table.rect(ofRow: row)
        let visible = scroll.contentView.bounds
        let y = min(max(0, rect.midY - visible.height / 2), max(0, table.bounds.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        // On a group header the clicked row is the group's first track, so this plays the album.
        let row = table.clickedRow
        guard row >= 0, let item = proxy.item(at: row) else { return }
        env.player.play(item.id)
    }

    func playSelected() {
        guard let first = table.selectedRowIndexes.first, let item = proxy.item(at: first) else { return }
        env.player.play(item.id)
    }

    @objc func removeSelected(_ sender: Any?) {
        let ids = Set(sender is NSMenuItem ? contextIDs : selectedIDs)
        guard !ids.isEmpty else { return }
        let firstRow = table.selectedRowIndexes.first ?? 0
        model.remove(ids)
        DispatchQueue.main.async {
            let row = min(firstRow, self.proxy.count - 1)
            if row >= 0 { self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    @objc func clearPlaylist(_ sender: Any?) { model.clear() }
    @objc func undoPlaylist(_ sender: Any?) { model.undo() }
    @objc func redoPlaylist(_ sender: Any?) { model.redo() }
    @objc func showActiveTrack(_ sender: Any?) { scrollToActive() }

    @objc func shufflePlaylist(_ sender: Any?) {
        var rng = SystemRandomNumberGenerator()
        model.shuffle(using: &rng)
    }

    @objc func queueSelected(_ sender: Any?) {
        model.toggleQueue(sender is NSMenuItem ? contextIDs : selectedIDs)
    }

    @objc func stopAfterSelected(_ sender: Any?) {
        guard let id = (sender is NSMenuItem ? contextIDs : selectedIDs).first else { return }
        model.setStopAfter(model.stopAfterID == id ? nil : id)
    }

    @objc func removeDuplicatesAndDead(_ sender: Any?) {
        let removed = model.removeDuplicatesAndDead { url in !url.isFileURL || FileManager.default.fileExists(atPath: url.path) }
        env.status.showMessage(removed == 0 ? "No duplicate or dead entries found."
                                            : "Removed \(removed) \(removed == 1 ? "entry" : "entries").")
    }

    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(searchBar.field)
    }

    @objc private func playContext() {
        if let id = contextIDs.first { env.player.play(id) }
    }

    @objc private func editContext() {
        Commands.editTrackDetails(contextIDs.compactMap { model.item($0) }.filter { $0.source != .stream }.map(\.track))
    }

    @objc private func organizeContext() {
        Commands.organizeFiles(contextIDs.compactMap { model.item($0) }.filter { $0.source == .collection }.map(\.track))
    }

    @objc private func showInFinderContext() {
        Commands.showInFinder(contextIDs.compactMap { model.item($0)?.url })
    }

    @objc private func copyContext() {
        let items = contextIDs.compactMap { model.item($0) }
        let text = items.map { item in
            [item.track.displayArtist, item.streamTitle ?? item.track.displayTitle].filter { !$0.isEmpty }.joined(separator: " - ")
        }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func copy(_ sender: Any?) { copyContext() }

    @objc private func showAlbumInMediaSources() {
        guard let item = contextIDs.first.flatMap({ model.item($0) }), !item.isStream else { return }
        let query = "album:\"\(item.track.album)\""
        AppDelegate.shared?.showInCollection(filter: query)
    }

    @objc private func showArtistInMediaSources() {
        guard let item = contextIDs.first.flatMap({ model.item($0) }), !item.isStream else { return }
        AppDelegate.shared?.showInCollection(filter: "artist:\"\(item.track.artist)\"")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        menu.removeAllItems()
        let ids = contextIDs
        guard !ids.isEmpty else { return }
        func add(_ title: String, _ action: Selector, _ symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Play", #selector(playContext), "play")
        let allQueued = ids.allSatisfy(model.isQueued)
        add(allQueued ? "Dequeue Track" : "Queue Track", #selector(queueSelected(_:)), allQueued ? "minus.circle" : "list.number")
        if ids.count == 1 {
            add(model.stopAfterID == ids[0] ? "Stop Playing After This Track ✓" : "Stop Playing After This Track",
                #selector(stopAfterSelected(_:)), "stop.circle")
        }
        add("Remove From Playlist", #selector(removeSelected(_:)), "minus")
        menu.addItem(.separator())
        let collectionItems = ids.compactMap { model.item($0) }.filter { $0.source == .collection && $0.track.id != nil }
        if !collectionItems.isEmpty {
            let ratings = Set(collectionItems.map { $0.statistics?.rating ?? 0 })
            menu.addItem(Commands.ratingMenuItem(trackIds: collectionItems.compactMap(\.track.id),
                                                 current: ratings.count == 1 ? ratings.first : nil))
        }
        add("Edit Track Details…", #selector(editContext), "pencil")
        add("Show in Finder", #selector(showInFinderContext), "finder")
        if !collectionItems.isEmpty { add("Organize Files…", #selector(organizeContext), "folder.badge.gearshape") }
        if ids.count == 1, let item = model.item(ids[0]), item.source == .collection {
            add("Show Album in Media Sources", #selector(showAlbumInMediaSources), "square.stack")
            add("Show Artist in Media Sources", #selector(showArtistInMediaSources), "music.mic")
        }
        menu.addItem(.separator())
        add("Copy Track Information", #selector(copyContext), "doc.on.doc")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(removeSelected(_:)), #selector(queueSelected(_:)), #selector(copy(_:)):
            return menuItem.menu === table.menu ? true : !table.selectedRowIndexes.isEmpty
        case #selector(stopAfterSelected(_:)):
            return menuItem.menu === table.menu || table.selectedRowIndexes.count == 1
        case #selector(clearPlaylist(_:)), #selector(shufflePlaylist(_:)), #selector(removeDuplicatesAndDead(_:)):
            return !model.isEmpty
        case #selector(undoPlaylist(_:)): return model.canUndo
        case #selector(redoPlaylist(_:)): return model.canRedo
        case #selector(showActiveTrack(_:)): return model.activeID != nil || env.player.currentItem != nil
        default: return true
        }
    }

    // MARK: Bars

    private func bindBars() {
        sortBar.levels = proxy.sortLevels
        sortBar.onChange = { [weak self] levels in self?.proxy.sortLevels = levels }
        sortBar.onReshuffle = { [weak self] in self?.proxy.shuffleSeed = UInt64.random(in: 1...UInt64.max) }

        searchBar.fields = PlaylistSearchFields(rawValue: env.settings.int(AppSettings.Key.playlistSearchFields))
        searchBar.onSearch = { [weak self] text in self?.search(text) }
        searchBar.onNext = { [weak self] in self?.jumpToMatch(forward: true) }
        searchBar.onPrevious = { [weak self] in self?.jumpToMatch(forward: false) }
        searchBar.onOptionsChanged = { [weak self] in
            guard let self else { return }
            self.env.settings.set(self.searchBar.fields.rawValue, AppSettings.Key.playlistSearchFields)
            self.search(self.searchText, force: true)
        }

        let b = bottomBar
        b.clear.target = self
        b.clear.action = #selector(clearPlaylist(_:))
        b.undo.target = self
        b.undo.action = #selector(undoPlaylist(_:))
        b.redo.target = self
        b.redo.action = #selector(redoPlaylist(_:))
        b.showActive.target = self
        b.showActive.action = #selector(showActiveTrack(_:))
        b.save.target = self
        b.save.action = #selector(showSaveMenu(_:))
        b.progression.target = self
        b.progression.action = #selector(showProgressionMenu(_:))
    }

    @objc private func showSaveMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let save = NSMenuItem(title: "Save Playlist…", action: #selector(AppDelegate.savePlaylist(_:)), keyEquivalent: "")
        let export = NSMenuItem(title: "Export Playlist As…", action: #selector(AppDelegate.exportPlaylist(_:)), keyEquivalent: "")
        menu.addItem(save)
        menu.addItem(export)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func showProgressionMenu(_ sender: NSButton) {
        let menu = AppDelegate.makeProgressionMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    func progressionChanged() { updateButtons() }

    // MARK: Search

    private func search(_ text: String, force: Bool = false) {
        guard text != searchText || force else { return }
        searchText = text
        let fields = searchBar.fields
        if searchBar.showOnlyMatches && !text.isEmpty {
            searchMatches = []
            proxy.filter = PlaylistSearch(text: text, fields: fields)
            searchBar.hasNoMatch = proxy.count == 0
            return
        }
        proxy.filter = nil
        updateSearchMatches()
        searchBar.hasNoMatch = !text.isEmpty && searchMatches.isEmpty
        refreshVisibleRows()
        if !text.isEmpty { jumpToMatch(forward: true, includeCurrent: true) }
    }

    private func updateSearchMatches() {
        guard !searchText.isEmpty, !searchBar.showOnlyMatches else {
            searchMatches = []
            return
        }
        let search = PlaylistSearch(text: searchText, fields: searchBar.fields)
        searchMatches = Set(proxy.matchingRows(search).compactMap { proxy.item(at: $0)?.id })
    }

    private func jumpToMatch(forward: Bool, includeCurrent: Bool = false) {
        guard !searchText.isEmpty else { return }
        let rows = proxy.matchingRows(PlaylistSearch(text: searchText, fields: searchBar.fields))
        guard !rows.isEmpty else { return }
        let current = table.selectedRow
        let target: Int
        if forward {
            target = rows.first { includeCurrent ? $0 >= current : $0 > current } ?? rows[0]
        } else {
            target = rows.last { $0 < current } ?? rows[rows.count - 1]
        }
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        table.scrollRowToVisible(target)
    }
}

/// Playlist table with keyboard handling and album-header clicks.
final class PlaylistTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHeaderClick: ((Int, Bool) -> Void)?
    var headRectProvider: ((Int) -> NSRect?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, event.clickCount == 1, let head = headRectProvider?(row) {
            let local = NSPoint(x: point.x, y: point.y - rect(ofRow: row).minY)
            if head.contains(local) {
                onHeaderClick?(row, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click plays the clicked track.
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, event.buttonNumber == 2 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onReturn?()
            return
        }
        super.otherMouseDown(with: event)
    }

    override func drawGrid(inClipRect clipRect: NSRect) {}
}

extension PlaylistRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PlaylistRow")
}
