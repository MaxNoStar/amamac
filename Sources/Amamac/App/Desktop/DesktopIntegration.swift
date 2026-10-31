import AmamacBase
import AmamacModels
import AppKit

/// Everything outside the main window: the on-screen display, the menu bar item, global
/// shortcuts, system notifications and sleep handling. Created once at launch.
@MainActor
final class DesktopIntegration {
    let osd: OSDController
    let statusItem: StatusItemController
    private let notifier = TrackNotifier()
    private let sleep: SleepInhibitor
    private unowned let env: AppEnvironment
    private weak var mainWindow: MainWindowController?
    private var lastState: PlayerController.State = .stopped

    init(env: AppEnvironment, mainWindow: MainWindowController) {
        self.env = env
        self.mainWindow = mainWindow
        osd = OSDController(env: env)
        statusItem = StatusItemController(env: env, mainWindow: mainWindow)
        sleep = SleepInhibitor(env: env)
        lastState = env.player.state
        env.player.addListener { [weak self] event in self?.handle(event) }
        HotKeys.register(env: env, osd: osd)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: env.settings.defaults,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    private func settingsChanged() {
        statusItem.setVisible(env.settings.bool(AppSettings.Key.showTrayIcon))
        sleep.update()
    }

    private func handle(_ event: PlayerController.PlayerEvent) {
        let player = env.player
        switch event {
        case .trackChanged:
            statusItem.update()
            guard let item = player.currentItem, player.state == .playing || player.state == .buffering else { return }
            osd.showTrack(item)
            notifier.trackChanged(item, env: env)
            if env.settings.bool(AppSettings.Key.autoScrollPlaylist) { mainWindow?.playlistPane.scrollToActive() }
            fetchCoverIfMissing(item)
        case .stateChanged:
            statusItem.update()
            sleep.update()
            switch (lastState, player.state) {
            case (.playing, .paused), (.buffering, .paused): osd.showMessage("Paused", symbol: "pause.fill")
            case (.paused, .playing): if let item = player.currentItem { osd.showTrack(item) }
            case (.playing, .stopped), (.paused, .stopped): osd.showMessage("Stopped", symbol: "stop.fill")
            default: break
            }
            lastState = player.state
        case .volumeChanged:
            if player.isMuted {
                osd.showMessage("Muted", symbol: "speaker.slash.fill")
            } else {
                osd.showMessage("Volume \(player.volume)%", symbol: "speaker.wave.2.fill", level: Double(player.volume) / 100)
            }
        case .streamTitleChanged:
            if let item = player.currentItem, player.state == .playing { osd.showTrack(item) }
            statusItem.update()
        case .seeked:
            break
        }
    }

    /// "Fetch missing covers automatically": look the playing album up once per session.
    private var coverLookups = Set<String>()
    private func fetchCoverIfMissing(_ item: PlaylistItem) {
        let track = item.track
        guard env.settings.bool(AppSettings.Key.autoFetchCovers), item.source == .collection, !track.album.isEmpty,
              coverLookups.insert(track.albumKey).inserted else { return }
        let env = self.env
        Task {
            guard await env.covers.cover(albumKey: track.albumKey, size: 64) == nil else { return }
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            _ = await CoverActions.fetchAutomatically(AlbumReference(albumKey: track.albumKey, album: track.album, artist: artist,
                                                                     releaseId: track.mbReleaseId.isEmpty ? nil : track.mbReleaseId), env: env)
        }
    }
}
