import AppKit
import AmamacCore

/// Builds the menu bar: Amamac, Edit, View, Playback, Playlist, Tools, Window, Help.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu()))
        bar.addItem(submenu(editMenu()))
        bar.addItem(submenu(viewMenu()))
        bar.addItem(submenu(playbackMenu()))
        bar.addItem(submenu(playlistMenu()))
        bar.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Amamac Help", #selector(NSApplication.showHelp(_:)), "?"))
        bar.addItem(submenu(help))
        NSApp.helpMenu = help
        return bar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, object: Any? = nil,
                             symbol: String? = nil, in menu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.representedObject = object
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu?.addItem(item)
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: Amamac.appName)
        item("About \(Amamac.appName)", #selector(AppDelegate.showAbout(_:)), in: m)
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        m.addItem(services)
        m.addItem(.separator())
        item("Hide \(Amamac.appName)", #selector(NSApplication.hide(_:)), "h", in: m)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], in: m)
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), in: m)
        m.addItem(.separator())
        item("Quit \(Amamac.appName)", #selector(NSApplication.terminate(_:)), "q", in: m)
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        item("Undo", Selector(("undo:")), "z", in: m)
        item("Redo", Selector(("redo:")), "z", [.command, .shift], in: m)
        m.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), "x", in: m)
        item("Copy", #selector(NSText.copy(_:)), "c", in: m)
        item("Paste", #selector(NSText.paste(_:)), "v", in: m)
        item("Delete", #selector(NSText.delete(_:)), in: m)
        item("Select All", #selector(NSText.selectAll(_:)), "a", in: m)
        m.addItem(.separator())
        item("Search Collection", #selector(CollectionBrowserViewController.focusSearch(_:)), "f", [.command, .option], in: m)
        item("Search Playlist", #selector(AppDelegate.searchPlaylist(_:)), "j", in: m)
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        for (i, pane) in Pane.allCases.enumerated() {
            item(pane.title, #selector(AppDelegate.togglePaneVisibility(_:)), "\(i + 1)", [.command, .option], object: pane.rawValue, in: m)
        }
        m.addItem(.separator())
        item("Lock Layout", #selector(AppDelegate.toggleLockLayout(_:)), in: m)
        item("Main Toolbar", #selector(AppDelegate.useMainToolbar(_:)), in: m)
        item("Slim Toolbar", #selector(AppDelegate.useSlimToolbar(_:)), in: m)
        item("Reset Layout…", #selector(AppDelegate.resetLayout(_:)), in: m)
        m.addItem(.separator())
        item("Show Active Track", #selector(AppDelegate.showActiveTrack(_:)), "l", in: m)
        m.addItem(.separator())
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], in: m)
        return m
    }

    private static func playbackMenu() -> NSMenu {
        let m = NSMenu(title: "Playback")
        item("Play Media…", #selector(AppDelegate.playMedia(_:)), "o", in: m)
        m.addItem(.separator())
        item("Play", #selector(AppDelegate.playPause(_:)), " ", [], in: m)
        item("Stop", #selector(AppDelegate.stopPlayback(_:)), ".", in: m)
        item("Stop After Current Track", #selector(AppDelegate.toggleStopAfterCurrent(_:)), ".", [.command, .shift], in: m)
        item("Previous Track", #selector(AppDelegate.previousTrack(_:)), "\u{F702}", [.command, .option], in: m)
        item("Next Track", #selector(AppDelegate.nextTrack(_:)), "\u{F703}", [.command, .option], in: m)
        m.addItem(.separator())
        let seeks: [(String, String, Int, NSEvent.ModifierFlags)] = [("Seek Forward", "\u{F703}", 1, []),
                                                                    ("Seek Backward", "\u{F702}", 1, []),
                                                                    ("Seek Forward (Short)", "\u{F703}", 0, .command),
                                                                    ("Seek Backward (Short)", "\u{F702}", 0, .command),
                                                                    ("Seek Forward (Long)", "\u{F703}", 2, .shift),
                                                                    ("Seek Backward (Long)", "\u{F702}", 2, .shift)]
        for (title, key, tag, mods) in seeks {
            let action = title.hasPrefix("Seek Forward") ? #selector(AppDelegate.seekForward(_:)) : #selector(AppDelegate.seekBackward(_:))
            item(title, action, key, mods, tag: tag, in: m)
        }
        m.addItem(.separator())
        item("Increase Volume", #selector(AppDelegate.volumeUp(_:)), "\u{F700}", in: m)
        item("Decrease Volume", #selector(AppDelegate.volumeDown(_:)), "\u{F701}", in: m)
        item("Mute", #selector(AppDelegate.toggleMute(_:)), "\u{F701}", [.command, .option], in: m)
        m.addItem(.separator())
        let rg = NSMenuItem(title: "Replay Gain Mode", action: nil, keyEquivalent: "")
        let rgMenu = NSMenu(title: "Replay Gain Mode")
        for (title, mode) in [("Off", ReplayGainMode.off), ("Track", .track), ("Album", .album)] {
            item(title, #selector(AppDelegate.setReplayGainMode(_:)), object: mode.rawValue, in: rgMenu)
        }
        rg.submenu = rgMenu
        m.addItem(rg)
        return m
    }

    private static func playlistMenu() -> NSMenu {
        let m = NSMenu(title: "Playlist")
        item("Add Media…", #selector(AppDelegate.addMedia(_:)), "o", [.command, .shift], in: m)
        item("Add Stream…", #selector(AppDelegate.addStream(_:)), "o", [.command, .option], in: m)
        m.addItem(.separator())
        item("Save Playlist…", #selector(AppDelegate.savePlaylist(_:)), "s", in: m)
        item("Export Playlist As…", #selector(AppDelegate.exportPlaylist(_:)), "s", [.command, .shift], in: m)
        m.addItem(.separator())
        item("Clear Playlist", #selector(AppDelegate.clearPlaylist(_:)), "\u{8}", [.command, .shift], in: m)
        item("Shuffle Playlist", #selector(AppDelegate.shufflePlaylist(_:)), "h", [.command, .shift], in: m)
        item("Remove Duplicate and Dead Entries", #selector(AppDelegate.removeDuplicatesAndDead(_:)), in: m)
        m.addItem(.separator())
        item("Queue Track", #selector(AppDelegate.queueSelected(_:)), "d", in: m)
        item("Edit Queue…", #selector(AppDelegate.editQueue(_:)), "u", [.control, .option], in: m)
        m.addItem(.separator())
        let progression = NSMenuItem(title: "Track Progression", action: nil, keyEquivalent: "")
        progression.submenu = AppDelegate.makeProgressionMenu()
        m.addItem(progression)
        let layouts = NSMenuItem(title: "Playlist Layouts", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Playlist Layouts")
        for layout in PlaylistLayout.builtIn {
            item(layout.name, #selector(AppDelegate.setPlaylistLayout(_:)), object: layout.name, in: layoutMenu)
        }
        layouts.submenu = layoutMenu
        m.addItem(layouts)
        return m
    }

    private static func toolsMenu() -> NSMenu {
        let m = NSMenu(title: "Tools")
        item("Bookmark Manager", #selector(AppDelegate.showBookmarkManager(_:)), in: m)
        item("Cover Manager", #selector(AppDelegate.showCoverManager(_:)), in: m)
        m.addItem(.separator())
        item("Collection Folders…", #selector(AppDelegate.chooseCollectionFolders(_:)), in: m)
        item("Remove Collection Folders…", #selector(AppDelegate.removeCollectionFolders(_:)), in: m)
        item("Update Collection", #selector(AppDelegate.updateCollection(_:)), "r", in: m)
        item("Full Rescan", #selector(AppDelegate.fullRescan(_:)), "r", [.command, .shift], in: m)
        m.addItem(.separator())
        item("Import Statistics from Apple Music…", #selector(AppDelegate.importAppleMusicStatistics(_:)), in: m)
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", in: m)
        item("Zoom", #selector(NSWindow.performZoom(_:)), in: m)
        m.addItem(.separator())
        item("Amamac", #selector(AppDelegate.showMainWindow(_:)), "1", in: m)
        m.addItem(.separator())
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), in: m)
        return m
    }
}
