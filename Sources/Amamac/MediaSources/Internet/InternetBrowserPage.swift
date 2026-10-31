import AmamacBase
import AmamacModels
import AmamacPodcasts
import AmamacWeb
import AppKit
import SwiftUI

/// Media Sources › Internet: Internet Radio and the Podcast Directory.
final class InternetBrowserPage: NSViewController, MediaSourcePage {
    let env: AppEnvironment
    weak var owner: MediaSourcesViewController?

    enum Section: CaseIterable {
        case radio, podcasts
        var title: String { self == .radio ? "Internet Radio" : "Podcast Directory" }
        var summary: String {
            self == .radio ? "Thousands of stations from radio-browser.info" : "Find podcasts to subscribe to"
        }
        var symbol: String { self == .radio ? "radio" : "magnifyingglass" }
    }

    init(env: AppEnvironment, owner: MediaSourcesViewController) {
        self.env = env
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
        title = MediaCategory.internet.title
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { MediaCategory.internet.title }
    var crumbSymbol: String { MediaCategory.internet.symbol }

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
        case .radio: page = HostedPage(title: section.title, symbol: section.symbol, root: RadioView(model: RadioModel(env: env, owner: owner)))
        case .podcasts: page = HostedPage(title: section.title, symbol: section.symbol, root: PodcastDirectoryView(model: PodcastDirectoryModel(env: env)))
        }
        owner?.push(page)
        return page
    }
}
