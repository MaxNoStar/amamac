import AmamacModels
import AmamacPlaylist
import AppKit

/// Home › Category › Level crumbs with a bookmark menu.
final class BreadcrumbBar: NSView {
    var crumbs: [(String, String)] = [] { didSet { rebuild() } }
    var onSelect: ((Int) -> Void)?
    var onHome: (() -> Void)?
    var bookmarkMenuProvider: (() -> NSMenu)?
    private let stack = NSStackView()
    private let bookmarkButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("breadcrumb")
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bookmarkButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmarks")
        bookmarkButton.isBordered = false
        bookmarkButton.toolTip = "Bookmarks"
        bookmarkButton.target = self
        bookmarkButton.action = #selector(showBookmarks(_:))
        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(bookmarkButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bookmarkButton.leadingAnchor, constant: -4),
            bookmarkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bookmarkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let home = crumbButton(title: nil, symbol: "house", tag: -1)
        home.toolTip = "Home"
        stack.addArrangedSubview(home)
        for (i, crumb) in crumbs.enumerated() {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
            chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor
            stack.addArrangedSubview(chevron)
            let b = crumbButton(title: crumb.0, symbol: crumb.1, tag: i + 1)
            if i == crumbs.count - 1 { b.font = .boldSystemFont(ofSize: 12) }
            stack.addArrangedSubview(b)
        }
    }

    private func crumbButton(title: String?, symbol: String, tag: Int) -> NSButton {
        let b = NSButton(title: title ?? "", image: NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? "Home")!,
                         target: self, action: #selector(crumbClicked(_:)))
        b.isBordered = false
        b.imagePosition = title == nil ? .imageOnly : .imageLeading
        b.font = .systemFont(ofSize: 12)
        b.tag = tag
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        if sender.tag < 0 { onHome?() } else { onSelect?(sender.tag) }
    }

    @objc private func showBookmarks(_ sender: NSButton) {
        guard let menu = bookmarkMenuProvider?() ?? defaultBookmarkMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func defaultBookmarkMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Bookmark Manager", action: #selector(ToolsCommands.showBookmarkManager(_:)), keyEquivalent: "")
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
