import AmamacBase
import AmamacModels
import AmamacPlaylist
import AppKit

/// Playlist menu: adding media, saving and exporting, track progression, layouts and the
/// playlist actions that must work wherever the focus is.
@MainActor
final class PlaylistCommands: NSObject, NSMenuItemValidation {
    private unowned let env: AppEnvironment
    private unowned let window: MainWindowController

    init(env: AppEnvironment, window: MainWindowController) {
        self.env = env
        self.window = window
    }

    @objc func addMedia(_ sender: Any?) {
        guard let urls = MediaOpenPanel.run(prompt: "Add") else { return }
        env.actions.addURLs(urls, mode: .append)
    }

    @objc func addStream(_ sender: Any?) {
        guard let input = TextPrompt.ask("Add Stream", info: "Enter the address of an internet radio stream or a playlist (.m3u, .pls).",
                                         placeholder: "https://", width: 360, action: "Add") else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            env.status.showMessage("“\(text)” is not a valid stream address.")
            return
        }
        env.actions.add([PlaylistItem.stream(url: url, title: nil)], mode: .append)
    }

    @objc func savePlaylist(_ sender: Any?) {
        guard !env.playlist.isEmpty else { return }
        guard let input = TextPrompt.ask("Save Playlist", info: "Saved playlists appear under Media Sources › Playlists.",
                                         text: defaultPlaylistName(), width: 300, action: "Save") else { return }
        let name = input.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? defaultPlaylistName()
        do {
            try env.savedPlaylists.save(name: name, items: env.playlist.items)
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
        panel.allowedContentTypes = PlaylistFileFormat.contentTypes
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
        window.playlistPane.progressionChanged()
        window.refreshTrackInfo()
    }

    @objc func setFavorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FavorMode(rawValue: raw) else { return }
        env.navigator.favor = mode
        env.settings.favor = mode
        env.player.updateUpcoming()
        window.refreshTrackInfo()
    }

    @objc func setPlaylistLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        window.playlistPane.applyLayout(named: name)
    }

    /// Track Progression submenu (menu bar and the playlist's bottom bar).
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
    @objc func shufflePlaylist(_ sender: Any?) { window.playlistPane.shufflePlaylist(sender) }
    @objc func removeDuplicatesAndDead(_ sender: Any?) { window.playlistPane.removeDuplicatesAndDead(sender) }
    @objc func queueSelected(_ sender: Any?) { window.playlistPane.queueSelected(nil) }
    @objc func searchPlaylist(_ sender: Any?) {
        if !window.isPaneVisible(.playlist) { window.setPane(.playlist, visible: true) }
        window.playlistPane.focusSearch(sender)
    }
    @objc func showActiveTrack(_ sender: Any?) { window.playlistPane.scrollToActive() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setTrackProgression(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.navigator.progression.rawValue ? .on : .off
            // Dynamic mode always plays the playlist in order.
            return env.dynamicMode.active == nil
        case #selector(setFavorMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == env.navigator.favor.rawValue ? .on : .off
            return env.navigator.progression.isRandom
        case #selector(setPlaylistLayout(_:)):
            menuItem.state = (menuItem.representedObject as? String) == window.playlistPane.layout.name ? .on : .off
            return true
        case #selector(savePlaylist(_:)), #selector(exportPlaylist(_:)), #selector(clearPlaylist(_:)),
             #selector(shufflePlaylist(_:)), #selector(removeDuplicatesAndDead(_:)):
            return !env.playlist.isEmpty
        case #selector(queueSelected(_:)):
            return !window.playlistPane.selectedIDs.isEmpty
        case #selector(showActiveTrack(_:)):
            return env.playlist.activeID != nil || env.player.currentItem != nil
        default:
            return true
        }
    }
}
