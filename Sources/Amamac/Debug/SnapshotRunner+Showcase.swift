// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacDatabase
import AmamacModels
import AmamacTestSupport
import AppKit

extension SnapshotRunner {
    /// The stubbed Wikipedia article for `ShowcaseLibrary.heroArtist`.
    nonisolated static let showcaseArticle = """
        <table class="infobox"><tr><th colspan="2">MC Chops</th></tr><tr><td>Origin</td><td>The Barnyard</td></tr>
        <tr><td>Genres</td><td>Rock and roll, oink rock</td></tr><tr><td>Instruments</td><td>Electric guitar, mustache</td></tr>
        <tr><td>Years active</td><td>2026–present</td></tr></table>
        <p><b>MC Chops</b> is a pink, mustachioed rock-and-roll pig and the mascot of Amamac, a music player for macOS.
        Like everything in these screenshots he is made up. His debut album,
        <a href="./Handlebar_Anthems">Handlebar Anthems</a> (2026), was recorded in a single take because nobody could
        get him to stop playing.</p>
        <h2>Style</h2><p>Chops waxes his handlebar mustache before every show and never takes off his shades or his
        studded jacket. Critics describe his sound as "three chords and a snout".</p>
        <h2>Influences</h2><p>Late-night radio, the dinner bell and rain on the barn roof.</p>
        """

    /// `AMAMAC_SNAPSHOT_SHOWCASE=1`: builds `ShowcaseLibrary`, plays MC Chops (silently) and
    /// writes the README screenshots as `showcase-*.png` at 2×. `scripts/readme-screenshots.sh`
    /// (`make screenshots`) runs it in light and dark and resizes the results.
    func performShowcase() async {
        let music = env.dataDirectory.appendingPathComponent("Music")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            if !FileManager.default.fileExists(atPath: music.path) {
                try await Task.detached { try ShowcaseLibrary.build(at: music) }.value
            }
            env.setCollectionFolders([music.path])
            while try await env.scanner.scan().skipped { try await Task.sleep(for: .milliseconds(200)) }
        } catch {
            fail("showcase library: \(error)")
        }
        NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
        let tracks = (try? await env.database.tracks()) ?? []
        guard tracks.count == ShowcaseLibrary.albums.reduce(0, { $0 + $1.tracks.count }) else {
            fail("showcase scan found \(tracks.count) tracks")
        }
        let albumOrder = ShowcaseLibrary.albums.map(\.title)
        func rank(_ t: TrackWithStatistics) -> (Int, Int) { (albumOrder.firstIndex(of: t.track.album) ?? 99, t.track.trackNumber) }
        env.playlist.replace(with: tracks.sorted { rank($0) < rank($1) }.map { $0.playlistItem() })

        let player = env.player, context = window.context, sources = window.mediaSources
        let defaults = env.settings.defaults
        player.local.setVolume(0)
        player.stream.setVolume(0)
        // The analyzer sits above Wikipedia so the hero shows all three applets.
        let applets: [AppletKind] = [.currentTrack, .analyzer, .wikipedia]
        context.setEnabled(applets)
        defaults.set(AnalyzerStyle.neonBars.rawValue, forKey: AppSettings.Key.analyzerStyle)
        guard let win = window.window else { fail("no window") }
        win.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        win.orderFrontRegardless()
        window.resetPaneWidths()

        // The hero: MC Chops's second track, a minute and a half in, with the analyzer dancing.
        guard let hero = env.playlist.items.first(where: { $0.track.title == "Mustache Rides Again" }) else { fail("no hero track") }
        player.play(hero.id)
        await Snapshotter.waitUntil(timeout: 5) { player.currentTime > 0.2 }
        guard player.state == .playing, player.currentItem?.id == hero.id else { fail("showcase playback did not start") }
        player.seek(to: 84)
        await Snapshotter.waitUntil(timeout: 5) { player.currentTime > 84 }
        guard player.currentTime > 84 else { fail("showcase seek stopped at \(player.currentTime)") }
        guard let analyzer = context.applet(.analyzer) as? AnalyzerAppletController else { fail("no analyzer applet") }
        let start = Date()
        analyzer.state.spectrum = { bands in Self.demoSpectrum(bands: bands, at: Date().timeIntervalSince(start)) }
        let outline = sources.collectionBrowser.outline
        let artists = Set(ShowcaseLibrary.albums.map(\.artist)).count
        await Snapshotter.waitUntil(timeout: 5) { outline.numberOfRows >= artists }
        for row in stride(from: outline.numberOfRows - 1, through: 0, by: -1) {
            outline.expandItem(outline.item(atRow: row), expandChildren: false)
        }
        window.refreshTrackInfo()
        // Covers, the Wikipedia article and the analyzer settle.
        try? await Task.sleep(for: .seconds(2.5))
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()

        func capture(_ view: NSView?, _ name: String, background: NSColor? = .windowBackgroundColor) async {
            guard let view else { fail("nothing to capture for \(name)") }
            await Snapshotter.capture(view, to: output.appendingPathComponent("showcase-\(name).png"), scale: 2,
                                      background: background)
        }
        await capture(win.contentView, "hero")
        await capture(window.panes[.context]?.view, "context")

        // Three more analyzer styles, alone in the context column.
        context.setEnabled([.analyzer])
        for style in [AnalyzerStyle.aurora, .halo, .ledMatrix] {
            defaults.set(style.rawValue, forKey: AppSettings.Key.analyzerStyle)
            try? await Task.sleep(for: .seconds(1.5))
            await capture(context.appletColumn, "analyzer-\(style.rawValue)")
        }
        context.setEnabled(applets)

        // Media Sources: a shorter window so the lists fill the pane, with MC Chops's album open.
        win.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 640), display: true)
        for row in 0..<outline.numberOfRows {
            if let group = (outline.item(atRow: row) as? CollectionNode)?.group, group.level == .album,
               group.albumArtist == ShowcaseLibrary.heroArtist {
                outline.expandItem(outline.item(atRow: row))
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(800))
        await capture(window.panes[.mediaSources]?.view, "collection")
        sources.open(category: .playlists)
        guard let playlists = sources.page(for: .playlists) as? PlaylistsBrowserPage else { fail("no playlists page") }
        playlists.open(.dynamic)
        try? await Task.sleep(for: .milliseconds(800))
        await capture(window.panes[.mediaSources]?.view, "dynamic")
        sources.open(category: .internet)
        guard let internet = sources.page(for: .internet) as? InternetBrowserPage,
              let radio = internet.open(.radio) as? HostedPage<RadioView> else { fail("no internet radio page") }
        await Snapshotter.waitUntil(timeout: 5) { !radio.root.model.top.stations.isEmpty }
        try? await Task.sleep(for: .milliseconds(800))
        await capture(window.panes[.mediaSources]?.view, "radio")

        // Settings › Playback with crossfading switched on.
        env.settings.set(true, AppSettings.Key.crossfade)
        SettingsWindowController.show(env: env, pane: .playback)
        try? await Task.sleep(for: .milliseconds(900))
        guard let settings = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(SettingsPane.playback.title) }) else {
            fail("no Playback settings window")
        }
        // The whole window frame, keeping its rounded corners transparent.
        await capture(settings.contentView?.superview ?? settings.contentView, "settings", background: nil)
        settings.close()

        player.stop()
        print("snapshot: showcase written to \(output.path)")
        exit(0)
    }
}
#endif
