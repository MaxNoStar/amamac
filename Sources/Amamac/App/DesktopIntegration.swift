import AmamacBase
import AmamacModels
import AppKit
import IOKit.pwr_mgt
import KeyboardShortcuts
import SwiftUI
import UserNotifications

/// Everything outside the main window: the on-screen display, the menu bar item, global
/// shortcuts, system notifications and sleep handling. Created once at launch.
@MainActor
final class DesktopIntegration {
    let osd: OSDController
    let statusItem: StatusItemController
    private let notifier = TrackNotifier()
    private let sleep: SleepInhibitor
    private unowned let env: AppEnvironment
    private weak var mainWindow: MainWindowController?
    private var lastState: PlayerController.State = .stopped

    init(env: AppEnvironment, mainWindow: MainWindowController) {
        self.env = env
        self.mainWindow = mainWindow
        osd = OSDController(env: env)
        statusItem = StatusItemController(env: env, mainWindow: mainWindow)
        sleep = SleepInhibitor(env: env)
        lastState = env.player.state
        env.player.addListener { [weak self] event in self?.handle(event) }
        HotKeys.register(env: env, osd: osd)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: env.settings.defaults,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        statusItem.setVisible(env.settings.bool(AppSettings.Key.showTrayIcon))
        sleep.update()
    }

    private func handle(_ event: PlayerController.PlayerEvent) {
        let player = env.player
        switch event {
        case .trackChanged:
            statusItem.update()
            guard let item = player.currentItem, player.state == .playing || player.state == .buffering else { return }
            osd.showTrack(item)
            notifier.trackChanged(item, env: env)
            if env.settings.bool(AppSettings.Key.autoScrollPlaylist) { mainWindow?.playlistPane.scrollToActive() }
            fetchCoverIfMissing(item)
        case .stateChanged:
            statusItem.update()
            sleep.update()
            switch (lastState, player.state) {
            case (.playing, .paused), (.buffering, .paused): osd.showMessage("Paused", symbol: "pause.fill")
            case (.paused, .playing): if let item = player.currentItem { osd.showTrack(item) }
            case (.playing, .stopped), (.paused, .stopped): osd.showMessage("Stopped", symbol: "stop.fill")
            default: break
            }
            lastState = player.state
        case .volumeChanged:
            if player.isMuted {
                osd.showMessage("Muted", symbol: "speaker.slash.fill")
            } else {
                osd.showMessage("Volume \(player.volume)%", symbol: "speaker.wave.2.fill", level: Double(player.volume) / 100)
            }
        case .streamTitleChanged:
            if let item = player.currentItem, player.state == .playing { osd.showTrack(item) }
            statusItem.update()
        case .seeked:
            break
        }
    }

    /// "Fetch missing covers automatically": look the playing album up once per session.
    private var coverLookups = Set<String>()
    private func fetchCoverIfMissing(_ item: PlaylistItem) {
        let track = item.track
        guard env.settings.bool(AppSettings.Key.autoFetchCovers), item.source == .collection, !track.album.isEmpty,
              coverLookups.insert(track.albumKey).inserted else { return }
        let env = self.env
        Task {
            guard await env.covers.cover(albumKey: track.albumKey, size: 64) == nil else { return }
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            _ = await CoverActions.fetchAutomatically(AlbumReference(albumKey: track.albumKey, album: track.album, artist: artist,
                                                                     releaseId: track.mbReleaseId.isEmpty ? nil : track.mbReleaseId), env: env)
        }
    }
}

// MARK: - On-screen display

/// What the OSD shows.
enum OSDContent: Equatable {
    case track(title: String, detail: String, rating: Int?, length: String, albumKey: String?)
    case message(String, symbol: String, level: Double?)
}

struct OSDStyle: Equatable {
    var translucent = true
    var fontScale = 1.15
    var textColor = Color.white
}

/// A borderless panel that never takes focus and lets clicks through (except while previewing,
/// when it can be dragged into place).
@MainActor
final class OSDController {
    private unowned let env: AppEnvironment
    private var panel: NSPanel?
    private var host: NSHostingView<OSDView>?
    private var hideTask: Task<Void, Never>?
    private(set) var isPreviewing = false
    private var moveObserver: NSObjectProtocol?

