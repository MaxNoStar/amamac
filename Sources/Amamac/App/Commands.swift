import AppKit
import AmamacCore

/// Actions shared by menus, browsers, the playlist and the Pop-Up Dropper.
@MainActor
enum Commands {
    enum AddMode {
        /// Add to the end of the playlist.
        case append
        /// Add (at the end, or at `index`) and start playing the first added item.
        case appendAndPlay
        /// Replace the playlist and start playing.
        case replace
        /// Add to the end and put the new items in the queue.
        case queue
    }

    static var env: AppEnvironment { AppEnvironment.shared }

    static func addToPlaylist(_ tracks: [TrackWithStatistics], mode: AddMode, at index: Int? = nil) {
        add(tracks.map { $0.playlistItem() }, mode: mode, at: index)
    }

    static func add(_ items: [PlaylistItem], mode: AddMode, at index: Int? = nil) {
        guard !items.isEmpty else { return }
        let model = env.playlist
        switch mode {
        case .append:
            let ids = model.insert(items, at: index)
            if env.settings.bool(AppSettings.Key.startPlayingOnAdd), env.player.state == .stopped { env.player.play(ids[0]) }
        case .appendAndPlay:
            let ids = model.insert(items, at: index)
            env.player.play(ids[0])
        case .replace:
            env.player.stop()
            model.replace(with: items)
            env.player.play(items[0].id)
        case .queue:
            let ids = model.insert(items, at: index)
            model.enqueue(ids)
        }
    }

    /// Adds files, folders, playlist files or stream URLs (expanded off the main thread).
    static func addURLs(_ urls: [URL], mode: AddMode, at index: Int? = nil) {
        guard !urls.isEmpty else { return }
        let database = env.database
        Task {
            let items = await PlaylistLoader.items(for: urls, database: database)
            if items.isEmpty {
                env.status.showMessage("Nothing playable was found.")
                return
            }
            add(items, mode: mode, at: index)
        }
    }

    /// Track ids written by the collection browser, resolved to tracks (in order).
    static func tracks(fromPasteboard pasteboard: NSPasteboard) -> [TrackWithStatistics] {
        var ids: [Int64] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: .amamacTracks), let decoded = try? JSONDecoder().decode([Int64].self, from: data) {
                ids += decoded
            }
        }
        guard !ids.isEmpty else { return [] }
        return (try? env.database.writer.read { try CollectionQueries.tracks($0, ids: ids) }) ?? []
    }

    // MARK: Library actions

    /// Opens Edit Track Details. Tracks outside the collection are edited from their files.
    static func editTrackDetails(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let ids = tracks.compactMap(\.id)
        let known = (try? env.database.writer.read { try CollectionQueries.tracks($0, ids: ids) }) ?? []
        let byId = Dictionary(uniqueKeysWithValues: known.map { ($0.track.id!, $0) })
        let resolved = tracks.map { track in
            track.id.flatMap { byId[$0] } ?? TrackWithStatistics(track: track, statistics: nil)
        }
        TagEditorWindow.show(tracks: resolved, env: env)
    }

    static func organizeFiles(_ tracks: [Track]) {
        OrganizeFilesWindow.show(tracks: tracks, env: env)
    }

    static func showInFinder(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// Moves the files to the Trash after confirmation and removes them from the collection.
    static func moveToTrash(_ tracks: [Track]) {
        removeFiles(tracks, permanently: false)
    }

    /// Deletes the files permanently after a stronger confirmation.
    static func deleteFiles(_ tracks: [Track]) {
        removeFiles(tracks, permanently: true)
    }

    private static func removeFiles(_ tracks: [Track], permanently: Bool) {
        let files = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        let what = files.count == 1 ? "“\(files[0].displayTitle)”" : "\(files.count) tracks"
        alert.messageText = permanently ? "Delete \(what) permanently?" : "Move \(what) to the Trash?"
        alert.informativeText = permanently ? "The files are deleted from disk immediately. This cannot be undone."
                                            : "The files are moved to the Trash and removed from the collection."
        alert.alertStyle = permanently ? .critical : .warning
        alert.addButton(withTitle: permanently ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if permanently { alert.buttons[0].hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed = 0
        var removed: [Int64] = []
        for track in files {
            env.ignoreWatcherEvents(for: track.path)
            do {
                if permanently {
                    try FileManager.default.removeItem(at: track.url)
                } else {
                    try FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
                }
                if let id = track.id { removed.append(id) }
            } catch {
                failed += 1
            }
        }
        if failed > 0 { env.status.showMessage("\(failed) files could not be removed.") }
        let scanner = env.scanner
        Task {
            try? await scanner.forget(trackIds: removed)
            NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
        }
    }

    /// Re-reads tracks after edits and updates the playlist, the player and the browsers.
    static func tracksChanged(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let fresh = (try? env.database.writer.read { try CollectionQueries.tracks($0, ids: ids) }) ?? []
        for t in fresh {
            env.playlist.updateTrack(id: t.track.id!) { item in
                item.track = t.track
                item.statistics = t.statistics
                item.url = t.track.url
            }
            env.player.trackUpdated(t.track)
        }
        NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
    }

    // MARK: Ratings

    /// "Rating" submenu (no rating, ½ … 5 stars) for the given collection tracks.
    static func ratingMenuItem(trackIds: [Int64], current: Int?) -> NSMenuItem {
        let item = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        let menu = NSMenu()
        for value in 0...10 {
            let title = value == 0 ? "No Rating" : PlaylistRowView.stars(value)
            let entry = NSMenuItem(title: title, action: #selector(RatingTarget.setRating(_:)), keyEquivalent: "")
            entry.target = RatingTarget.shared
            entry.tag = value
            entry.representedObject = trackIds
            entry.state = current == value ? .on : .off
            menu.addItem(entry)
        }
        item.submenu = menu
        item.isEnabled = !trackIds.isEmpty
        return item
    }

    /// Sets the rating (0...10) of several tracks at once.
    static func setRating(_ rating: Int, trackIds: [Int64]) {
        guard !trackIds.isEmpty else { return }
        if trackIds.count == 1 {
            env.player.setRating(rating, trackId: trackIds[0])
            return
        }
        let db = env.database
        Task {
            let updated = (try? await db.writer.write { db -> [(Int64, TrackStatistics)] in
                try trackIds.map { id in
                    var stats = try TrackStatistics.fetchOne(db, key: id) ?? TrackStatistics(trackId: id)
                    stats.rating = max(0, min(10, rating))
                    try stats.save(db)
                    return (id, stats)
                }
            }) ?? []
            for (id, stats) in updated { env.player.statisticsUpdated(trackId: id, stats) }
            NotificationCenter.default.post(name: AppEnvironment.collectionChanged, object: nil)
        }
    }
}

/// Menu target for rating items (menus built outside a responder).
final class RatingTarget: NSObject {
    static let shared = RatingTarget()

    @objc func setRating(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [Int64] else { return }
        Commands.setRating(sender.tag, trackIds: ids)
    }
}
