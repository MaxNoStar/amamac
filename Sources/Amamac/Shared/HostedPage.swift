import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

/// A Media Sources page hosting a SwiftUI view.
final class HostedPage<Root: View>: NSViewController, MediaSourcePage {
    let crumbTitle: String
    let crumbSymbol: String
    let root: Root

    init(title: String, symbol: String, root: Root) {
        crumbTitle = title
        crumbSymbol = symbol
        self.root = root
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        view = host
    }
}