    init(env: AppEnvironment) { self.env = env }

    var style: OSDStyle {
        let s = env.settings
        return OSDStyle(translucent: s.bool(AppSettings.Key.osdTranslucent), fontScale: Double(s.int(AppSettings.Key.osdFontScale)) / 100,
                        textColor: s.string(AppSettings.Key.osdTextColor).flatMap(NSColor.init(hex:)).map(Color.init(nsColor:)) ?? .white)
    }

    func showTrack(_ item: PlaylistItem, force: Bool = false) {
        let track = item.track
        let title = item.streamTitle ?? track.displayTitle
        let detail = item.streamTitle != nil ? track.displayTitle
            : [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        let rating = item.source == .collection ? item.statistics?.rating ?? 0 : nil
        let length = item.duration > 0 ? TimeFormatting.duration(item.duration) : ""
        show(.track(title: title, detail: detail, rating: rating, length: length,
                    albumKey: item.source == .collection && !track.album.isEmpty ? track.albumKey : nil), force: force)
    }

    func showMessage(_ text: String, symbol: String, level: Double? = nil, force: Bool = false) {
        show(.message(text, symbol: symbol, level: level), force: force)
    }

    func show(_ content: OSDContent, force: Bool = false) {
        guard force || isPreviewing || (env.settings.bool(AppSettings.Key.osdEnabled) && !hiddenForFullScreen) else { return }
        let panel = makePanel()
        let view = OSDView(content: content, style: style, cover: nil)
        host?.rootView = view
        if case .track(_, _, _, _, let key?) = content {
            Task {
                let image = await env.coverImages.image(albumKey: key, size: 100)
                if host?.rootView.content == content { host?.rootView = OSDView(content: content, style: style, cover: image); resize() }
            }
        }
        resize()
        if !isPreviewing { place(panel) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        guard !isPreviewing else { return }
        let duration = max(1000, env.settings.int(AppSettings.Key.osdDuration))
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(duration))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled && !isPreviewing { panel.orderOut(nil) }
        }
    }

    /// Shows a sample that can be dragged; its position is saved as it moves.
    func setPreviewing(_ on: Bool) {
        isPreviewing = on
        let panel = makePanel()
        panel.ignoresMouseEvents = !on
        panel.isMovableByWindowBackground = on
        if on {
            show(.track(title: "Drag me where the OSD should appear", detail: "Amamac — On-Screen Display", rating: 8, length: "3:45", albumKey: nil))
            place(panel)
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.savePosition() }
            }
        } else {
            moveObserver.map(NotificationCenter.default.removeObserver)
            moveObserver = nil
            panel.orderOut(nil)
        }
    }

    /// The panel's content view, for snapshots.
    var contentView: NSView? { panel?.contentView }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OSDView(content: .message("", symbol: "music.note", level: nil), style: style, cover: nil))
        // The panel takes the view's natural size (see `resize`).
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    private func resize() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        if !isPreviewing { place(panel) }
    }

    private var screen: NSScreen {
        let index = env.settings.int(AppSettings.Key.osdScreen)
        if index > 0, NSScreen.screens.indices.contains(index - 1) { return NSScreen.screens[index - 1] }
        return env.router?.windowScreen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Position as fractions of the screen's visible area (0,0 bottom left).
    private func place(_ panel: NSPanel) {
        let stored = (env.settings.defaults.array(forKey: AppSettings.Key.osdPosition) as? [Double]) ?? [0.5, 0.9]
        let fx = stored.first ?? 0.5, fy = stored.dropFirst().first ?? 0.9
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.minX + fx * max(0, area.width - size.width),
                                     y: area.minY + fy * max(0, area.height - size.height)))
    }

    private func savePosition() {
        guard let panel else { return }
        let area = (panel.screen ?? screen).visibleFrame
        let size = panel.frame.size
        let fx = area.width > size.width ? (panel.frame.minX - area.minX) / (area.width - size.width) : 0.5
        let fy = area.height > size.height ? (panel.frame.minY - area.minY) / (area.height - size.height) : 0.9
        env.settings.set([min(1, max(0, fx)), min(1, max(0, fy))], AppSettings.Key.osdPosition)
        if let index = NSScreen.screens.firstIndex(where: { $0 == panel.screen }) {
            env.settings.set(index + 1, AppSettings.Key.osdScreen)
        }
    }

    /// True when another app is in full-screen on the OSD's screen (and the setting asks to hide).
    private var hiddenForFullScreen: Bool {
        guard env.settings.bool(AppSettings.Key.osdHideWhenFullscreen),
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return false }
        let screenFrame = screen.frame
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return Int(bounds["Width"] ?? 0) == Int(screenFrame.width) && Int(bounds["Height"] ?? 0) == Int(screenFrame.height)
        }
    }
}

