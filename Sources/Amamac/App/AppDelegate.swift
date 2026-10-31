import AppKit
import AmamacCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static private(set) weak var shared: AppDelegate?

    private(set) var env: AppEnvironment!
    private(set) var mainWindow: MainWindowController!
    private(set) var desktop: DesktopIntegration?
    private var sessionSaveScheduled = false
    private var nowPlayingArtworkKey: String?
    private var nowPlayingArtwork: NSImage?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.current
        let dataDir = options.dataDir ?? AppEnvironment.defaultDataDirectory()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let defaults: UserDefaults
        if options.isAutomation || options.dataDir != nil {
            // Automation and alternate data directories never touch the user's preferences.
            let suite = "local.amamac.automation"
            UserDefaults().removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }
        do {
            env = try AppEnvironment(dataDirectory: dataDir, defaults: defaults,
                                     httpConfiguration: options.snapshotDir != nil ? SnapshotRunner.stubNetwork() : .ephemeral)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Amamac could not open its collection database."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        AppEnvironment.shared = env
        _ = env.equalizer
        if options.snapshotDir != nil { env.settings.enabledApplets = AppletKind.allCases.map(\.rawValue) }
        NSApp.mainMenu = MainMenu.build()
        mainWindow = MainWindowController(env: env)

        if let perfOutput = options.perfOutput {
            PerfRunner(env: env, window: mainWindow, output: perfOutput).run()
            return
        }
        if let snapshotDir = options.snapshotDir {
            SnapshotRunner(env: env, window: mainWindow, output: snapshotDir, layoutDump: options.dumpLayout).run()
            return
        }

        mainWindow.showWindow(nil)
        desktop = DesktopIntegration(env: env, mainWindow: mainWindow)
        setUpNowPlaying()
        observeSession()
        restoreSession()
        env.podcasts.startAutoUpdate()
        if env.collectionFolders.isEmpty && !env.settings.bool(AppSettings.Key.firstRunDone) {
            DispatchQueue.main.async { self.runFirstRunSetup() }
        } else {
            env.scanCollection()
            env.startWatching()
        }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard env != nil, LaunchOptions.current.snapshotDir == nil else { return }
        saveSession()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { Commands.addURLs(files, mode: .appendAndPlay) }
        for url in urls where url.scheme?.lowercased() == "amamac" { LinkHandler.open(url) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let item = env.player.currentItem, env.player.isActive {
            let title = NSMenuItem(title: [item.streamTitle ?? item.track.displayTitle, item.track.artist]
                .filter { !$0.isEmpty }.joined(separator: " – "), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let playing = env.player.state == .playing || env.player.state == .buffering
        menu.addItem(withTitle: playing ? "Pause" : "Play", action: #selector(playPause(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Next Track", action: #selector(nextTrack(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Previous Track", action: #selector(previousTrack(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: First run

    private func runFirstRunSetup() {
        env.settings.set(true, AppSettings.Key.firstRunDone)
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let alert = NSAlert()
        alert.messageText = "Where is your music?"
        alert.informativeText = "Amamac builds its collection from the folders you choose. You can change them later with Tools › Collection Folders."
        alert.addButton(withTitle: "Use \(music.lastPathComponent) Folder")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            env.setCollectionFolders([music.path])
            env.scanCollection()
        case .alertSecondButtonReturn:
            chooseCollectionFolders(nil)
        default:
            break
        }
    }

    @objc func chooseCollectionFolders(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use as Collection"
        panel.message = "Choose the folders that make up your collection. Folders already in the collection: " +
            (env.collectionFolders.map(\.path).joined(separator: ", ").nilIfEmpty ?? "none")
        guard panel.runModal() == .OK else { return }
        let paths = env.collectionFolders.map(\.path) + panel.urls.map(\.path)
        env.setCollectionFolders(Array(NSOrderedSet(array: paths)) as? [String] ?? paths)
        env.scanCollection()
    }

    @objc func removeCollectionFolders(_ sender: Any?) {
        let folders = env.collectionFolders
        guard !folders.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all collection folders?"
        alert.informativeText = folders.map(\.path).joined(separator: "\n") +
            "\n\nTracks stay on disk; their statistics are kept until the next full rescan."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        env.setCollectionFolders([])
    }

    // MARK: Now Playing / remote commands

    private func setUpNowPlaying() {
        SystemMediaControls.registerRemoteCommands { command in
            Task { @MainActor in AppEnvironment.shared.player.handle(command) }
        }
        env.player.addListener { [weak self] _ in self?.updateNowPlaying() }
        NotificationCenter.default.addObserver(forName: AppEnvironment.coverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nowPlayingArtworkKey = nil
                self?.updateNowPlaying()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateNowPlaying() }
        }
    }

    private func updateNowPlaying() {
        let player = env.player
        guard let item = player.currentItem, player.isActive else {
            SystemMediaControls.update(nil, artwork: nil)
            return
        }
        let info = SystemMediaControls.Info(title: item.streamTitle ?? item.track.displayTitle, artist: item.track.artist,
                                            album: item.isStream ? item.track.displayTitle : item.track.album,
                                            duration: player.duration > 0 ? player.duration : nil,
                                            elapsed: player.currentTime, playing: player.state == .playing,
                                            isLiveStream: item.isStream && player.duration == 0)
        let key = item.albumKey
        if key != nowPlayingArtworkKey {
            nowPlayingArtworkKey = key
            nowPlayingArtwork = nil
            if !item.isStream {
                nowPlayingArtwork = env.coverImages.image(albumKey: key, size: 300) { [weak self] image in
                    guard let self, self.nowPlayingArtworkKey == key else { return }
                    self.nowPlayingArtwork = image
                    self.updateNowPlaying()
                }
            }
        }
        SystemMediaControls.update(info, artwork: nowPlayingArtwork)
    }

    // MARK: Session

    private func observeSession() {
        env.playlist.observe { [weak self] _ in self?.scheduleSessionSave() }
        env.player.addListener { [weak self] event in
            if event == .trackChanged || event == .stateChanged { self?.scheduleSessionSave() }
        }
    }

    private func scheduleSessionSave() {
        guard !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sessionSaveScheduled = false
            self?.saveSession()
        }
    }

    func saveSession() {
        let player = env.player
        let session = PlaylistLoader.Session(model: env.playlist,
                                             position: player.isActive ? player.currentTime : nil,
                                             wasPlaying: player.state == .playing || player.state == .buffering)
        try? PlaylistLoader.saveSession(session, database: env.database)
    }

    private func restoreSession() {
        guard let session = PlaylistLoader.loadSession(database: env.database), !session.entries.isEmpty else { return }
        let database = env.database
        Task {
            let items = await PlaylistLoader.items(for: session, database: database)
            env.playlist.restore(items: items, activeID: session.activeID.map(PlaylistItemID.init(rawValue:)),
                                 queue: session.queue.map(PlaylistItemID.init(rawValue:)),
                                 stopAfterID: session.stopAfterID.map(PlaylistItemID.init(rawValue:)))
            if env.settings.bool(AppSettings.Key.resumePlayback), session.wasPlaying, let active = env.playlist.activeID {
                env.player.play(active, startAt: session.position ?? 0)
            }
            mainWindow.playlistPane.scrollToActive()
            env.dynamicMode.resumeIfNeeded()
        }
    }

    // MARK: Playback menu

    @objc func playPause(_ sender: Any?) { env.player.playPause() }
    @objc func stopPlayback(_ sender: Any?) { env.player.stop() }
    @objc func nextTrack(_ sender: Any?) { env.player.next() }
    @objc func previousTrack(_ sender: Any?) { env.player.previous() }
    @objc func toggleStopAfterCurrent(_ sender: Any?) { env.player.toggleStopAfterCurrent() }
    @objc func volumeUp(_ sender: Any?) { env.player.setVolume(env.player.volume + 5) }
    @objc func volumeDown(_ sender: Any?) { env.player.setVolume(env.player.volume - 5) }
    @objc func toggleMute(_ sender: Any?) { env.player.toggleMute() }

    @objc func seekForward(_ sender: NSMenuItem) { env.player.seek(by: Double(env.settings.int(seekKey(sender.tag)))) }
    @objc func seekBackward(_ sender: NSMenuItem) { env.player.seek(by: -Double(env.settings.int(seekKey(sender.tag)))) }

    private func seekKey(_ tag: Int) -> String {
        switch tag {
        case 0: AppSettings.Key.seekShort
        case 2: AppSettings.Key.seekLong
        default: AppSettings.Key.seekMedium
        }
    }

    @objc func setReplayGainMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ReplayGainMode(rawValue: raw) else { return }
        env.settings.replayGainMode = mode
    }

    @objc func playMedia(_ sender: Any?) {
        guard let urls = runMediaOpenPanel(prompt: "Play") else { return }
        Commands.addURLs(urls, mode: .appendAndPlay)
    }

    // MARK: Playlist menu

    @objc func addMedia(_ sender: Any?) {
        guard let urls = runMediaOpenPanel(prompt: "Add") else { return }
        Commands.addURLs(urls, mode: .append)
    }

    @objc func addStream(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Stream"
        alert.informativeText = "Enter the address of an internet radio stream or a playlist (.m3u, .pls)."
        let field = NSTextField(string: "")
        field.placeholderString = "https://"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            env.status.showMessage("“\(text)” is not a valid stream address.")
            return
        }
        Commands.add([PlaylistItem.stream(url: url, title: nil)], mode: .append)
    }

    private func runMediaOpenPanel(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.allowedContentTypes = [.audio, .folder] + PlaylistFileFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    @objc func savePlaylist(_ sender: Any?) {
        guard !env.playlist.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Save Playlist"
        alert.informativeText = "Saved playlists appear under Media Sources › Playlists."
        let field = NSTextField(string: defaultPlaylistName())
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? defaultPlaylistName()
        do {
            try SavedPlaylistStore(database: env.database).save(name: name, items: env.playlist.items)
            env.status.showMessage("Saved playlist “\(name)”.")
        } catch {
            env.status.showMessage("Could not save the playlist: \(error.localizedDescription)")
        }
    }

    private func defaultPlaylistName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Playlist " + formatter.string(from: Date())
    }

    @objc func exportPlaylist(_ sender: Any?) {
        guard !env.playlist.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Playlist.m3u8"
        panel.allowedContentTypes = PlaylistFileFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let entries = env.playlist.items.map { item in
            PlaylistFileEntry(url: item.url, title: item.streamTitle ?? item.track.title, artist: item.track.artist,
                              album: item.track.album, durationMs: item.track.durationMs,
                              trackNumber: item.track.trackNumber > 0 ? item.track.trackNumber : nil)
        }
        do {
            try PlaylistFile.write(entries, to: url)
            env.status.showMessage("Exported \(entries.count) tracks to \(url.lastPathComponent).")
        } catch {
            env.status.showMessage("Could not export the playlist: \(error.localizedDescription)")
        }
    }

    @objc func setTrackProgression(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TrackProgression(rawValue: raw) else { return }
        env.navigator.progression = mode
        env.settings.trackProgression = mode
        env.player.updateUpcoming()
        mainWindow.playlistPane.progressionChanged()
        mainWindow.refreshTrackInfo()
    }

    @objc func setFavorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FavorMode(rawValue: raw) else { return }
        env.navigator.favor = mode
        env.settings.favor = mode
        env.player.updateUpcoming()
        mainWindow.refreshTrackInfo()
    }

    @objc func setPlaylistLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        mainWindow.playlistPane.applyLayout(named: name)
    }

    static func makeProgressionMenu() -> NSMenu {
        let menu = NSMenu(title: "Track Progression")
        for mode in TrackProgression.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setTrackProgression(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
            if mode == .onlyQueue || mode == .repeatPlaylist { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let favor = NSMenuItem(title: "Favor", action: nil, keyEquivalent: "")
        let favorMenu = NSMenu(title: "Favor")
        for mode in FavorMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setFavorMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            favorMenu.addItem(item)
        }
        favor.submenu = favorMenu
        menu.addItem(favor)
        return menu
    }

    // Playlist actions are forwarded so they work wherever the focus is.
    @objc func clearPlaylist(_ sender: Any?) { env.playlist.clear() }
    @objc func shufflePlaylist(_ sender: Any?) { mainWindow.playlistPane.shufflePlaylist(sender) }
    @objc func removeDuplicatesAndDead(_ sender: Any?) { mainWindow.playlistPane.removeDuplicatesAndDead(sender) }
    @objc func queueSelected(_ sender: Any?) { mainWindow.playlistPane.queueSelected(nil) }
    @objc func searchPlaylist(_ sender: Any?) {
        if !mainWindow.isPaneVisible(.playlist) { mainWindow.setPane(.playlist, visible: true) }
        mainWindow.playlistPane.focusSearch(sender)
    }
    @objc func showActiveTrack(_ sender: Any?) { mainWindow.playlistPane.scrollToActive() }

    // MARK: View menu

    @objc func togglePaneVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pane = Pane(rawValue: raw) else { return }
        mainWindow.togglePane(pane)
    }

    @objc func toggleLockLayout(_ sender: Any?) {
        let locked = !env.settings.bool(AppSettings.Key.lockLayout)
        env.settings.set(locked, AppSettings.Key.lockLayout)
        mainWindow.applyLock(locked)
    }

    @objc func useMainToolbar(_ sender: Any?) {
        env.settings.set(false, AppSettings.Key.slimToolbar)
        mainWindow.setSlimToolbar(false)
    }

    @objc func useSlimToolbar(_ sender: Any?) {
        env.settings.set(true, AppSettings.Key.slimToolbar)
        mainWindow.setSlimToolbar(true)
    }

    @objc func resetLayout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset the layout?"
        alert.informativeText = "All panes are shown again at their default widths and the layout is locked."
        alert.addButton(withTitle: "Reset Layout")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mainWindow.resetLayout()
    }

    @objc func showMainWindow(_ sender: Any?) { mainWindow.showWindow(nil) }

    // MARK: Tools menu

    @objc func updateCollection(_ sender: Any?) { env.scanCollection() }
    @objc func fullRescan(_ sender: Any?) { env.scanCollection(full: true) }

    /// Opens Local Music filtered by `filter` (playlist "Show Album/Artist in Media Sources").
    func showInCollection(filter: String) {
        if !mainWindow.isPaneVisible(.mediaSources) { mainWindow.setPane(.mediaSources, visible: true) }
        mainWindow.mediaSources.open(category: .localMusic)
        mainWindow.mediaSources.collectionBrowser.setFilterText(filter)
        mainWindow.mediaSources.collectionBrowser.reload()
    }

    @objc func showBookmarkManager(_ sender: Any?) { BookmarkManagerWindow.show(env: env) }

    @objc func editQueue(_ sender: Any?) { QueueEditorWindow.show(env: env) }

    @objc func showEqualizer(_ sender: Any?) { EqualizerWindow.show(env: env) }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(env: env) }

    /// Shows Media Sources at a root category and returns its page.
    @discardableResult
    func showMediaSources(_ category: MediaCategory) -> NSViewController {
        if !mainWindow.isPaneVisible(.mediaSources) { mainWindow.setPane(.mediaSources, visible: true) }
        mainWindow.mediaSources.open(category: category)
        return mainWindow.mediaSources.page(for: category)
    }

    // MARK: Covers

    private func album(from sender: NSMenuItem) -> AlbumReference? {
        guard var album = sender.representedObject as? AlbumReference else { return nil }
        if album.releaseId == nil {
            album.releaseId = try? env.database.writer.read {
                try String.fetchOne($0, sql: "SELECT mbReleaseId FROM track WHERE albumKey = ? AND mbReleaseId <> '' LIMIT 1",
                                    arguments: [album.albumKey])
            }
        }
        return album
    }

    @objc func fetchCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.fetch(album, env: env) }
    }

    @objc func displayCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.display(album, env: env) }
    }

    @objc func setCustomCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.setCustom(album, env: env) }
    }

    @objc func unsetCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.unset(album, env: env) }
    }

    @objc func showCoverManager(_ sender: Any?) { CoverManagerWindow.show(env: env) }

    // MARK: Statistics import

    @objc func importAppleMusicStatistics(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .propertyList]
        panel.message = "Choose the library file exported from Music (File › Library › Export Library…)."
        panel.prompt = "Import"
        let overwrite = NSButton(checkboxWithTitle: "Replace ratings that are already set", target: nil, action: nil)
        panel.accessoryView = overwrite
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replace = overwrite.state == .on
        let db = env.database
        let token = env.status.beginTask("Importing statistics")
        Task {
            defer { env.status.endTask(token) }
            do {
                let entries = try await Task.detached { try AppleMusicImporter.parse(url) }.value
                let report = try await AppleMusicImporter.apply(entries, to: db, overwriteRatings: replace)
                let ids = (try? await db.writer.read { try Int64.fetchAll($0, sql: "SELECT trackId FROM statistics") }) ?? []
                Commands.tracksChanged(ids: ids)
                let alert = NSAlert()
                alert.messageText = "Statistics imported"
                alert.informativeText = "\(report.entries) tracks in the export, \(report.matched) found in the collection, " +
                    "\(report.updated) updated, \(report.unmatched) not found."
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Help

    @objc func showAbout(_ sender: Any?) { AboutPanel.show() }

    @objc func showDiagnostics(_ sender: Any?) { DiagnosticsWindow.show(env: env) }

    @objc func showAcknowledgements(_ sender: Any?) { AcknowledgementsWindow.show() }

    @objc func showAmamacHelp(_ sender: Any?) { HelpWindow.show() }

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard env != nil else { return false }
        let player = env.player
        let responder = NSApp.keyWindow?.firstResponder
        let editingText = responder is NSText || responder is NSTextView
        switch menuItem.action {
        case #selector(playPause(_:)):
            let playing = player.state == .playing || player.state == .buffering
            menuItem.title = playing ? "Pause" : "Play"
            // Bare Space must reach text fields.
            return !(menuItem.keyEquivalent == " " && editingText)
        case #selector(seekForward(_:)), #selector(seekBackward(_:)):
            let bare = menuItem.keyEquivalentModifierMask.isEmpty
            if bare && (editingText || responder is NSOutlineView || responder is NSTableView) { return false }
            return player.canSeek
        case #selector(stopPlayback(_:)): return player.isActive
        case #selector(toggleStopAfterCurrent(_:)):
            let id = player.currentItem?.id ?? env.playlist.activeID
            menuItem.state = id != nil && env.playlist.stopAfterID == id ? .on : .off
            return id != nil
        case #selector(toggleMute(_:)):
            menuItem.state = player.isMuted ? .on : .off
            return true
        case #selector(setReplayGainMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.settings.replayGainMode.rawValue ? .on : .off
            return true
        case #selector(setTrackProgression(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.navigator.progression.rawValue ? .on : .off
            // Dynamic mode always plays the playlist in order.
            return env.dynamicMode.active == nil
        case #selector(setFavorMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.navigator.favor.rawValue ? .on : .off
            return env.navigator.progression.isRandom
        case #selector(setPlaylistLayout(_:)):
            menuItem.state = (menuItem.representedObject as? String) == mainWindow.playlistPane.layout.name ? .on : .off
            return true
        case #selector(togglePaneVisibility(_:)):
            if let raw = menuItem.representedObject as? String, let pane = Pane(rawValue: raw) {
                menuItem.state = mainWindow.isPaneVisible(pane) ? .on : .off
            }
            return true
        case #selector(toggleLockLayout(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.lockLayout) ? .on : .off
            return true
        case #selector(useMainToolbar(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.slimToolbar) ? .off : .on
            return true
        case #selector(useSlimToolbar(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.slimToolbar) ? .on : .off
            return true
        case #selector(savePlaylist(_:)), #selector(exportPlaylist(_:)), #selector(clearPlaylist(_:)),
             #selector(shufflePlaylist(_:)), #selector(removeDuplicatesAndDead(_:)):
            return !env.playlist.isEmpty
        case #selector(queueSelected(_:)):
            return !mainWindow.playlistPane.selectedIDs.isEmpty
        case #selector(showActiveTrack(_:)):
            return env.playlist.activeID != nil || player.currentItem != nil
        case #selector(removeCollectionFolders(_:)):
            return !env.collectionFolders.isEmpty
        default:
            return true
        }
    }
}

/// A simple window showing a full-size cover.
enum CoverViewerWindow {
    @MainActor private static var windows: [NSWindow] = []

    @MainActor
    static func show(image: NSImage, title: String) {
        let size = image.size
        let scale = min(1, 800 / max(size.width, size.height, 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(200, size.width * scale), height: max(200, size.height * scale)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        let closing = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == closing } }
        }
    }
}
