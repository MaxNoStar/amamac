import AmamacModels
import AmamacPlayback
import AppKit

/// Keeps Control Centre's Now Playing (title, artwork, position) current and handles the media
/// keys and remote commands.
@MainActor
final class NowPlayingController {
    private unowned let env: AppEnvironment
    private var artworkKey: String?
    private var artwork: NSImage?

    init(env: AppEnvironment) {
        self.env = env
        let player = env.player
        SystemMediaControls.registerRemoteCommands { command in
            Task { @MainActor in player.handle(command) }
        }
        player.addListener { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: AppEnvironment.coverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.artworkKey = nil
                self?.update()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let player = env.player
        guard let item = player.currentItem, player.isActive else {
            SystemMediaControls.update(nil, artwork: nil)
            return
        }
        let info = SystemMediaControls.Info(title: item.streamTitle ?? item.track.displayTitle, artist: item.track.artist,
                                            album: item.isStream ? item.track.displayTitle : item.track.album,
                                            duration: player.duration > 0 ? player.duration : nil,
                                            elapsed: player.currentTime, playing: player.state == .playing,
                                            isLiveStream: item.isStream && player.duration == 0)
        let key = item.albumKey
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            if !item.isStream {
                artwork = env.coverImages.image(albumKey: key, size: 300) { [weak self] image in
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = image
                    self.update()
                }
            }
        }
        SystemMediaControls.update(info, artwork: artwork)
    }
}
