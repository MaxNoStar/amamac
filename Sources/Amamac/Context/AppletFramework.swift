import AppKit
import SwiftUI
import AmamacCore

/// The applets the Context pane can show.
enum AppletKind: String, CaseIterable {
    case currentTrack, albums, lyrics, wikipedia, analyzer

    var title: String {
        switch self {
        case .currentTrack: "Current Track"
        case .albums: "Albums"
        case .lyrics: "Lyrics"
        case .wikipedia: "Wikipedia"
        case .analyzer: "Analyzer"
        }
    }

    var symbol: String {
        switch self {
        case .currentTrack: "music.note"
        case .albums: "square.stack"
        case .lyrics: "text.quote"
        case .wikipedia: "book"
        case .analyzer: "waveform"
        }
    }

    var summary: String {
        switch self {
        case .currentTrack: "Cover, rating and statistics of the playing track"
        case .albums: "Other albums by the current artist"
        case .lyrics: "Lyrics, synced to the music when available"
        case .wikipedia: "Wikipedia articles about the artist, album or track"
        case .analyzer: "A spectrum analyzer"
        }
    }

    var defaultHeight: CGFloat {
        switch self {
        case .currentTrack: 230
        case .albums: 280
        case .lyrics: 420
        case .wikipedia: 520
        case .analyzer: 170
        }
    }

    @MainActor
    func make(env: AppEnvironment) -> Applet {
        switch self {
        case .currentTrack: CurrentTrackAppletController(env: env)
        case .albums: AlbumsAppletController(env: env)
        case .lyrics: LyricsAppletController(env: env)
        case .wikipedia: WikipediaAppletController(env: env)
        case .analyzer: AnalyzerAppletController(env: env)
        }
    }
}

/// One applet: its content view, optional settings, and whether it is currently on screen.
@MainActor
protocol Applet: AnyObject {
    var kind: AppletKind { get }
    var contentView: NSView { get }
    /// Settings shown in a popover from the header's gear button (nil: no gear).
    func makeConfigurationView() -> AnyView?
    /// Called when the applet is shown or hidden (enabled/collapsed) so it can start or stop work.
    func setActive(_ active: Bool)
}

extension Applet {
    func makeConfigurationView() -> AnyView? { nil }
    func setActive(_ active: Bool) {}
}

/// Wraps an applet with Amarok's header (icon, title, settings, collapse) and a bottom edge that
/// can be dragged to resize it.
final class AppletContainerView: NSView {
    let applet: Applet
    private let header = AppletHeaderView()
    private let resizeHandle = AppletResizeHandle()
    private var contentHeight: NSLayoutConstraint!
    private var collapsedHeight: NSLayoutConstraint!
    private var handleHeight: NSLayoutConstraint!
    var onHeightChanged: ((CGFloat) -> Void)?
    var onCollapsedChanged: ((Bool) -> Void)?

    private(set) var isCollapsed = false

    init(applet: Applet, height: CGFloat, collapsed: Bool) {
        self.applet = applet
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("applet.\(applet.kind.rawValue)")
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        header.configure(kind: applet.kind, hasSettings: applet.makeConfigurationView() != nil)
        header.onToggle = { [weak self] in self?.setCollapsed(!(self?.isCollapsed ?? false), notify: true) }
        header.onSettings = { [weak self] button in self?.showSettings(from: button) }
        let content = applet.contentView
        for v in [header, content, resizeHandle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        contentHeight = content.heightAnchor.constraint(equalToConstant: height)
        collapsedHeight = content.heightAnchor.constraint(equalToConstant: 0)
        handleHeight = resizeHandle.heightAnchor.constraint(equalToConstant: 6)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHeight,
            resizeHandle.topAnchor.constraint(equalTo: content.bottomAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handleHeight,
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.contentHeight.constant = max(80, self.contentHeight.constant + delta)
        }
        resizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            self.onHeightChanged?(self.contentHeight.constant)
        }
        setCollapsed(collapsed, notify: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var contentHeightValue: CGFloat { contentHeight.constant }

    func setContentHeight(_ height: CGFloat) { contentHeight.constant = height }

    func setCollapsed(_ collapsed: Bool, notify: Bool) {
        isCollapsed = collapsed
        applet.contentView.isHidden = collapsed
        if collapsed {
            contentHeight.isActive = false
            collapsedHeight.isActive = true
        } else {
            collapsedHeight.isActive = false
            contentHeight.isActive = true
        }
        resizeHandle.isHidden = collapsed
        handleHeight.constant = collapsed ? 0 : 6
        header.isCollapsed = collapsed
        if notify { onCollapsedChanged?(collapsed) }
    }

    private func showSettings(from button: NSView) {
        guard let settings = applet.makeConfigurationView() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: settings.padding(14).frame(minWidth: 260))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }
}

final class AppletHeaderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let settings = NSButton()
    private let toggle = NSButton()
    var onToggle: (() -> Void)?
    var onSettings: ((NSView) -> Void)?
    var isCollapsed = false {
        didSet {
            toggle.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                                   accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        for (button, symbol, tip) in [(settings, "gearshape", "Applet Settings"), (toggle, "chevron.down", "Collapse")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.contentTintColor = .secondaryLabelColor
            button.target = self
        }
        settings.action = #selector(settingsClicked(_:))
        toggle.action = #selector(toggleClicked)
        let stack = NSStackView(views: [icon, title, NSView(), settings, toggle])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(kind: AppletKind, hasSettings: Bool) {
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        title.stringValue = kind.title
        settings.isHidden = !hasSettings
        setAccessibilityLabel(kind.title)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.withAlphaComponent(0.55).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onToggle?() }
    }

    @objc private func settingsClicked(_ sender: NSButton) { onSettings?(sender) }
    @objc private func toggleClicked() { onToggle?() }
}

/// Drag strip at the bottom of an applet.
final class AppletResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastY: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 1, width: 28, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { lastY = NSEvent.mouseLocation.y }

    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        if let lastY { onDrag?(lastY - y) }
        lastY = y
    }

    override func mouseUp(with event: NSEvent) {
        lastY = nil
        onDragEnded?()
    }
}

