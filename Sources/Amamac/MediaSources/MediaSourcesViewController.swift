import AppKit
import SwiftUI
import AmamacCore

/// A page shown inside Media Sources (a category browser or one of its sub-levels).
protocol MediaSourcePage: NSViewController {
    var crumbTitle: String { get }
    var crumbSymbol: String { get }
}

/// One of the root categories.
enum MediaCategory: String, CaseIterable {
    case localMusic, internet, playlists, files, podcasts

    var title: String {
        switch self {
        case .localMusic: "Local Music"
        case .internet: "Internet"
        case .playlists: "Playlists"
        case .files: "Files"
        case .podcasts: "Podcasts"
        }
    }

    var summary: String {
        switch self {
        case .localMusic: "Local sources of content"
        case .internet: "Online sources of content"
        case .playlists: "Various types of playlists"
        case .files: "Browse local hard drive for content"
        case .podcasts: "Podcast subscriptions and episodes"
        }
    }

    var symbol: String {
        switch self {
        case .localMusic: "music.note.house"
        case .internet: "globe"
        case .playlists: "music.note.list"
        case .files: "folder"
        case .podcasts: "antenna.radiowaves.left.and.right"
        }
    }
}

/// The left "Media Sources" pane: breadcrumb bar, a stack of pages, and the progress strip.
final class MediaSourcesViewController: NSViewController {
    let env: AppEnvironment
    private let breadcrumb = BreadcrumbBar()
    private let container = NSView()
    private var stack: [NSViewController] = []
    private lazy var rootPage = CategoryListPage { [weak self] in self?.open(category: $0) }
    private(set) lazy var collectionBrowser = CollectionBrowserViewController(env: env)
    private var categoryPages: [MediaCategory: NSViewController] = [:]

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let progress = NSHostingView(rootView: ProgressStrip(status: env.status))
        progress.sizingOptions = [.intrinsicContentSize]
        for v in [breadcrumb, container, progress] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            breadcrumb.topAnchor.constraint(equalTo: root.topAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.topAnchor.constraint(equalTo: container.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        breadcrumb.onSelect = { [weak self] index in self?.pop(to: index) }
        breadcrumb.onHome = { [weak self] in self?.pop(to: 0) }
        breadcrumb.bookmarkMenuProvider = { [weak self] in self?.bookmarkMenu() ?? NSMenu() }
        push(rootPage)
        open(category: .localMusic)
    }

    // MARK: Navigation

    func open(category: MediaCategory) {
        pop(to: 0)
        push(page(for: category))
    }

    func page(for category: MediaCategory) -> NSViewController {
        if let page = categoryPages[category] { return page }
        let page: NSViewController
        switch category {
        case .localMusic: page = collectionBrowser
        case .internet: page = makeInternetPage()
        case .playlists: page = makePlaylistsPage()
        case .files: page = makeFilesPage()
        case .podcasts: page = makePodcastsPage()
        }
        categoryPages[category] = page
        return page
    }

    var currentCategory: MediaCategory? {
        guard stack.count > 1 else { return nil }
        return categoryPages.first { $0.value === stack[1] }?.key
    }

    func push(_ page: NSViewController) {
        if let top = stack.last {
            top.view.removeFromSuperview()
        }
        stack.append(page)
        if page.parent == nil { addChild(page) }
        page.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.topAnchor.constraint(equalTo: container.topAnchor),
            page.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        updateBreadcrumb()
    }

    func pop(to index: Int) {
        guard index < stack.count - 1 else { return }
        stack.last?.view.removeFromSuperview()
        let kept = Set(categoryPages.values.map(ObjectIdentifier.init))
        for vc in stack[(index + 1)...] where !kept.contains(ObjectIdentifier(vc)) && vc !== rootPage { vc.removeFromParent() }
        stack.removeSubrange((index + 1)...)
        if let top = stack.last {
            top.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(top.view)
            NSLayoutConstraint.activate([
                top.view.topAnchor.constraint(equalTo: container.topAnchor),
                top.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                top.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                top.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        updateBreadcrumb()
    }

    /// "Previous Browser" (Backspace).
    @objc func goUp(_ sender: Any?) {
        if stack.count > 1 { pop(to: stack.count - 2) }
    }

    private func updateBreadcrumb() {
        breadcrumb.crumbs = stack.dropFirst().map { vc in
            if let page = vc as? MediaSourcePage { return (page.crumbTitle, page.crumbSymbol) }
            return (vc.title ?? "", "folder")
        }
    }

    // MARK: View bookmarks

    /// The current view as a link, or nil when it cannot be bookmarked.
    var currentViewLink: (name: String, link: AmamacLink)? {
        guard let category = currentCategory else { return nil }
        switch category {
        case .localMusic:
            let filter = collectionBrowser.searchField.stringValue
            let levels = collectionBrowser.grouping.levels
            let name = filter.isEmpty ? "Local Music by " + levels.map(\.displayName).joined(separator: " / ") : "Local Music: \(filter)"
            return (name, .collection(filter: filter, levels: levels.map(\.rawValue)))
        case .files:
            let folder = (categoryPages[.files] as? FileBrowserPage)?.model.current
            return ("Files: " + (folder?.lastPathComponent ?? ""), .category(category.rawValue, path: folder?.path))
        default:
            return (category.title, .category(category.rawValue, path: nil))
        }
    }

    private func bookmarkMenu() -> NSMenu {
        let menu = NSMenu()
        let add = NSMenuItem(title: "Bookmark This View", action: #selector(bookmarkCurrentView(_:)), keyEquivalent: "")
        add.target = self
        add.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)
        add.isEnabled = currentViewLink != nil
        menu.autoenablesItems = false
        menu.addItem(add)
        let views = BookmarkStore(database: env.database).all().filter { $0.kind == .view }
        if !views.isEmpty {
            menu.addItem(.separator())
            for bookmark in views {
                let item = NSMenuItem(title: bookmark.name, action: #selector(openBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bookmark.url
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bookmark Manager", action: #selector(AppDelegate.showBookmarkManager(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func bookmarkCurrentView(_ sender: Any?) {
        guard let view = currentViewLink else { return }
        BookmarkStore(database: env.database).addView(name: view.name, link: view.link)
        env.status.showMessage("Bookmarked “\(view.name)”.")
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw) else { return }
        LinkHandler.open(url)
    }

    func makeInternetPage() -> NSViewController { InternetBrowserPage(env: env, owner: self) }
    func makePlaylistsPage() -> NSViewController { PlaylistsBrowserPage(env: env, owner: self) }
    func makeFilesPage() -> NSViewController { FileBrowserPage(env: env) }
    func makePodcastsPage() -> NSViewController { PodcastBrowserPage(env: env, owner: self) }
}

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
        menu.addItem(withTitle: "Bookmark Manager", action: #selector(AppDelegate.showBookmarkManager(_:)), keyEquivalent: "")
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// The root list of categories (big rows with icon and description).
final class CategoryListPage: NSViewController, MediaSourcePage {
    var crumbTitle: String { "Home" }
    var crumbSymbol: String { "house" }
    private let onOpen: (MediaCategory) -> Void

    init(onOpen: @escaping (MediaCategory) -> Void) {
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingView(rootView: CategoryListView(onOpen: onOpen))
        hosting.sizingOptions = []
        view = hosting
    }
}

private struct CategoryListView: View {
    let onOpen: (MediaCategory) -> Void
    @State private var hovered: MediaCategory?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(MediaCategory.allCases, id: \.self) { category in
                    Button { onOpen(category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 24))
                                .frame(width: 36)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title).font(.headline)
                                Text(category.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8).fill(hovered == category ? Color.amamacAccent.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? category : (hovered == category ? nil : hovered) }
                    .accessibilityLabel(category.title)
                }
            }
            .padding(8)
        }
    }
}

/// Scan / download progress and short messages at the bottom of Media Sources.
struct ProgressStrip: View {
    let status: StatusCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(status.tasks) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.phase.isEmpty ? task.title : "\(task.title): \(task.phase)")
                        .font(.caption).lineLimit(1)
                    if let fraction = task.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            if let message = status.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, status.tasks.isEmpty && status.message == nil ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: status.tasks.count)
    }
}
