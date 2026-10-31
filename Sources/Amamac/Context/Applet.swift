import AmamacModels
import AppKit
import SwiftUI

/// The applets the Context pane can show.
enum AppletKind: String, CaseIterable {
    case currentTrack, albums, wikipedia, analyzer

    var title: String {
        switch self {
        case .currentTrack: "Current Track"
        case .albums: "Albums"
        case .wikipedia: "Wikipedia"
        case .analyzer: "Analyzer"
        }
    }

    var symbol: String {
        switch self {
        case .currentTrack: "music.note"
        case .albums: "square.stack"
        case .wikipedia: "book"
        case .analyzer: "waveform"
        }
    }

    var summary: String {
        switch self {
        case .currentTrack: "Cover, rating and statistics of the playing track"
        case .albums: "Other albums by the current artist"
        case .wikipedia: "Wikipedia articles about the artist, album or track"
        case .analyzer: "A spectrum analyzer"
        }
    }

    var defaultHeight: CGFloat {
        switch self {
        case .currentTrack: 230
        case .albums: 280
        case .wikipedia: 520
        case .analyzer: 170
        }
    }

    @MainActor
    func make(env: AppEnvironment) -> Applet {
        switch self {
        case .currentTrack: CurrentTrackAppletController(env: env)
        case .albums: AlbumsAppletController(env: env)
        case .wikipedia: WikipediaAppletController(env: env)
        case .analyzer: AnalyzerAppletController(env: env)
        }
    }
}

/// One applet: its content view, optional settings, and whether it is currently on screen.
@MainActor
protocol Applet: AnyObject {
    var kind: AppletKind { get }
    var contentView: NSView { get }
    /// Settings shown in a popover from the header's gear button (nil: no gear).
    func makeConfigurationView() -> AnyView?
    /// Called when the applet is shown or hidden (enabled/collapsed) so it can start or stop work.
    func setActive(_ active: Bool)
}

extension Applet {
    func makeConfigurationView() -> AnyView? { nil }
    func setActive(_ active: Bool) {}
}

/// Hosts a SwiftUI view as an applet's content.
final class HostedAppletView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }
}
