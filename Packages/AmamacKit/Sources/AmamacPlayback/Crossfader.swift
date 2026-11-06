import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine
import Synchronization
import os

/// Watches the playing deck and, when its track is about to end and the next one should
/// crossfade, starts that track on the idle deck and ramps the two against each other. Runs on
/// its own queue and never waits for the main actor; it takes the next track from the same
/// `upcoming` the gapless path uses, so only one of them can start it.
final class Crossfader: @unchecked Sendable {
    struct Fade {
        let from: Deck
        let to: Deck
        let length: TimeInterval
    }

    weak var engine: LocalAudioEngine?
    private let queue = DispatchQueue(label: "amamac.crossfade", qos: .userInitiated)
    private let log = Logger(subsystem: "local.amamac", category: "crossfade")
    /// Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var fade: Fade?
    private let fading = Mutex(false)

    var isCrossfading: Bool { fading.withLock { $0 } }

    /// Checks the playing deck every 20 ms while `on`; a running fade freezes while off (paused).
    func watch(_ on: Bool) {
        queue.async {
            if on { self.startTimer() } else { self.stopTimer() }
        }
    }

    /// Ends a running fade at once: the old track stops and the new one plays at full volume.
    func finishNow() {
        queue.sync {
            if let fade { finish(fade) }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let engine else { return }
        if let fade {
            advance(fade)
            return
        }
        let deck = engine.activeDeck
        guard deck.isPlaying, let next = engine.peekUpcoming(), case .crossfade(let seconds) = next.transition,
              let current = deck.nowPlayingItem, next.after == current,
              let total = deck.totalTime, let now = deck.currentTime,
              let length = CrossfadePolicy.fadeLength(requested: seconds, outgoing: total, incoming: nil)
        else { return }
        let remaining = total - now
        guard remaining <= length, let taken = engine.takeUpcoming(after: current, crossfadeOnly: true) else { return }
        begin(taken.track, decoder: taken.decoder, from: deck, length: max(0.05, min(length, remaining)))
    }

    private func begin(_ next: UpcomingTrack, decoder prepared: PlaybackDecoder?, from outgoing: Deck, length: TimeInterval) {
        guard let engine else { return }
        let incoming = engine.deck(otherThan: outgoing)
        incoming.player.stop()
        incoming.setTransitionGain(0)
        incoming.setFadeGain(outgoing.fadeGain)
        engine.makeActive(incoming)
        do {
            try incoming.play(prepared ?? engine.makeDecoder(for: next), itemID: next.itemID)
        } catch {
            // Leave the old track to play out; the controller then starts the next one itself and
            // reports the error through its usual path.
            log.error("Crossfade into \(next.url.path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            engine.makeActive(outgoing)
            incoming.setTransitionGain(1)
            return
        }
        fade = Fade(from: outgoing, to: incoming, length: length)
        fading.withLock { $0 = true }
    }

    /// Follows the new track's own position, so pausing both decks also holds the fade.
    private func advance(_ fade: Fade) {
        let progress = (fade.to.currentTime ?? 0) / fade.length
        let gains = CrossfadePolicy.gains(progress: progress)
        fade.from.setTransitionGain(gains.outgoing)
        fade.to.setTransitionGain(gains.incoming)
        if progress >= 1 { finish(fade) }
    }

    private func finish(_ fade: Fade) {
        fade.from.player.stop()
        self.fade = nil
        fading.withLock { $0 = false }
        fade.to.setTransitionGain(1)
        fade.from.setTransitionGain(1)
    }
}
