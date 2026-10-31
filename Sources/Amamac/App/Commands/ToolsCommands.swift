import AppKit

/// Tools menu (collection updates, managers, Equalizer), Settings, the cover actions of the
/// collection's context menu, and the Help menu.
@MainActor
final class ToolsCommands: NSObject {
    private unowned let env: AppEnvironment
    /// For the on-screen display preview in Settings; nil in automation runs.
    weak var desktop: DesktopIntegration?

    init(env: AppEnvironment) { self.env = env }

    @objc func updateCollection(_ sender: Any?) { env.scanCollection() }
    @objc func fullRescan(_ sender: Any?) { env.scanCollection(full: true) }

    @objc func showBookmarkManager(_ sender: Any?) { BookmarkManagerWindow.show(env: env) }
    @objc func editQueue(_ sender: Any?) { QueueEditorWindow.show(env: env) }
    @objc func showEqualizer(_ sender: Any?) { EqualizerWindow.show(env: env) }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(env: env, osd: desktop?.osd) }

    // MARK: Covers

    private func album(from sender: NSMenuItem) -> AlbumReference? {
        guard var album = sender.representedObject as? AlbumReference else { return nil }
        if album.releaseId == nil {
            album.releaseId = try? env.database.releaseID(albumKey: album.albumKey)
        }
        return album
    }

    @objc func fetchCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.fetch(album, env: env) }
    }

    @objc func displayCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.display(album, env: env) }
    }

    @objc func setCustomCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.setCustom(album, env: env) }
    }

    @objc func unsetCover(_ sender: NSMenuItem) {
        if let album = album(from: sender) { CoverActions.unset(album, env: env) }
    }

    @objc func showCoverManager(_ sender: Any?) { CoverManagerWindow.show(env: env) }

    // MARK: Help

    @objc func showAbout(_ sender: Any?) { AboutPanel.show() }
    @objc func showDiagnostics(_ sender: Any?) { DiagnosticsWindow.show(env: env) }
    @objc func showAcknowledgements(_ sender: Any?) { AcknowledgementsWindow.show() }
    @objc func showAmamacHelp(_ sender: Any?) { HelpWindow.show() }
}
