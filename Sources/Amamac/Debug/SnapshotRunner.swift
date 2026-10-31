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
            case "all.api.radio-browser.info":
                return json([["name": "de1.api.radio-browser.info"]])
            case let h where h.hasSuffix("api.radio-browser.info"):
                let path = url.path()
                if path.contains("/json/tags") {
                    return json([["name": "jazz", "stationcount": 1520], ["name": "news", "stationcount": 980], ["name": "classical", "stationcount": 870]])
                }
                if path.contains("/json/countries") {
                    return json([["name": "Iceland", "iso_3166_1": "IS", "stationcount": 41], ["name": "Japan", "iso_3166_1": "JP", "stationcount": 312]])
                }
                if path.contains("/json/url/") { return json(["ok": true]) }
                let stations: [(String, String, Int, Int, String)] = [
                    ("Reykjavík Jazz", "MP3", 128, 0, "jazz,bebop"), ("Sine Wave FM", "AAC+", 64, 0, "electronic,ambient"),
                    ("Ogg Vorbis Classics", "OGG", 160, 0, "classical"), ("World News 24", "AAC", 96, 1, "news,talk"),
                    ("Synth City", "MP3", 320, 0, "synthwave,80s"), ("Opus Experimental", "OPUS", 96, 0, "experimental"),
                ]
                return json(stations.enumerated().map { i, s in
                    ["stationuuid": "stub-\(i)", "name": s.0, "url": "http://radio.example.org/\(i)", "codec": s.1, "bitrate": s.2,
                     "hls": s.3, "tags": s.4, "country": "Iceland", "favicon": "https://art.example.org/\(i).png",
                     "homepage": "https://radio.example.org"] as [String: Any]
                })
            case "itunes.apple.com":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard query.contains(where: { $0.name == "media" && $0.value == "podcast" }) else { return nil }
                return json(["results": [
                    ["collectionId": 1, "collectionName": "Field Recordings", "artistName": "Example Radio", "primaryGenreName": "Music",
                     "feedUrl": "https://pod.example.org/feed.xml", "artworkUrl600": "https://pod.example.org/art.png"],
                    ["collectionId": 2, "collectionName": "Tone Talk", "artistName": "The Synthetics", "primaryGenreName": "Technology",
                     "feedUrl": "https://tones.example.org/rss", "artworkUrl600": "https://art.example.org/7.png"],
                ]])
            case "pod.example.org":
                if url.pathExtension == "png" { return (200, stubArtwork(hue: 0.08)) }
                return (200, stubFeed)
            case "art.example.org":
                return (200, stubArtwork(hue: Double(url.deletingPathExtension().lastPathComponent) .map { $0 / 8 } ?? 0.5))
            case "cdn.example.org":
                return (200, Data(repeating: 0, count: 48_000))
            default:
                return nil
            }
        }
    }

    nonisolated static let stubFeed = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Field Recordings</title><link>https://pod.example.org</link>
        <itunes:author>Example Radio</itunes:author><itunes:image href="https://pod.example.org/art.png"/>
        <description>Sounds recorded outdoors, with notes on where and how.</description>
        <item><title>Harbour at Dawn</title><guid>e3</guid><pubDate>Mon, 19 Oct 2026 06:00:00 +0000</pubDate>
        <enclosure url="https://cdn.example.org/e3.mp3" length="48000" type="audio/mpeg"/><itunes:duration>24:10</itunes:duration>
        <description><![CDATA[<p>Gulls, ropes and a <b>distant foghorn</b>, recorded from the pier.</p>]]></description></item>
        <item><title>Rain on a Tin Roof</title><guid>e2</guid><pubDate>Mon, 12 Oct 2026 06:00:00 +0000</pubDate>
        <enclosure url="https://cdn.example.org/e2.mp3" length="48000" type="audio/mpeg"/><itunes:duration>31:02</itunes:duration>
        <description>A summer storm passing over a mountain hut.</description></item>
        <item><title>Night Train</title><guid>e1</guid><pubDate>Mon, 05 Oct 2026 06:00:00 +0000</pubDate>
        <enclosure url="https://cdn.example.org/e1.mp3" length="48000" type="audio/mpeg"/><itunes:duration>45:00</itunes:duration>
        <description>Sleeper carriage from Oslo to Bergen.</description></item>
        </channel></rss>
        """.utf8)

    /// A small gradient PNG standing in for station logos and podcast artwork.
    nonisolated static func stubArtwork(hue: Double) -> Data {
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let top = NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.6, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 24, height: 24))
        guard let image = ctx.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    func run() {
        Snapshotter.startWatchdog(seconds: 120)
        NSApp.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["AMAMAC_SNAPSHOT_DARK"] == nil ? .aqua : .darkAqua)
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
        await captureInternetPages(win)
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

    /// Internet radio, the podcast directory and the Podcasts page, against the stubbed network.
    private func captureInternetPages(_ win: NSWindow) async {
        let sources = window.mediaSources
        func captureSources(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            win.contentView?.layoutSubtreeIfNeeded()
            if let view = window.panes[.mediaSources]?.view {
                await Snapshotter.capture(view, to: output.appendingPathComponent(name))
            }
        }
        sources.open(category: .internet)
        guard let internet = sources.page(for: .internet) as? InternetBrowserPage,
              let radio = internet.open(.radio) as? HostedPage<RadioView> else { fail("no internet radio page") }
        let top = radio.root.model.top
        await Snapshotter.waitUntil(timeout: 5) { !top.stations.isEmpty }
        guard top.stations.count == 6, top.hiddenCount == 2 else {
            fail("radio: \(top.stations.count) stations, \(top.hiddenCount) hidden, error \(top.error ?? "none")")
        }
        top.toggleFavorite(top.visible[0])
        let before = env.playlist.count
        top.add([top.visible[1]], mode: .append)
        guard env.playlist.count == before + 1, env.playlist.items.last?.isStream == true,
              env.playlist.items.last?.track.title == "Sine Wave FM" else { fail("station was not added as a stream") }
        await captureSources("internet-radio.png")

        sources.open(category: .internet)
        guard let directory = internet.open(.podcasts) as? HostedPage<PodcastDirectoryView> else { fail("no podcast directory") }
        let search = directory.root.model
        search.term = "field recordings"
        search.search()
        await Snapshotter.waitUntil(timeout: 5) { !search.results.isEmpty }
        guard let first = search.results.first else { fail("podcast search found nothing") }
        search.subscribe(first)
        await Snapshotter.waitUntil(timeout: 5) { env.podcasts.channels.count == 1 }
        guard let channel = env.podcasts.channels.first, let channelId = channel.id else { fail("podcast subscription failed") }
        await captureSources("podcast-directory.png")

        sources.open(category: .podcasts)
        guard let page = sources.page(for: .podcasts) as? PodcastBrowserPage else { fail("no podcasts page") }
        page.model.setExpanded(channelId, true)
        let episodes = env.podcasts.service.episodes(channelId: channelId)
        guard episodes.count == 3, episodes[0].isNew, !episodes[1].isNew else { fail("podcast episodes: \(episodes.map(\.title))") }
        env.podcasts.download(episodes[0])
        await Snapshotter.waitUntil(timeout: 5) { env.podcasts.service.episodes(channelId: channelId).first?.isDownloaded == true }
        guard env.podcasts.service.episodes(channelId: channelId).first?.isDownloaded == true else { fail("episode download failed") }
        page.model.selection = [.episode(episodes[0].id!)]
        await captureSources("podcasts.png")
        print("snapshot: internet check passed")
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
        for pane in SettingsPane.allCases {
            SettingsWindowController.show(env: env, pane: pane)
            await capture(pane.title, "settings-\(pane.rawValue).png")
        }
        HelpWindow.show()
        await capture("Amamac Help", "help.png")
        DiagnosticsWindow.show(env: env)
        await capture("Diagnostics", "diagnostics.png")

        // The OSD with an opaque background (the HUD material does not render off screen).
        env.settings.set(false, AppSettings.Key.osdTranslucent)
        let osd = OSDController(env: env)
        if let item = env.playlist.items.first(where: { $0.source == .collection && !$0.track.album.isEmpty }) {
            osd.showTrack(item, force: true)
            try? await Task.sleep(for: .milliseconds(600))
            if let view = osd.contentView { await Snapshotter.capture(view, to: output.appendingPathComponent("osd-track.png")) }
        }
        osd.showMessage("Volume 60%", symbol: "speaker.wave.2.fill", level: 0.6, force: true)
        try? await Task.sleep(for: .milliseconds(300))
        if let view = osd.contentView { await Snapshotter.capture(view, to: output.appendingPathComponent("osd-volume.png")) }
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
