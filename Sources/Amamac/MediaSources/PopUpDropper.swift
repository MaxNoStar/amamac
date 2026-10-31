import AppKit

/// Amarok's Pop-Up Dropper: while tracks are dragged out of Media Sources, large drop targets
/// appear over the Context pane (Append, Replace, Queue, Append and Play).
final class PopUpDropper: NSView {
    private let items: [PopUpDropperItem]
    private let stack = NSStackView()

    init(actions: LibraryActions) {
        items = [
            PopUpDropperItem(title: "Append to Playlist", symbol: "text.badge.plus", mode: .append, actions: actions),
            PopUpDropperItem(title: "Replace Playlist", symbol: "arrow.triangle.2.circlepath", mode: .replace, actions: actions),
            PopUpDropperItem(title: "Queue Tracks", symbol: "list.number", mode: .queue, actions: actions),
            PopUpDropperItem(title: "Append and Play", symbol: "play.circle", mode: .appendAndPlay, actions: actions),
        ]
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("popUpDropper")
        wantsLayer = true
        isHidden = true
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for item in items {
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 56).isActive = true
            item.onDrop = { [weak self] in self?.hide() }
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
        bounds.fill()
    }

    // Let clicks through when hidden; while visible the overlay only matters for drags.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    func show(for session: NSDraggingSession) {
        guard isHidden else { return }
        alphaValue = 0
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isHidden = true
                self?.items.forEach { $0.highlighted = false }
            }
        })
    }
}

final class PopUpDropperItem: NSView {
    let title: String
    let symbol: String
    let mode: LibraryActions.AddMode
    private unowned let actions: LibraryActions
    var onDrop: (() -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, mode: LibraryActions.AddMode, actions: LibraryActions) {
        self.title = title
        self.symbol = symbol
        self.mode = mode
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.amamacTracks, .fileURL])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        (highlighted ? NSColor.amamacAccent : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let color: NSColor = highlighted ? .white : .labelColor
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular).applying(.init(paletteColors: [color]))) {
            let size = image.size
            image.draw(in: NSRect(x: 18, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                                   .foregroundColor: color])
        text.draw(at: NSPoint(x: 56, y: (bounds.height - text.size().height) / 2))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        let pasteboard = sender.draggingPasteboard
        let tracks = actions.tracks(fromPasteboard: pasteboard)
        if !tracks.isEmpty {
            actions.addToPlaylist(tracks, mode: mode)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            actions.addURLs(urls, mode: mode)
        }
        onDrop?()
        return true
    }
}
