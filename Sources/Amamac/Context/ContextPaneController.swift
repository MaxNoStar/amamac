import AppKit
import SwiftUI

/// The middle "Context" pane: a scrolling column of applets, the applet tab bar with
/// "Configure Applets", and the Pop-Up Dropper overlay.
final class ContextPaneController: NSViewController {
    let env: AppEnvironment
    private let dropper = PopUpDropper()
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let tabBar = AppletTabBar()
    private var strip: NSHostingView<AppletStrip>!
    private var stripHeight: NSLayoutConstraint!
    private var applets: [AppletKind: Applet] = [:]
    private var containers: [AppletKind: AppletContainerView] = [:]

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The scrolling column of applets (snapshots capture all of it).
    var appletColumn: NSView? { scroll.documentView }

    var enabledKinds: [AppletKind] {
        env.settings.enabledApplets.compactMap(AppletKind.init(rawValue:))
    }

    override func loadView() {
        let root = NSView()
        root.identifier = NSUserInterfaceItemIdentifier("contextPane")

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let document = FlippedView()
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        strip = NSHostingView(rootView: makeStrip())
        strip.sizingOptions = []
        strip.isHidden = true
        tabBar.configureButton.target = self
        tabBar.configureButton.action = #selector(toggleConfigure(_:))
        tabBar.onSelect = { [weak self] kind in self?.scroll(to: kind) }
        tabBar.onReorder = { [weak self] kinds in self?.setEnabled(kinds) }

        for v in [scroll, strip!, tabBar, dropper] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripHeight,
            tabBar.topAnchor.constraint(equalTo: strip.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dropper.topAnchor.constraint(equalTo: root.topAnchor),
            dropper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dropper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dropper.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        PopUpDropper.shared = dropper
        rebuild()
    }

    // MARK: Applets

    func applet(_ kind: AppletKind) -> Applet {
        if let existing = applets[kind] { return existing }
        let made = kind.make(env: env)
        applets[kind] = made
        return made
    }

    private func rebuild() {
        let kinds = enabledKinds
        let collapsed = Set(env.settings.defaults.stringArray(forKey: AppSettings.Key.collapsedApplets) ?? [])
        let heights = env.settings.defaults.dictionary(forKey: AppSettings.Key.appletHeights) as? [String: Double] ?? [:]
        for view in column.arrangedSubviews { view.removeFromSuperview() }
        for (kind, container) in containers where !kinds.contains(kind) {
            container.applet.setActive(false)
            containers[kind] = nil
        }
        for kind in kinds {
            let container = containers[kind] ?? {
                let c = AppletContainerView(applet: applet(kind), height: heights[kind.rawValue].map { CGFloat($0) } ?? kind.defaultHeight,
                                            collapsed: collapsed.contains(kind.rawValue))
                c.onHeightChanged = { [weak self] height in self?.saveHeight(kind, height) }
                c.onCollapsedChanged = { [weak self] value in self?.saveCollapsed(kind, value) }
                containers[kind] = c
                return c
            }()
            column.addArrangedSubview(container)
            container.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 10).isActive = true
            container.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -10).isActive = true
            container.applet.setActive(!container.isCollapsed)
        }
        if kinds.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: "No applets are shown. Use Configure Applets below to add some.")
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            column.addArrangedSubview(hint)
        }
        tabBar.kinds = kinds
        strip.rootView = makeStrip()
    }

    func setEnabled(_ kinds: [AppletKind]) {
        env.settings.enabledApplets = kinds.map(\.rawValue)
        rebuild()
    }

    private func saveHeight(_ kind: AppletKind, _ height: CGFloat) {
        var heights = env.settings.defaults.dictionary(forKey: AppSettings.Key.appletHeights) as? [String: Double] ?? [:]
        heights[kind.rawValue] = Double(height)
        env.settings.set(heights, AppSettings.Key.appletHeights)
    }

    private func saveCollapsed(_ kind: AppletKind, _ collapsed: Bool) {
        var set = Set(env.settings.defaults.stringArray(forKey: AppSettings.Key.collapsedApplets) ?? [])
        if collapsed { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
        env.settings.set(Array(set), AppSettings.Key.collapsedApplets)
        containers[kind]?.applet.setActive(!collapsed)
    }

    private func makeStrip() -> AppletStrip {
        AppletStrip(enabled: enabledKinds) { [weak self] kind in
            guard let self else { return }
            var kinds = self.enabledKinds
            if let i = kinds.firstIndex(of: kind) { kinds.remove(at: i) } else { kinds.append(kind) }
            self.setEnabled(kinds)
            if kinds.contains(kind) { DispatchQueue.main.async { self.scroll(to: kind) } }
        }
    }

    @objc private func toggleConfigure(_ sender: NSButton) {
        let show = sender.state == .on
        strip.isHidden = !show
        stripHeight.constant = show ? 100 : 0
    }

    func scroll(to kind: AppletKind) {
        guard let container = containers[kind], let document = scroll.documentView else { return }
        view.layoutSubtreeIfNeeded()
        let frame = container.convert(container.bounds, to: document)
        let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(0, frame.minY - 10), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
