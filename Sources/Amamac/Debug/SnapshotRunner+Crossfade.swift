// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacModels
import AmamacPlayback
import AppKit

extension SnapshotRunner {
    /// Turns crossfading on (1 s, half a 2-second fixture) and plays, muted, through
    /// PlayerController: a track followed by one from another album must hand over while it still
    /// plays, and the player must follow; two tracks of one album must stay gapless.
    func checkCrossfade() async {
        let player = env.player, model = env.playlist, navigator = env.navigator
        let defaults = env.settings.defaults
        typealias K = AppSettings.Key
        let savedQueue = model.queue, savedProgression = navigator.progression
        player.stop()
        player.local.setVolume(0)
        model.setQueue([])
        model.setStopAfter(nil)
        navigator.progression = .standard
        defaults.set(true, forKey: K.crossfade)
        defaults.set(1000, forKey: K.crossfadeDuration)
        defaults.set(true, forKey: K.crossfadeKeepsAlbumsGapless)

        /// The first track whose next one is (or isn't) on the same album.
        func pair(sameAlbum: Bool) -> (PlaylistItem, PlaylistItem)? {
            for id in model.order {
                model.setActive(id)
                guard let a = model.item(id), let nextID = navigator.peekNext(), let b = model.item(nextID),
                      a.url.isFileURL, b.url.isFileURL, a.duration >= 2, b.duration >= 2 else { continue }
                if CrossfadePolicy.sameAlbum(a.track, b.track) == sameAlbum { return (a, b) }
            }
            return nil
        }

        guard let (a, b) = pair(sameAlbum: false) else { fail("no fixture pair across albums") }
        player.play(a.id)
        await Snapshotter.waitUntil(timeout: 4) { player.local.isCrossfading }
        guard player.local.isCrossfading else { fail("\(a.track.displayTitle) did not crossfade into \(b.track.displayTitle)") }
        await Snapshotter.waitUntil(timeout: 2) { player.currentItem?.id == b.id }
        guard player.currentItem?.id == b.id, model.activeID == b.id, player.state == .playing else {
            fail("the player did not follow the crossfade to \(b.track.displayTitle)")
        }
        await Snapshotter.waitUntil(timeout: 3) { !player.local.isCrossfading }
        player.stop()

        guard let (c, d) = pair(sameAlbum: true) else { fail("no fixture pair within an album") }
        player.play(c.id)
        var crossfaded = false
        let deadline = Date().addingTimeInterval(5)
        while player.currentItem?.id != d.id && Date() < deadline {
            crossfaded = crossfaded || player.local.isCrossfading
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard player.currentItem?.id == d.id, !crossfaded else {
            fail("\(c.track.displayTitle) → \(d.track.displayTitle) on one album did not stay gapless (crossfaded: \(crossfaded))")
        }
        player.stop()

        for key in [K.crossfade, K.crossfadeDuration, K.crossfadeKeepsAlbumsGapless] { defaults.removeObject(forKey: key) }
        navigator.progression = savedProgression
        model.setQueue(savedQueue)
        print("snapshot: crossfade check passed")
    }
}
#endif
