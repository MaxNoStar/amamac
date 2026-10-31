// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AppKit
import WebKit

/// Offscreen-free window capture for automated visual checks (`--snapshot`). Renders AppKit and
/// SwiftUI content with `cacheDisplay` and composites WKWebView content from `takeSnapshot`, which
/// `cacheDisplay` cannot see. Needs no screen-recording permission.
enum Snapshotter {
    /// Renders `view` into a PNG, at 1× unless `scale` says otherwise.
    static func capture(_ view: NSView, to url: URL, scale: CGFloat = 1) async {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        // Composite web views.
        let webViews = descendants(of: view).compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        if !webViews.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            for web in webViews {
                guard let image = try? await web.takeSnapshot(configuration: nil) else { continue }
                var rect = web.convert(web.bounds, to: view)
                if view.isFlipped { rect.origin.y = bounds.height - rect.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Writes a JSON description of the view tree: class, frame (window coordinates, top-left
    /// origin), visibility, identifier and visible text.
    static func dumpLayout(of window: NSWindow, to url: URL) {
        guard let root = window.contentView else { return }
        let height = root.bounds.height
        func describe(_ view: NSView) -> [String: Any] {
            var frame = view.convert(view.bounds, to: nil)
            frame.origin.y = height - frame.maxY
            var info: [String: Any] = [
                "class": String(describing: type(of: view)),
                "frame": [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)],
            ]
            if view.isHidden { info["hidden"] = true }
            if let id = view.identifier?.rawValue, !id.hasPrefix("_") { info["id"] = id }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { info["text"] = field.stringValue }
            if let button = view as? NSButton, !button.title.isEmpty { info["text"] = button.title }
            if let label = view.accessibilityLabel(), !label.isEmpty { info["label"] = label }
            let children = view.subviews.filter { !$0.isHidden }.map(describe)
            if !children.isEmpty { info["children"] = children }
            return info
        }
        let json: [String: Any] = ["window": [Int(window.frame.width), Int(window.frame.height)], "root": describe(root)]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Exits the process if automation hangs.
    static func startWatchdog(seconds: Double = 90) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            FileHandle.standardError.write("Snapshot watchdog fired after \(Int(seconds)) s\n".data(using: .utf8)!)
            exit(2)
        }
    }

    /// Polls `condition` until true or the timeout elapses.
    static func waitUntil(timeout: Double = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
