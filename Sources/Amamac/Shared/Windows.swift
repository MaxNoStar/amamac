import AppKit

/// Tool windows that exist at most once: `show` brings the open one to the front or builds it.
@MainActor
enum SingleWindow {
    private static var windows: [String: NSWindow] = [:]

    /// `make` builds the window; it is centred, kept until it closes and made key.
    static func show(_ key: String, make: () -> NSWindow) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = make()
        window.isReleasedWhenClosed = false
        window.center()
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows[key] = nil }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Keeps windows that may be open several times (cover viewers, fetch dialogs) alive until they close.
@MainActor
enum OpenWindows {
    private static var windows: [NSWindow] = []

    static func retain(_ window: NSWindow) {
        windows.append(window)
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == id } }
        }
    }
}

/// A simple window showing a full-size cover.
@MainActor
enum CoverViewerWindow {
    static func show(image: NSImage, title: String) {
        let size = image.size
        let scale = min(1, 800 / max(size.width, size.height, 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(200, size.width * scale), height: max(200, size.height * scale)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        OpenWindows.retain(window)
    }
}
