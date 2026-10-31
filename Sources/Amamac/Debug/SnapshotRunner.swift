import AppKit
import AmamacCore

/// `--snapshot DIR`: builds the fixture library inside the data directory, scans it, fills the
/// playlist, renders the main window and each pane to PNGs and exits. No audio is played.
@MainActor
final class SnapshotRunner {
    let env: AppEnvironment
    let window: MainWindowController
    let output: URL
    let layoutDump: URL?

    init(env: AppEnvironment, window: MainWindowController, output: URL, layoutDump: URL?) {
        self.env = env
        self.window = window
        self.output = output
        self.layoutDump = layoutDump
    }

    /// Canned online answers: synced lyrics for every track, a short Wikipedia article, and
    /// no MusicBrainz matches (so Wikipedia's search path is used).
    nonisolated static func stubNetwork() -> URLSessionConfiguration {
        StubURLProtocol.configuration { request in
            guard let url = request.url, let host = url.host() else { return nil }
            func json(_ object: Any) -> (Int, Data) { (200, try! JSONSerialization.data(withJSONObject: object)) }
            switch host {
            case "lrclib.net":
                let lines = (0..<24).map { i in String(format: "[00:%02d.%02d]", i / 4 * 1, (i % 4) * 25) + "Snapshot lyric line \(i + 1)" }
                return json(["instrumental": false, "plainLyrics": "", "syncedLyrics": lines.joined(separator: "\n")])
            case "musicbrainz.org":
                return json(["artists": []])
            case let h where h.hasSuffix("wikipedia.org"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if query.contains(where: { $0.name == "list" }) {
                    return json(["query": ["search": [["title": "Björk Ensemble"]]]])
                }
                let html = """
                <table class="infobox"><tr><th colspan="2">Björk Ensemble</th></tr><tr><td>Origin</td><td>Reykjavík</td></tr>
                <tr><td>Genres</td><td>Test tones</td></tr><tr><td>Years active</td><td>2015–present</td></tr></table>
                <p><b>Björk Ensemble</b> is a fictional group used by Amamac's snapshot fixtures. Its only album,
                <a href="./Discs_(album)">Dïscs</a>, consists of sine waves spread over two discs.</p>
                <h2>History</h2><p>The ensemble was formed to exercise multi-disc albums, diacritics in tags and
                gapless playback. See also <a href="https://example.org/">an external link</a>.</p>
                """
                return json(["parse": ["title": "Björk Ensemble", "text": html]])
            default:
                return nil
            }
        }
    }

    func run() {
        Snapshotter.startWatchdog(seconds: 120)
        NSApp.appearance = NSAppearance(named: .aqua)
        Task { await perform() }
    }

    private func perform() async {
        let music = env.dataDirectory.appendingPathComponent("Music")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            if !FileManager.default.fileExists(atPath: music.path) {
                try await Task.detached { _ = try AudioFixtures.buildStandardLibrary(at: music) }.value
            }
            env.setCollectionFolders([music.path])
            while try await env.scanner.scan().skipped { try await Task.sleep(for: .milliseconds(200)) }
        } catch {
            fail("fixture library: \(error)")
        }
        NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)

        let tracks = (try? await env.database.writer.read {
            try CollectionQueries.tracks($0, constraints: [], filter: CollectionQuery(groups: []), limit: nil)
        }) ?? []
        guard !tracks.isEmpty else { fail("scan produced no tracks") }
        env.playlist.replace(with: tracks.map { $0.playlistItem() })
        if let second = env.playlist.order.dropFirst().first { env.playlist.setActive(second) }
        if env.playlist.count > 4 { env.playlist.enqueue([env.playlist.order[4]]) }

        guard let win = window.window else { fail("no window") }
        win.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        win.orderFrontRegardless()
        window.resetPaneWidths()
        window.refreshTrackInfo()
        // Covers and the collection outline load asynchronously.
        try? await Task.sleep(for: .seconds(1))
        await checkPlayback()
        // Let the lyrics and Wikipedia applets load their (stubbed) content.
        try? await Task.sleep(for: .seconds(1.5))
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()

