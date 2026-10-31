import AmamacModels
import AmamacPlaylist
import AppKit

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