struct OSDView: View {
    let content: OSDContent
    let style: OSDStyle
    let cover: NSImage?

    var body: some View {
        let scale = style.fontScale
        Group {
            switch content {
            case .track(let title, let detail, let rating, let length, _):
                HStack(spacing: 14 * scale) {
                    Group {
                        if let cover {
                            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 30 * scale)).foregroundStyle(style.textColor.opacity(0.7))
                        }
                    }
                    .frame(width: 64 * scale, height: 64 * scale)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        Text(title).font(.system(size: 17 * scale, weight: .bold)).lineLimit(1)
                        if !detail.isEmpty { Text(detail).font(.system(size: 13 * scale)).opacity(0.85).lineLimit(1) }
                        HStack(spacing: 8) {
                            if let rating {
                                Text(RatingText.stars(rating)).font(.system(size: 12 * scale)).opacity(0.9)
                            }
                            if !length.isEmpty { Text(length).font(.system(size: 12 * scale).monospacedDigit()).opacity(0.75) }
                        }
                    }
                    .frame(maxWidth: 460 * scale, alignment: .leading)
                }
            case .message(let text, let symbol, let level):
                HStack(spacing: 12 * scale) {
                    Image(systemName: symbol).font(.system(size: 24 * scale))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text).font(.system(size: 17 * scale, weight: .semibold))
                        if let level {
                            ProgressView(value: level).progressViewStyle(.linear).tint(style.textColor).frame(width: 180 * scale)
                        }
                    }
                }
            }
        }
        .foregroundStyle(style.textColor)
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 14 * scale)
        .background {
            if style.translucent {
                VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12))
            }
        }
        .fixedSize()
    }
}

/// HUD material behind the OSD.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Menu bar item

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

// MARK: - Global shortcuts

extension KeyboardShortcuts.Name {
    static let playPause = Self("playPause", initial: .init(.p, modifiers: [.control, .option]))
    static let nextTrack = Self("nextTrack", initial: .init(.rightArrow, modifiers: [.control, .option]))
    static let previousTrack = Self("previousTrack", initial: .init(.leftArrow, modifiers: [.control, .option]))
    static let stopPlayback = Self("stopPlayback")
    static let stopAfterCurrent = Self("stopAfterCurrent", initial: .init(.v, modifiers: [.control, .option, .shift]))
    static let volumeUp = Self("volumeUp", initial: .init(.equal, modifiers: [.control, .option]))
    static let volumeDown = Self("volumeDown", initial: .init(.minus, modifiers: [.control, .option]))
    static let toggleMute = Self("toggleMute", initial: .init(.m, modifiers: [.control, .option]))
    static let showOSD = Self("showOSD", initial: .init(.o, modifiers: [.control, .option]))
    static let addMedia = Self("addMedia", initial: .init(.a, modifiers: [.control, .option]))
    static let rate1 = Self("rate1", initial: .init(.one, modifiers: [.control, .option]))
    static let rate2 = Self("rate2", initial: .init(.two, modifiers: [.control, .option]))
    static let rate3 = Self("rate3", initial: .init(.three, modifiers: [.control, .option]))
    static let rate4 = Self("rate4", initial: .init(.four, modifiers: [.control, .option]))
    static let rate5 = Self("rate5", initial: .init(.five, modifiers: [.control, .option]))
}

