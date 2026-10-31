import AmamacModels
import AppKit
import SwiftUI

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
