import AmamacModels
import AmamacPlaylist
import AppKit

/// "Sort: › Album ↑ › Title ↓ › +" above the playlist. The root crumb clears sorting; clicking a
/// level flips its direction; its menu changes or removes it; "+" adds a level.
final class SortBreadcrumbBar: NSView {
    var levels: [PlaylistSortLevel] = [] { didSet { if levels != oldValue { rebuild() } } }
    var onChange: (([PlaylistSortLevel]) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("sortBreadcrumb")
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let root = crumbButton(title: "Playlist", symbol: "list.bullet")
        root.toolTip = levels.isEmpty ? "The playlist is in its original order" : "Clear sorting (original order)"
        root.target = self
        root.action = #selector(clearSort)
        stack.addArrangedSubview(root)
        for (i, level) in levels.enumerated() {
            stack.addArrangedSubview(chevron())
            let arrow = level.column == nil ? "" : (level.ascending ? " ↑" : " ↓")
            let button = crumbButton(title: level.displayName + arrow, symbol: nil)
            button.tag = i
            button.target = self
            button.action = #selector(toggleLevel(_:))
            button.toolTip = "Click to reverse; right-click for options"
            button.menu = levelMenu(index: i)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(chevron())
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Sort Level")!,
                           target: self, action: #selector(showAddMenu(_:)))
        add.isBordered = false
        add.toolTip = "Add a sort level"
        stack.addArrangedSubview(add)
    }

    private func crumbButton(title: String, symbol: String?) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = true
        b.font = .systemFont(ofSize: 11)
        b.controlSize = .small
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        return b
    }

