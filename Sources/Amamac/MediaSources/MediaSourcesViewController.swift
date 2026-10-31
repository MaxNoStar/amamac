import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

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
        let views = env.bookmarks.all().filter { $0.kind == .view }
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
        menu.addItem(withTitle: "Bookmark Manager", action: #selector(ToolsCommands.showBookmarkManager(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func bookmarkCurrentView(_ sender: Any?) {
        guard let view = currentViewLink else { return }
        env.bookmarks.addView(name: view.name, link: view.link)
        env.status.showMessage("Bookmarked “\(view.name)”.")
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw) else { return }
        LinkHandler.open(url, env: env)
    }

    func makeInternetPage() -> NSViewController { InternetBrowserPage(env: env, owner: self) }
    func makePlaylistsPage() -> NSViewController { PlaylistsBrowserPage(env: env, owner: self) }
    func makeFilesPage() -> NSViewController { FileBrowserPage(env: env) }
    func makePodcastsPage() -> NSViewController { PodcastBrowserPage(env: env, owner: self) }
}