        if let root = win.contentView {
            await Snapshotter.capture(root, to: output.appendingPathComponent("window.png"))
        }
        for pane in Pane.allCases {
            if let view = window.panes[pane]?.view {
                await Snapshotter.capture(view, to: output.appendingPathComponent("pane-\(pane.rawValue).png"))
            }
        }
        await Snapshotter.capture(window.toolbar, to: output.appendingPathComponent("toolbar.png"))
        if let column = window.context.appletColumn {
            await Snapshotter.capture(column, to: output.appendingPathComponent("context-applets.png"))
        }
        await captureVariants(win)
        await capturePlaylistPages(win, tracks: tracks, music: music)
        await captureDialogs(tracks: tracks)
        if let layoutDump { Snapshotter.dumpLayout(of: win, to: layoutDump) }
        env.player.stop()
        print("snapshot: wrote \(output.path)")
        exit(0)
    }

    /// Expanded collection, unlocked layout with the slim toolbar, and the Media Sources home page.
    private func captureVariants(_ win: NSWindow) async {
        let outline = window.mediaSources.collectionBrowser.outline
        for row in stride(from: min(outline.numberOfRows, 4) - 1, through: 0, by: -1) {
            outline.expandItem(outline.item(atRow: row), expandChildren: row < 2)
        }
        try? await Task.sleep(for: .milliseconds(600))
        if let view = window.panes[.mediaSources]?.view {
            await Snapshotter.capture(view, to: output.appendingPathComponent("collection-expanded.png"))
        }

        window.applyLock(false)
        window.setSlimToolbar(true)
        win.contentView?.layoutSubtreeIfNeeded()
        if let root = win.contentView {
            await Snapshotter.capture(root, to: output.appendingPathComponent("window-unlocked-slim.png"))
        }
        window.applyLock(true)
        window.setSlimToolbar(false)

        window.mediaSources.pop(to: 0)
        win.contentView?.layoutSubtreeIfNeeded()
        if let view = window.panes[.mediaSources]?.view {
            await Snapshotter.capture(view, to: output.appendingPathComponent("media-sources-home.png"))
        }
        window.mediaSources.open(category: .localMusic)
    }

    /// Media Sources › Playlists (saved, dynamic with its banner, generator), Files, and links.
    private func capturePlaylistPages(_ win: NSWindow, tracks: [TrackWithStatistics], music: URL) async {
        let sources = window.mediaSources
        func captureSources(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(500))
            win.contentView?.layoutSubtreeIfNeeded()
            if let view = window.panes[.mediaSources]?.view {
                await Snapshotter.capture(view, to: output.appendingPathComponent(name))
            }
        }
        _ = try? SavedPlaylistStore(database: env.database).save(name: "Snapshot Mix", items: Array(env.playlist.items.prefix(5)))
        sources.open(category: .playlists)
        await captureSources("playlists-home.png")
        guard let playlists = sources.page(for: .playlists) as? PlaylistsBrowserPage else { fail("no playlists page") }
        playlists.open(.saved)
        await captureSources("playlists-saved.png")

        sources.open(category: .playlists)
        playlists.open(.dynamic)
        let mode = env.dynamicMode
        guard let random = GeneratorStore(database: env.database).dynamicPlaylists().first else { fail("no dynamic playlists") }
        // A fixed current track: the 2-second fixtures would otherwise keep advancing.
        env.player.stop()
        let model = env.playlist
        model.setActive(model.order[min(7, model.count - 1)])
        mode.start(random)
        func upcoming() -> Int { (model.activeIndex ?? -1) < 0 ? model.count : model.count - model.activeIndex! - 1 }
        await Snapshotter.waitUntil(timeout: 5) { upcoming() == mode.upcomingCount }
        guard upcoming() == mode.upcomingCount else { fail("dynamic mode filled \(upcoming()) of \(mode.upcomingCount) upcoming tracks "
                 + "(count \(model.count), active \(String(describing: model.activeIndex)), working \(mode.isWorking), "
                 + "current \(String(describing: env.player.currentItem.flatMap { model.index(of: $0.id) })))") }
        await captureSources("playlists-dynamic.png")
        if let view = window.panes[.playlist]?.view {
            await Snapshotter.capture(view, to: output.appendingPathComponent("pane-playlist-dynamic.png"))
        }
        mode.stop()
        print("snapshot: dynamic mode check passed")

        sources.open(category: .playlists)
        guard let generator = playlists.open(.generator) as? HostedPage<GeneratorView> else { fail("no generator page") }
        generator.root.model.run()
        await Snapshotter.waitUntil(timeout: 10) { generator.root.model.result != nil }
        guard let result = generator.root.model.result, !result.ids.isEmpty else { fail("the playlist generator produced nothing") }
        await captureSources("playlists-generator.png")

        guard let files = sources.page(for: .files) as? FileBrowserPage else { fail("no files page") }
        sources.open(category: .files)
        files.model.go(to: music)
        await Snapshotter.waitUntil(timeout: 3) { !files.model.entries.isEmpty }
        await captureSources("files-browser.png")

        // A view bookmark round trip: Local Music grouped by artist with a filter.
        let grouping = env.settings.collectionGrouping
        LinkHandler.open(AmamacLink.collection(filter: "artist:a", levels: ["artist"]).url)
        guard sources.currentCategory == .localMusic, sources.collectionBrowser.searchField.stringValue == "artist:a",
              env.settings.collectionGrouping.levels == [.artist] else { fail("collection link did not apply") }
        BookmarkStore(database: env.database).addView(name: sources.currentViewLink!.name, link: sources.currentViewLink!.link)
        env.settings.collectionGrouping = grouping
        sources.collectionBrowser.setFilterText("")
        sources.collectionBrowser.reload()
        if let track = tracks.first?.track.id {
            BookmarkStore(database: env.database).addPosition(trackId: track, title: tracks[0].track.displayTitle, position: 1)
        }
        print("snapshot: link check passed")
    }

    /// Opens each library dialog, captures it and closes it again.
    private func captureDialogs(tracks: [TrackWithStatistics]) async {
        func capture(_ prefix: String, _ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            guard let dialog = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(prefix) }),
                  let view = dialog.contentView?.superview ?? dialog.contentView else {
                FileHandle.standardError.write("snapshot: no window titled \(prefix)\n".data(using: .utf8)!)
                return
            }
            await Snapshotter.capture(view, to: output.appendingPathComponent(name))
            dialog.close()
        }
        let album = tracks.filter { $0.track.album == "Dïscs" }
        TagEditorWindow.show(tracks: album, env: env)
        await capture("Edit Track Details", "dialog-tag-editor.png")
        OrganizeFilesWindow.show(tracks: tracks.map(\.track), env: env)
        await capture("Organize Files", "dialog-organize.png")
        EditFilterDialog.show(initial: "artist:björk year:>2000 -live", relativeTo: nil) { _ in }
        await capture("Edit Filter", "dialog-edit-filter.png")
        CoverManagerWindow.show(env: env)
        await capture("Cover Manager", "dialog-cover-manager.png")
        env.playlist.enqueue(Array(env.playlist.order.suffix(3)))
        QueueEditorWindow.show(env: env)
        await capture("Queue Editor", "dialog-edit-queue.png")
        BookmarkManagerWindow.show(env: env)
        await capture("Bookmark Manager", "dialog-bookmarks.png")
        env.equalizer.select("Rock")
        guard env.equalizer.enabled, env.settings.string(AppSettings.Key.equalizerPreset) == "Rock" else { fail("equalizer preset not applied") }
        EqualizerWindow.show(env: env)
        await capture("Equalizer", "dialog-equalizer.png")
        env.equalizer.setEnabled(false)
        SettingsWindowController.show(env: env, pane: .playback)
        await capture("Playback", "settings-playback.png")
    }

    /// Plays silently through PlayerController and checks state, position and Next. The window is
    /// captured while playing so the snapshot shows the playing state.
    private func checkPlayback() async {
        let player = env.player
        player.local.setVolume(0)
        player.stream.setVolume(0)
        guard let first = env.playlist.activeID else { fail("no active item") }
        player.play(first)
        await Snapshotter.waitUntil(timeout: 5) { player.currentTime > 0.6 }
        guard player.state == .playing, player.currentItem?.id == first, player.currentTime > 0.6 else {
            fail("playback did not start (state \(player.state), time \(player.currentTime))")
        }
        let expectedNext = env.navigator.peekNext()
        player.next()
        await Snapshotter.waitUntil(timeout: 3) { player.currentItem?.id == expectedNext && player.currentTime > 0.2 }
        guard let expectedNext, player.currentItem?.id == expectedNext else { fail("Next did not advance") }
        print("snapshot: playback check passed")
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write("snapshot failed: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
