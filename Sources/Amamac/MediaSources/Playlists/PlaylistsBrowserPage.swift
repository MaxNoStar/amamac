import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

/// Media Sources › Playlists: Saved Playlists, Dynamic Playlists, Automated Playlist Generator.
final class PlaylistsBrowserPage: NSViewController, MediaSourcePage {
    let env: AppEnvironment
    weak var owner: MediaSourcesViewController?

    enum Section: String, CaseIterable {
        case saved, dynamic, generator
        var title: String {
            switch self {
            case .saved: "Saved Playlists"
            case .dynamic: "Dynamic Playlists"
            case .generator: "Automated Playlist Generator"
            }
        }
        var summary: String {
            switch self {
            case .saved: "Playlists stored in Amamac and playlist files in your collection"
            case .dynamic: "Playlists that keep refilling themselves by rules"
            case .generator: "Builds a playlist that meets constraints such as length and tags"
            }
        }
        var symbol: String {
            switch self {
            case .saved: "music.note.list"
            case .dynamic: "dice"
            case .generator: "wand.and.stars"
            }
        }
    }

    init(env: AppEnvironment, owner: MediaSourcesViewController) {
        self.env = env
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { MediaCategory.playlists.title }
    var crumbSymbol: String { MediaCategory.playlists.symbol }

    override func loadView() {
        let host = NSHostingView(rootView: SubcategoryList(items: Section.allCases.map { ($0.title, $0.summary, $0.symbol) }) { [weak self] i in
            self?.open(Section.allCases[i])
        })
        host.sizingOptions = []
        view = host
    }

    @discardableResult
    func open(_ section: Section) -> NSViewController {
        let page: NSViewController
        switch section {
        case .saved: page = HostedPage(title: section.title, symbol: section.symbol, root: SavedPlaylistsView(model: SavedPlaylistsModel(env: env)))
        case .dynamic: page = HostedPage(title: section.title, symbol: section.symbol, root: DynamicPlaylistsView(model: DynamicPlaylistsModel(env: env)))
        case .generator: page = HostedPage(title: section.title, symbol: section.symbol, root: GeneratorView(model: GeneratorModel(env: env)))
        }
        owner?.push(page)
        return page
    }
}

struct SubcategoryList: View {
    let items: [(String, String, String)]
    let onOpen: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    Button { onOpen(i) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: items[i].2).font(.system(size: 22)).frame(width: 34).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(items[i].0).font(.headline)
                                Text(items[i].1).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }
}