/// Tabs for the enabled applets (click scrolls to the applet; drag to reorder) and the checkable
/// "Configure Applets" button.
final class AppletTabBar: NSView {
    var kinds: [AppletKind] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var onSelect: ((AppletKind) -> Void)?
    var onReorder: (([AppletKind]) -> Void)?
    let configureButton = NSButton(title: "Configure Applets", target: nil, action: nil)
    private var dragIndex: Int?
    private var dragX: CGFloat = 0
    private var dragStartX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("appletTabBar")
        configureButton.setButtonType(.pushOnPushOff)
        configureButton.bezelStyle = .recessed
        configureButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        configureButton.imagePosition = .imageLeading
        configureButton.controlSize = .small
        configureButton.font = .systemFont(ofSize: 11)
        configureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(configureButton)
        NSLayoutConstraint.activate([
            configureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            configureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityRole(.tabGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private let tabWidth: CGFloat = 112

    private func tabRect(_ i: Int) -> NSRect {
        NSRect(x: 8 + CGFloat(i) * (tabWidth + 4), y: 4, width: tabWidth, height: bounds.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for (i, kind) in kinds.enumerated() {
            var rect = tabRect(i)
            if i == dragIndex { rect.origin.x += dragX - dragStartX }
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            (i == dragIndex ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
            if let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                image.draw(in: NSRect(x: rect.minX + 7, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: kind.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                                                .paragraphStyle: style])
                .draw(with: NSRect(x: rect.minX + 26, y: rect.midY - 7, width: rect.width - 32, height: 14),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func index(at point: NSPoint) -> Int? {
        kinds.indices.first { tabRect($0).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragIndex = index(at: p)
        dragStartX = p.x
        dragX = p.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragIndex = nil; needsDisplay = true }
        guard let from = dragIndex else { return }
        if abs(dragX - dragStartX) < 4 {
            onSelect?(kinds[from])
            return
        }
        let target = max(0, min(kinds.count - 1, Int(((tabRect(from).midX + dragX - dragStartX) - 8) / (tabWidth + 4))))
        guard target != from else { return }
        var new = kinds
        new.insert(new.remove(at: from), at: target)
        kinds = new
        onReorder?(new)
    }

    override func accessibilityChildren() -> [Any]? {
        kinds.enumerated().map { i, kind in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.radioButton)
            element.setAccessibilityLabel(kind.title)
            element.setAccessibilityFrameInParentSpace(tabRect(i))
            element.setAccessibilityParent(self)
            return element
        }
    }
}

/// The strip of all applets shown while "Configure Applets" is on: toggles to add or remove.
struct AppletStrip: View {
    let enabled: [AppletKind]
    let onToggle: (AppletKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppletKind.allCases, id: \.self) { kind in
                    let on = enabled.contains(kind)
                    Button { onToggle(kind) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol).font(.system(size: 20))
                            Text(kind.title).font(.caption.weight(.semibold))
                            Text(kind.summary).font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).lineLimit(2)
                        }
                        .frame(width: 130, height: 76)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.amamacAccent.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.amamacAccent : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Remove \(kind.title)" : "Add \(kind.title)")
                }
            }
            .padding(10)
        }
    }
}

/// Hosts a SwiftUI view as an applet's content.
final class HostedAppletView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }
}
