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