    private func chevron() -> NSView {
        let v = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)!)
        v.contentTintColor = .tertiaryLabelColor
        return v
    }

    private func columnMenu(action: Selector, tagBase: Int) -> NSMenu {
        let menu = NSMenu()
        let used = Set(levels.map(\.column))
        let shuffle = NSMenuItem(title: "Shuffle", action: action, keyEquivalent: "")
        shuffle.target = self
        shuffle.tag = tagBase
        shuffle.representedObject = PlaylistSortLevel.shuffle
        shuffle.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)
        shuffle.isEnabled = !used.contains(nil)
        menu.addItem(shuffle)
        menu.addItem(.separator())
        for column in PlaylistColumn.sortable {
            let item = NSMenuItem(title: column.displayName, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tagBase
            item.representedObject = PlaylistSortLevel(column: column)
            item.isEnabled = !used.contains(column)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    private func levelMenu(index: Int) -> NSMenu {
        let menu = NSMenu()
        let change = NSMenuItem(title: "Change Level", action: nil, keyEquivalent: "")
        change.submenu = columnMenu(action: #selector(replaceLevel(_:)), tagBase: index)
        menu.addItem(change)
        let remove = NSMenuItem(title: "Remove This Level", action: #selector(removeLevel(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = index
        menu.addItem(remove)
        return menu
    }

    @objc private func clearSort() { commit([]) }

    @objc private func toggleLevel(_ sender: NSButton) {
        var new = levels
        guard sender.tag < new.count else { return }
        if new[sender.tag].column == nil {
            commit(new, reshuffle: true)
            return
        }
        new[sender.tag].ascending.toggle()
        commit(new)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = columnMenu(action: #selector(addLevel(_:)), tagBase: levels.count)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func addLevel(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? PlaylistSortLevel else { return }
        commit(levels + [level], reshuffle: level.column == nil)
    }

    @objc private func replaceLevel(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? PlaylistSortLevel, sender.tag < levels.count else { return }
        var new = levels
        new[sender.tag] = level
        commit(new, reshuffle: level.column == nil)
    }

    @objc private func removeLevel(_ sender: NSMenuItem) {
        guard sender.tag < levels.count else { return }
        var new = levels
        new.remove(at: sender.tag)
        commit(new)
    }

    var onReshuffle: (() -> Void)?

    private func commit(_ new: [PlaylistSortLevel], reshuffle: Bool = false) {
        if reshuffle { onReshuffle?() }
        levels = new
        onChange?(new)
    }
}

/// The progressive search bar: field, Previous / Next match, and the search preferences menu.
final class ProgressiveSearchBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let previous = NSButton()
    private let next = NSButton()
    private let options = NSButton()
    var fields: PlaylistSearchFields = .default
    var showOnlyMatches = false
    var onSearch: ((String) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onOptionsChanged: (() -> Void)?

    /// Set by the controller: the field tints red when text matches nothing.
    var hasNoMatch = false {
        didSet {
            field.layer?.backgroundColor = hasNoMatch ? NSColor.systemRed.withAlphaComponent(0.25).cgColor : nil
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("playlistSearch")
        field.placeholderString = "Search playlist"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.target = self
        field.action = #selector(fieldAction(_:))
        field.setAccessibilityIdentifier("playlistSearchField")
        for (button, symbol, tip, action) in [(previous, "chevron.up", "Previous match", #selector(prevClicked)),
                                              (next, "chevron.down", "Next match", #selector(nextClicked)),
                                              (options, "line.3.horizontal.decrease.circle", "Search preferences", #selector(showOptions(_:)))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [field, previous, next, options])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { onSearch?(field.stringValue) }

    @objc private func fieldAction(_ sender: NSSearchField) {
        // Return jumps to the next match; clearing via the cancel button lands here too.
        if sender.stringValue.isEmpty { onSearch?("") } else { onNext?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): onPrevious?(); return true
        case #selector(NSResponder.moveDown(_:)): onNext?(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            onSearch?("")
            return true
        default: return false
        }
    }

    @objc private func prevClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let entries: [(String, PlaylistSearchFields)] = [("Tracks", .tracks), ("Albums", .albums), ("Artists", .artists),
                                                         ("Genres", .genre), ("Composers", .composers),
                                                         ("Ratings", .rating), ("Years", .years)]
        menu.addItem(NSMenuItem.sectionHeader(title: "Search In"))
        for (title, flag) in entries {
            let item = NSMenuItem(title: title, action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self
            item.tag = flag.rawValue
            item.state = fields.contains(flag) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let only = NSMenuItem(title: "Show Only Matches", action: #selector(toggleOnlyMatches), keyEquivalent: "")
        only.target = self
        only.state = showOnlyMatches ? .on : .off
        menu.addItem(only)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func toggleField(_ sender: NSMenuItem) {
        let flag = PlaylistSearchFields(rawValue: sender.tag)
        if fields.contains(flag) { fields.remove(flag) } else { fields.insert(flag) }
        onOptionsChanged?()
    }

    @objc private func toggleOnlyMatches() {
        showOnlyMatches.toggle()
        onOptionsChanged?()
    }
}

/// Clear, Save ▾, Undo, Redo, Show Active Track, Track Progression ▾ and the length summary.
final class PlaylistBottomBar: NSView {
    let clear = NSButton()
    let save = NSButton()
    let undo = NSButton()
    let redo = NSButton()
    let showActive = NSButton()
    let progression = NSButton()
    let summary = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("playlistBottomBar")
        let buttons: [(NSButton, String, String)] = [
            (clear, "trash", "Clear Playlist"),
            (save, "square.and.arrow.down", "Save Playlist"),
            (undo, "arrow.uturn.backward", "Undo"),
            (redo, "arrow.uturn.forward", "Redo"),
            (showActive, "scope", "Show Active Track"),
            (progression, TrackProgression.standard.symbolName, "Track Progression"),
        ]
        for (button, symbol, tip) in buttons {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.alignment = .right
        summary.lineBreakMode = .byTruncatingHead
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.identifier = NSUserInterfaceItemIdentifier("playlistSummary")
        let stack = NSStackView(views: [clear, save, undo, redo, showActive, progression, summary])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setCustomSpacing(8, after: progression)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

extension TrackProgression {
    var symbolName: String {
        switch self {
        case .standard: "arrow.right"
        case .onlyQueue: "list.number"
        case .repeatTrack: "repeat.1"
        case .repeatAlbum: "repeat.circle"
        case .repeatPlaylist: "repeat"
        case .randomTracks: "shuffle"
        case .randomAlbums: "shuffle.circle"
        }
    }
}
