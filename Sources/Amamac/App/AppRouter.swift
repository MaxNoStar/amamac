import AppKit

/// Navigation in the main window, for features that should not know its panes
/// (`env.router`, implemented by `MainWindowController`).
@MainActor
protocol AppRouter: AnyObject {
    /// The screen the main window is on.
    var windowScreen: NSScreen? { get }

    /// Scrolls the playlist to the active track.
    func showActiveTrack()

    /// Opens Local Music filtered by `filter` (playlist "Show Album/Artist in Media Sources").
    func showInCollection(filter: String)

    /// Shows Media Sources at a root category and returns its page.
    @discardableResult
    func showMediaSources(_ category: MediaCategory) -> NSViewController

    /// Shows or hides the Pop-Up Dropper over the Context pane while tracks are dragged.
    func showDropTargets(for session: NSDraggingSession)
    func hideDropTargets()
}
