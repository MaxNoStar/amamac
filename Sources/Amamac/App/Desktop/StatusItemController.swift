import AmamacBase
import AmamacModels
import AppKit

/// The menu bar ("tray") icon: click shows or hides the window, right-click opens a menu, scrolling
/// changes the volume and a middle click plays or pauses.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let env: AppEnvironment
    private weak var mainWindow: MainWindowController?
    private var item: NSStatusItem?
    private var monitor: Any?

    init(env: AppEnvironment, mainWindow: MainWindowController) {
        self.env = env
        self.mainWindow = mainWindow
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.setAccessibilityLabel("Amamac")
            self.item = item
            // Local monitors run on the main thread.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
            update()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }

    func update() {
        guard let button = item?.button else { return }
        let player = env.player
        let symbol = player.state == .playing || player.state == .buffering ? "music.note.list" : "music.note"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Amamac")
        button.image?.isTemplate = true
        if let current = player.currentItem, player.isActive {
            button.toolTip = [current.streamTitle ?? current.track.displayTitle, current.track.artist].filter { !$0.isEmpty }.joined(separator: " – ")
                + (player.state == .paused ? " (paused)" : "")
        } else {
            button.toolTip = "Amamac"
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let button = item?.button, event.window === button.window else { return event }
        switch event.type {
        case .scrollWheel:
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.1 else { return nil }
            env.player.setVolume(env.player.volume + (delta > 0 ? 2 : -2))
            return nil
        case .otherMouseUp:
            env.player.playPause()
            return nil
        default:
            return event
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.delegate = self
            item?.menu = menu
            sender.performClick(nil)
            item?.menu = nil
        } else if let window = mainWindow?.window {
            if window.isVisible && NSApp.isActive && window.isKeyWindow {
                window.orderOut(nil)
            } else {
                NSApp.activate()
                mainWindow?.showWindow(nil)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let player = env.player
        if let current = player.currentItem, player.isActive {
            let title = NSMenuItem(title: [current.streamTitle ?? current.track.displayTitle, current.track.artist]
                .filter { !$0.isEmpty }.joined(separator: " – "), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let playing = player.state == .playing || player.state == .buffering
        for (title, selector) in [(playing ? "Pause" : "Play", #selector(PlaybackCommands.playPause(_:))),
                                  ("Stop", #selector(PlaybackCommands.stopPlayback(_:))),
                                  ("Previous Track", #selector(PlaybackCommands.previousTrack(_:))),
                                  ("Next Track", #selector(PlaybackCommands.nextTrack(_:)))] {
            menu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Amamac", action: #selector(showWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(NSMenuItem(title: "Quit Amamac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    @objc private func showWindow(_ sender: Any?) {
        NSApp.activate()
        mainWindow?.showWindow(nil)
    }
}
