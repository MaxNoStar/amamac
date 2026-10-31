import AmamacBase
import AmamacModels
import AmamacPlaylist
import AppKit

/// Identifiers of the three dockable panes.
enum Pane: String, CaseIterable {
    case mediaSources, context, playlist

    var title: String {
        switch self {
        case .mediaSources: "Media Sources"
        case .context: "Context"
        case .playlist: "Playlist"
        }
    }

    /// Amarok's first-run proportions: 0.65 : 1.7 : 0.65.
    var defaultFraction: CGFloat {
        switch self {
        case .mediaSources, .playlist: 0.65 / 3
        case .context: 1.7 / 3
        }
    }
}

/// Wraps a pane's content and shows a title bar with Float / Close buttons when the layout is
/// unlocked (Amarok's dock title bars).
final class PaneViewController: NSViewController {
    let pane: Pane
    let content: NSViewController
    private let titleBar = PaneTitleBar()
    private var titleBarHeight: NSLayoutConstraint!
    var onClose: (() -> Void)?

    init(pane: Pane, content: NSViewController) {
        self.pane = pane
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.identifier = NSUserInterfaceItemIdentifier("pane.\(pane.rawValue)")
        addChild(content)
        let label = NSTextField(labelWithString: pane.title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(pane.title)")!,
                             target: self, action: #selector(closePane))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        for v in [label, close] {
            v.translatesAutoresizingMaskIntoConstraints = false
            titleBar.addSubview(v)
        }
        for v in [titleBar, content.view] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        titleBarHeight = titleBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBarHeight,
            label.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            content.view.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        titleBar.isHidden = true
        view = root
    }

    func setLocked(_ locked: Bool) {
        titleBar.isHidden = locked
        titleBarHeight.constant = locked ? 0 : 22
    }

    @objc private func closePane() { onClose?() }
}

