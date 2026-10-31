import AmamacModels
import AmamacPlaylist
import Foundation

/// Saves the playlist, queue and position shortly after each change and restores them at launch.
@MainActor
final class SessionController {
    private unowned let env: AppEnvironment
    private var saveScheduled = false

    init(env: AppEnvironment) { self.env = env }

    func observe() {
        env.playlist.observe { [weak self] _ in self?.scheduleSave() }
        env.player.addListener { [weak self] event in
            if event == .trackChanged || event == .stateChanged { self?.scheduleSave() }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        let player = env.player
        let session = PlaylistLoader.Session(model: env.playlist,
                                             position: player.isActive ? player.currentTime : nil,
                                             wasPlaying: player.state == .playing || player.state == .buffering)
        try? PlaylistLoader.saveSession(session, database: env.database)
    }

    /// Restores the saved playlist, then calls `completion` (also when there was nothing to restore).
    func restore(then completion: @escaping () -> Void = {}) {
        guard let session = PlaylistLoader.loadSession(database: env.database), !session.entries.isEmpty else {
            completion()
            return
        }
        let database = env.database
        Task {
            defer { completion() }
            let items = await PlaylistLoader.items(for: session, database: database)
            env.playlist.restore(items: items, activeID: session.activeID.map(PlaylistItemID.init(rawValue:)),
                                 queue: session.queue.map(PlaylistItemID.init(rawValue:)),
                                 stopAfterID: session.stopAfterID.map(PlaylistItemID.init(rawValue:)))
            if env.settings.bool(AppSettings.Key.resumePlayback), session.wasPlaying, let active = env.playlist.activeID {
                env.player.play(active, startAt: session.position ?? 0)
            }
            env.router?.showActiveTrack()
            env.dynamicMode.resumeIfNeeded()
        }
    }
}