@MainActor
enum HotKeys {
    static let all: [(KeyboardShortcuts.Name, String)] = [
        (.playPause, "Play / Pause"), (.stopPlayback, "Stop"), (.nextTrack, "Next Track"), (.previousTrack, "Previous Track"),
        (.stopAfterCurrent, "Stop After Current Track"), (.volumeUp, "Increase Volume"), (.volumeDown, "Decrease Volume"),
        (.toggleMute, "Mute"), (.showOSD, "Show On-Screen Display"), (.addMedia, "Add Media…"),
        (.rate1, "Rate ★"), (.rate2, "Rate ★★"), (.rate3, "Rate ★★★"), (.rate4, "Rate ★★★★"), (.rate5, "Rate ★★★★★"),
    ]

    static func register(env: AppEnvironment, osd: OSDController) {
        let player = env.player
        KeyboardShortcuts.onKeyUp(for: .playPause) { player.playPause() }
        KeyboardShortcuts.onKeyUp(for: .stopPlayback) { player.stop() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { player.next() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { player.previous() }
        KeyboardShortcuts.onKeyUp(for: .stopAfterCurrent) {
            player.toggleStopAfterCurrent()
            let on = env.playlist.stopAfterID != nil
            osd.showMessage(on ? "Stop after this track" : "Continue after this track", symbol: on ? "stop.circle" : "play.circle")
        }
        KeyboardShortcuts.onKeyUp(for: .volumeUp) { player.setVolume(player.volume + 5) }
        KeyboardShortcuts.onKeyUp(for: .volumeDown) { player.setVolume(player.volume - 5) }
        KeyboardShortcuts.onKeyUp(for: .toggleMute) { player.toggleMute() }
        KeyboardShortcuts.onKeyUp(for: .showOSD) {
            if let item = player.currentItem, player.isActive { osd.show(trackContent(item, osd: osd), force: true) } else {
                osd.show(.message("Nothing is playing", symbol: "music.note", level: nil), force: true)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .addMedia) {
            NSApp.activate()
            NSApp.sendAction(#selector(PlaylistCommands.addMedia(_:)), to: nil, from: nil)
        }
        for (stars, name) in [(1, KeyboardShortcuts.Name.rate1), (2, .rate2), (3, .rate3), (4, .rate4), (5, .rate5)] {
            KeyboardShortcuts.onKeyUp(for: name) {
                guard let id = player.currentItem?.track.id, player.currentItem?.source == .collection else { return }
                player.setRating(stars * 2, trackId: id)
                osd.showMessage("Rated " + RatingText.stars(stars * 2), symbol: "star.fill")
            }
        }
    }

    private static func trackContent(_ item: PlaylistItem, osd: OSDController) -> OSDContent {
        let track = item.track
        return .track(title: item.streamTitle ?? track.displayTitle,
                      detail: [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "),
                      rating: item.source == .collection ? item.statistics?.rating ?? 0 : nil,
                      length: item.duration > 0 ? TimeFormatting.duration(item.duration) : "",
                      albumKey: item.source == .collection && !track.album.isEmpty ? track.albumKey : nil)
    }
}

// MARK: - System notifications

/// Optional Notification Center banners on track changes while Amamac is in the background.
@MainActor
final class TrackNotifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func trackChanged(_ item: PlaylistItem, env: AppEnvironment) {
        guard env.settings.bool(AppSettings.Key.systemNotifications), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = item.streamTitle ?? item.track.displayTitle
        content.body = [item.track.artist, item.track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        let key = item.track.albumKey
        Task {
            if item.source == .collection, let cover = await env.covers.cover(albumKey: key, size: 128) {
                // The attachment is moved into the notification store, so hand over a copy.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + cover.pathExtension)
                if (try? FileManager.default.copyItem(at: cover, to: copy)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "cover", url: copy) {
                    content.attachments = [attachment]
                }
            }
            let request = UNNotificationRequest(identifier: "nowPlaying", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Sleep

/// Keeps the Mac from idling to sleep while music plays, and pauses before the Mac sleeps.
@MainActor
final class SleepInhibitor {
    private unowned let env: AppEnvironment
    private var assertion: IOPMAssertionID = 0

    init(env: AppEnvironment) {
        self.env = env
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
    }

    func update() {
        let playing = env.player.state == .playing || env.player.state == .buffering
        let want = playing && env.settings.bool(AppSettings.Key.inhibitSleep)
        if want, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Amamac is playing music" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func willSleep() {
        if env.settings.bool(AppSettings.Key.pauseOnSleep), env.player.state == .playing { env.player.pause() }
    }
}