/// Title strip shown above a pane while the layout is unlocked.
final class PaneTitleBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The main window: toolbar on top, Media Sources | Context | Playlist below.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    let env: AppEnvironment
    let toolbar = MainToolbarView()
    let slimToolbar = SlimToolbarView()
    let split = NSSplitViewController()
    private(set) var panes: [Pane: PaneViewController] = [:]
    private var items: [Pane: NSSplitViewItem] = [:]
    let mediaSources: MediaSourcesViewController
    let context: ContextPaneController
    let playlistPane: PlaylistPaneController
    private var refreshTimer: Timer?
    private var bookmarks: [TimeInterval] = []

    init(env: AppEnvironment) {
        self.env = env
        mediaSources = MediaSourcesViewController(env: env)
        context = ContextPaneController(env: env)
        playlistPane = PlaylistPaneController(env: env)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Amamac.appName
        window.minSize = NSSize(width: 860, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        buildContent()
        bindToolbar()
        window.setFrameAutosaveName("AmamacMainWindow")
        if !window.setFrameUsingName("AmamacMainWindow") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        let contentVC = NSViewController()
        let root = NSView()
        contentVC.view = root

        let paneControllers: [(Pane, NSViewController)] = [(.mediaSources, mediaSources), (.context, context), (.playlist, playlistPane)]
        for (pane, controller) in paneControllers {
            let wrapper = PaneViewController(pane: pane, content: controller)
            wrapper.onClose = { [weak self] in self?.setPane(pane, visible: false) }
            panes[pane] = wrapper
            let item = NSSplitViewItem(viewController: wrapper)
            item.canCollapse = true
            item.minimumThickness = pane == .context ? 260 : 200
            item.holdingPriority = pane == .context ? NSLayoutConstraint.Priority(250) : NSLayoutConstraint.Priority(260)
            items[pane] = item
            split.addSplitViewItem(item)
        }
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "AmamacPanes"
        contentVC.addChild(split)

        slimToolbar.isHidden = true
        for v in [toolbar, slimToolbar, split.view] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            slimToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            slimToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            slimToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        toolbarTop = split.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor)
        slimTop = split.view.topAnchor.constraint(equalTo: slimToolbar.bottomAnchor)
        toolbarTop.isActive = true
        window?.contentViewController = contentVC
        window?.setContentSize(NSSize(width: 1440, height: 900))

        let hidden = Set(env.settings.defaults.stringArray(forKey: AppSettings.Key.hiddenPanes) ?? [])
        for pane in Pane.allCases { items[pane]?.isCollapsed = hidden.contains(pane.rawValue) }
        applyLock(env.settings.bool(AppSettings.Key.lockLayout))
        setSlimToolbar(env.settings.bool(AppSettings.Key.slimToolbar))
        DispatchQueue.main.async { [weak self] in self?.applyDefaultWidthsIfNeeded() }
    }

    private var toolbarTop: NSLayoutConstraint!
    private var slimTop: NSLayoutConstraint!

    private func applyDefaultWidthsIfNeeded() {
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames AmamacPanes") == nil || LaunchOptions.current.isAutomation {
            resetPaneWidths()
        }
    }

    func resetPaneWidths() {
        let width = split.splitView.bounds.width
        guard width > 0 else { return }
        let first = (width * Pane.mediaSources.defaultFraction).rounded()
        let second = (width * (Pane.mediaSources.defaultFraction + Pane.context.defaultFraction)).rounded()
        split.splitView.setPosition(first, ofDividerAt: 0)
        split.splitView.setPosition(second, ofDividerAt: 1)
    }

    // MARK: View menu

    func isPaneVisible(_ pane: Pane) -> Bool { !(items[pane]?.isCollapsed ?? true) }

    func setPane(_ pane: Pane, visible: Bool) {
        items[pane]?.animator().isCollapsed = !visible
        var hidden = Set(env.settings.defaults.stringArray(forKey: AppSettings.Key.hiddenPanes) ?? [])
        if visible { hidden.remove(pane.rawValue) } else { hidden.insert(pane.rawValue) }
        env.settings.set(Array(hidden), AppSettings.Key.hiddenPanes)
    }

    func togglePane(_ pane: Pane) { setPane(pane, visible: !isPaneVisible(pane)) }

    func applyLock(_ locked: Bool) {
        for pane in panes.values { pane.setLocked(locked) }
    }

    func setSlimToolbar(_ slim: Bool) {
        toolbar.isHidden = slim
        slimToolbar.isHidden = !slim
        toolbarTop.isActive = !slim
        slimTop.isActive = slim
    }

    func resetLayout() {
        for pane in Pane.allCases { items[pane]?.isCollapsed = false }
        env.settings.set([String](), AppSettings.Key.hiddenPanes)
        env.settings.set(true, AppSettings.Key.lockLayout)
        applyLock(true)
        resetPaneWidths()
    }

    // MARK: Toolbar binding

    private func bindToolbar() {
        let player = env.player
        toolbar.playButton.target = self
        toolbar.playButton.action = #selector(playPause)
        toolbar.volumeDial.onChange = { player.setVolume($0) }
        toolbar.volumeDial.onToggleMute = { player.toggleMute() }
        toolbar.slider.onSeek = { player.seek(to: $0) }
        toolbar.slider.onMarkerClick = { player.seek(to: $0) }
        toolbar.carousel.onNext = { player.next() }
        toolbar.carousel.onPrevious = { player.previous() }
        toolbar.carousel.onCurrentClicked = { [weak self] in self?.playlistPane.scrollToActive() }
        toolbar.markerButton.target = self
        toolbar.markerButton.action = #selector(addPositionMarker(_:))
        toolbar.setTimeDisplayRemainingLeft(env.settings.bool(AppSettings.Key.timeDisplayRemaining))
        toolbar.onTimeDisplayToggled = { [weak self] in self?.env.settings.set($0, AppSettings.Key.timeDisplayRemaining) }
        slimToolbar.bind(player: player)

        player.addListener { [weak self] event in
            switch event {
            case .trackChanged, .stateChanged, .streamTitleChanged:
                self?.refreshTrackInfo()
            case .volumeChanged:
                self?.refreshVolume()
            case .seeked:
                self?.refreshTime()
            }
        }
        env.playlist.observe { [weak self] change in
            if change.isStructural || change == .queueChanged || change == .activeChanged { self?.refreshTrackInfo() }
        }
        env.proxy.onChange { [weak self] in self?.refreshTrackInfo() }
        NotificationCenter.default.addObserver(forName: BookmarkStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBookmarks() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
        refreshTrackInfo()
        refreshVolume()
    }

    private func label(for id: PlaylistItemID?) -> String? {
        guard let id, let item = env.playlist.item(id) else { return nil }
        return item.streamTitle ?? item.track.displayTitle
    }

    func refreshTrackInfo() {
        let player = env.player
        let nav = env.navigator
        let item = player.currentItem ?? env.playlist.activeItem
        var labels = TrackLabelCarousel.Labels(currentTitle: "Rediscover Your Music")
        if let item, player.isActive || env.playlist.activeItem != nil {
            let t = item.track
            labels.currentTitle = item.streamTitle ?? t.displayTitle
            var detail: [String] = []
            if item.isStream {
                if item.streamTitle != nil { detail.append("on \(t.displayTitle)") }
            } else {
                if !t.artist.isEmpty { detail.append("by \(t.artist)") } else if !t.composer.isEmpty { detail.append("by \(t.composer)") }
                if !t.album.isEmpty { detail.append("on \(t.album)") }
            }
            labels.currentDetail = detail.joined(separator: " ")
            labels.currentID = item.id
            let prev = nav.peekPrevious()
            let next = nav.nextIgnoringStopAfter()
            labels.previous = prev == item.id ? nil : label(for: prev)
            labels.previousID = prev
            labels.next = next == item.id && nav.progression != .repeatTrack ? nil : label(for: next)
            labels.nextID = next
            window?.title = item.isStream ? labels.currentTitle : [labels.currentTitle, t.artist].filter { !$0.isEmpty }.joined(separator: " – ")
        } else {
            window?.title = Amamac.appName
        }
        toolbar.carousel.labels = labels
        toolbar.playButton.isPlaying = player.state == .playing || player.state == .buffering
        slimToolbar.refresh()
        refreshBookmarks()
        refreshTime()
    }

    func refreshTime() {
        let player = env.player
        toolbar.updateTime(position: player.currentTime, duration: player.duration, active: player.isActive)
        slimToolbar.refreshTime()
    }

    func refreshVolume() {
        toolbar.volumeDial.volume = env.player.volume
        toolbar.volumeDial.isMuted = env.player.isMuted
        slimToolbar.refresh()
    }

    func refreshBookmarks() {
        guard let trackId = env.player.currentItem?.track.id else {
            toolbar.slider.markers = []
            return
        }
        toolbar.slider.markers = BookmarkStore(database: env.database).positions(trackId: trackId)
    }

    @objc func playPause() { env.player.playPause() }

    @objc func addPositionMarker(_ sender: Any?) {
        guard let item = env.player.currentItem, let trackId = item.track.id, env.player.isActive else { return }
        BookmarkStore(database: env.database).addPosition(trackId: trackId, title: item.track.displayTitle, position: env.player.currentTime)
    }

    // MARK: NSWindowDelegate

    private lazy var playlistUndoManager = PlaylistUndoManager(model: env.playlist)

    /// Edit › Undo undoes text edits first, then playlist edits.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { playlistUndoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the main window hides it; the app keeps playing (Amarok behaviour with tray icon).
        sender.orderOut(nil)
        return false
    }
}

/// The main window's undo manager. Text fields register their edits here as usual; when there is
/// nothing of theirs to undo, Undo / Redo act on the playlist (Amarok's playlist undo).
final class PlaylistUndoManager: UndoManager {
    private weak var model: PlaylistModel?

    init(model: PlaylistModel) {
        self.model = model
        super.init()
    }

    override var canUndo: Bool { super.canUndo || (model?.canUndo ?? false) }
    override var canRedo: Bool { super.canRedo || (model?.canRedo ?? false) }

    override func undo() {
        if super.canUndo { super.undo() } else { model?.undo() }
    }

    override func redo() {
        if super.canRedo { super.redo() } else { model?.redo() }
    }

    override var undoMenuItemTitle: String { super.canUndo ? super.undoMenuItemTitle : "Undo Playlist Change" }
    override var redoMenuItemTitle: String { super.canRedo ? super.redoMenuItemTitle : "Redo Playlist Change" }
}
