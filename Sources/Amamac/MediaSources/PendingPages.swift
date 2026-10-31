import AppKit
import SwiftUI
import AmamacCore

/// Base for Media Sources categories whose browsers are not built yet.
class PendingCategoryPage: NSViewController, MediaSourcePage {
    let env: AppEnvironment
    let category: MediaCategory

    init(env: AppEnvironment, category: MediaCategory) {
        self.env = env
        self.category = category
        super.init(nibName: nil, bundle: nil)
        title = category.title
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { category.title }
    var crumbSymbol: String { category.symbol }

    override func loadView() {
        let host = NSHostingView(rootView: VStack(spacing: 8) {
            Image(systemName: category.symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(category.title).font(.headline)
            Text(category.summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity))
        host.sizingOptions = []
        view = host
    }
}

final class InternetBrowserPage: PendingCategoryPage {
    init(env: AppEnvironment) { super.init(env: env, category: .internet) }
    required init?(coder: NSCoder) { fatalError() }
}

final class PodcastBrowserPage: PendingCategoryPage {
    init(env: AppEnvironment) { super.init(env: env, category: .podcasts) }
    required init?(coder: NSCoder) { fatalError() }
}
