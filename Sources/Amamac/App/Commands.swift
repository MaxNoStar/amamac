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
            model.insert(items, at: index)
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

    static func editTrackDetails(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        env.status.showMessage("The tag editor is not available yet.")
    }

    static func organizeFiles(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        env.status.showMessage("Organize Files is not available yet.")
    }

    static func showInFinder(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// Moves the files to the Trash after confirmation and updates the collection.
    static func moveToTrash(_ tracks: [Track]) {
        let files = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = files.count == 1 ? "Move “\(files[0].displayTitle)” to the Trash?"
                                             : "Move \(files.count) tracks to the Trash?"
        alert.informativeText = "The files are moved to the Trash and removed from the collection."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed = 0
        for track in files {
            do { try FileManager.default.trashItem(at: track.url, resultingItemURL: nil) } catch { failed += 1 }
        }
        if failed > 0 { env.status.showMessage("\(failed) files could not be moved to the Trash.") }
        env.scanCollection(onlyPaths: Array(Set(files.map(\.directory))))
    }
}
