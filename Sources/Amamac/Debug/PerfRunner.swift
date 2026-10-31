import AmamacDatabase
import AmamacPlaylist
import AmamacQuery
import AmamacTestSupport
import AppKit

/// `--perf FILE --data-dir DIR`: fills the collection with 20,000 synthetic tracks and times the
/// operations a large library stresses, through the real window. Results go to FILE and stdout.
@MainActor
final class PerfRunner {
    private let env: AppEnvironment
    private let window: MainWindowController
    private let output: URL
    private var lines: [String] = []

    init(env: AppEnvironment, window: MainWindowController, output: URL) {
        self.env = env
        self.window = window
        self.output = output
    }

    func run() {
        Snapshotter.startWatchdog(seconds: 180)
        Task { await perform() }
    }

    @discardableResult
    private func measure(_ label: String, budget: Duration, _ body: () -> Void) -> Duration {
        let elapsed = ContinuousClock().measure(body)
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        let line = String(format: "%-44@ %8.1f ms  %@", label as NSString, ms, elapsed <= budget ? "ok" : "SLOW (budget \(budget))")
        print("perf: " + line)
        lines.append(line)
        return elapsed
    }

    private func perform() async {
        guard let win = window.window else { exit(1) }
        win.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        win.orderFrontRegardless()
        window.resetPaneWidths()
        func draw() {
            win.contentView?.layoutSubtreeIfNeeded()
            win.displayIfNeeded()
        }

        measure("populate 20,000 synthetic tracks", budget: .seconds(20)) {
            try? SyntheticLibrary.populate(env.database, trackCount: 20_000)
        }
        let browser = window.mediaSources.collectionBrowser
        measure("collection: top level (album artists)", budget: .milliseconds(300)) {
            browser.reload()
            draw()
        }
        measure("collection: expand 5 artists", budget: .milliseconds(300)) {
            for row in stride(from: 8, through: 0, by: -2) { browser.outline.expandItem(browser.outline.item(atRow: row)) }
            draw()
        }
        measure("collection: filter “night”", budget: .milliseconds(500)) {
            browser.setFilterText("night")
            draw()
        }
        measure("collection: filter rating:>3 year:>1990", budget: .milliseconds(500)) {
            browser.setFilterText("rating:>3 year:>1990")
            draw()
        }
        measure("collection: clear filter", budget: .milliseconds(300)) {
            browser.setFilterText("")
            draw()
        }

        var tracks: [TrackWithStatistics] = []
        measure("load 20,000 tracks with statistics", budget: .milliseconds(800)) {
            tracks = (try? env.database.tracks()) ?? []
        }
        let pane = window.playlistPane
        measure("playlist: replace with 20,000 items", budget: .milliseconds(800)) {
            env.playlist.replace(with: tracks.map { $0.playlistItem() })
            pane.reload()
            draw()
        }
        measure("playlist: jump to row 10,000", budget: .milliseconds(150)) {
            pane.table.scrollRowToVisible(10_000)
            draw()
        }
        measure("playlist: scroll 40 screens", budget: .milliseconds(1500)) {
            for i in 0..<40 {
                pane.table.scrollRowToVisible(10_000 + i * 40)
                draw()
            }
        }
        measure("playlist: sort by artist, album", budget: .milliseconds(600)) {
            env.proxy.sortLevels = [PlaylistSortLevel(column: .artist), PlaylistSortLevel(column: .album)]
            pane.reload()
            draw()
        }
        measure("playlist: clear sort", budget: .milliseconds(600)) {
            env.proxy.sortLevels = []
            pane.reload()
            draw()
        }
        measure("playlist: select all and copy", budget: .milliseconds(800)) {
            pane.table.selectAll(nil)
            pane.perform(#selector(NSText.copy(_:)), with: nil)
        }
        measure("playlist: remove 5,000 items", budget: .milliseconds(600)) {
            env.playlist.remove(Set(env.playlist.order.prefix(5_000)))
            pane.reload()
            draw()
        }
        measure("playlist: undo", budget: .milliseconds(600)) {
            env.playlist.undo()
            pane.reload()
            draw()
        }
        measure("save session (20,000 entries)", budget: .milliseconds(500)) {
            let session = PlaylistLoader.Session(model: env.playlist, position: nil, wasPlaying: false)
            try? PlaylistLoader.saveSession(session, database: env.database)
        }
        let clock = ContinuousClock()
        let start = clock.now
        if let session = PlaylistLoader.loadSession(database: env.database) {
            _ = await PlaylistLoader.items(for: session, database: env.database)
        }
        let restore = clock.now - start
        lines.append("restore session (20,000 entries)            \(restore.formatted(.units(allowed: [.milliseconds])))")
        print("perf: restore session: \(restore)")

        try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
        exit(lines.contains { $0.contains("SLOW") } ? 2 : 0)
    }
}
