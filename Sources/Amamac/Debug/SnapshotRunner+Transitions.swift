// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacLibrary
import AmamacModels
import AmamacPlayback
import AmamacTestSupport
import AppKit

extension SnapshotRunner {
    /// Plays a chain that changes format at every join (44.1 kHz FLAC, 48 kHz mono FLAC, 96 kHz
    /// FLAC, then two LAME MP3s), muted, through PlayerController, gapless and then crossfading
    /// across albums. The player must follow every track to the end of the chain without
    /// recoveries, early ends or failed tracks in the playback event log.
    func checkTransitions() async {
        let player = env.player, model = env.playlist, navigator = env.navigator
        let defaults = env.settings.defaults
        typealias K = AppSettings.Key
        let savedItems = model.order.compactMap { model.item($0) }, savedActive = model.activeID
        let savedProgression = navigator.progression
        player.stop()
        player.local.setVolume(0)
        model.setQueue([])
        model.setStopAfter(nil)
        navigator.progression = .standard

        let dir = env.dataDirectory.appendingPathComponent("Transitions")
        let specs: [AudioFixtures.Spec] = [
            .init("a 44k.flac", sampleRate: 44_100, frequency: 220),
            .init("b 48k mono.flac", sampleRate: 48_000, channels: 1, frequency: 330),
            .init("c 96k.flac", sampleRate: 96_000, frequency: 440),
            .init("d lame.mp3", frequency: 550),
            .init("e lame.mp3", frequency: 660),
        ]
        var tracks: [Track] = []
        do {
            for (i, spec) in specs.enumerated() {
                let url = try AudioFixtures.make(spec, in: dir)
                var track = try TagReader.read(url: url).track
                track.album = "Chain \(i)"
                tracks.append(track)
            }
        } catch {
            fail("transition fixtures: \(error)")
        }

        for crossfade in [false, true] {
            defaults.set(crossfade, forKey: K.crossfade)
            defaults.set(1000, forKey: K.crossfadeDuration)
            defaults.set(false, forKey: K.crossfadeKeepsAlbumsGapless)
            let items = tracks.map { PlaylistItem(track: $0, source: .file) }
            model.replace(with: items)
            let logged = player.local.eventLog.all.count
            player.play(items[0].id)
            var seen: [PlaylistItemID] = []
            let deadline = Date().addingTimeInterval(Double(items.count) * 2 + 8)
            while Date() < deadline {
                if let id = player.currentItem?.id, seen.last != id { seen.append(id) }
                if player.state == .stopped { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let mode = crossfade ? "crossfading" : "gapless"
            let names = seen.compactMap { id in items.first { $0.id == id }?.track.album }
            guard seen == items.map(\.id), player.state == .stopped else {
                fail("\(mode) chain played \(names) and ended \(player.state)")
            }
            let events = player.local.eventLog.all.dropFirst(logged).map(\.message)
            let trouble = ["Watchdog", "Output failed", "Could not", "stopped after", "cancelled", "error"]
            if let bad = events.first(where: { e in trouble.contains { e.localizedCaseInsensitiveContains($0) } }) {
                fail("\(mode) chain logged: \(bad)")
            }
            if crossfade, !events.contains(where: { $0.hasPrefix("Crossfade into") }) {
                fail("the crossfading chain never crossfaded")
            }
        }

        for key in [K.crossfade, K.crossfadeDuration, K.crossfadeKeepsAlbumsGapless] { defaults.removeObject(forKey: key) }
        navigator.progression = savedProgression
        model.replace(with: savedItems)
        if let savedActive { model.setActive(savedActive) }
        print("snapshot: transition check passed")
    }
}
#endif
