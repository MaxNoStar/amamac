import AmamacBase
import AmamacModels
import AppKit
import SwiftUI

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
