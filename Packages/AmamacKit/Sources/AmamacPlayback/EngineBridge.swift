@preconcurrency import AVFoundation
import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine
import Synchronization
import os

/// Receives one deck's SFBAudioEngine delegate callbacks on its internal threads. Gapless
/// decisions are made here synchronously; everything else is forwarded as `EngineEvent`s while
/// the deck is the active one (a deck fading out after a crossfade stays silent).
final class EngineBridge: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    struct State {
        var decoderItems: [ObjectIdentifier: PlaylistItemID] = [:]
    }

    let state = Mutex(State())
    let continuation: AsyncStream<EngineEvent>.Continuation
    weak var engine: LocalAudioEngine?
    weak var deck: Deck?
    private let log = Logger(subsystem: "local.amamac", category: "engine")

    init(continuation: AsyncStream<EngineEvent>.Continuation) {
        self.continuation = continuation
    }

    func register(_ decoder: PCMDecoding, item: PlaylistItemID) {
        let key = ObjectIdentifier(decoder as AnyObject)
        state.withLock { $0.decoderItems[key] = item }
    }

    func item(for decoder: PCMDecoding?) -> PlaylistItemID? {
        guard let decoder else { return nil }
        let key = ObjectIdentifier(decoder as AnyObject)
        return state.withLock { $0.decoderItems[key] }
    }

    private func forget(_ decoder: PCMDecoding) {
        let key = ObjectIdentifier(decoder as AnyObject)
        state.withLock { $0.decoderItems[key] = nil }
    }

    private var isActive: Bool {
        guard let deck, let engine else { return false }
        return engine.isActive(deck)
    }

    private func forward(_ event: EngineEvent) {
        if isActive { continuation.yield(event) }
    }

    // MARK: AudioPlayer.Delegate

    func audioPlayer(_ audioPlayer: AudioPlayer, decodingComplete decoder: PCMDecoding) {
        // Enqueue the next track right here so a busy main thread can never cause a gap. A track
        // meant to crossfade is normally taken by the crossfader earlier; if it wasn't (the fade
        // couldn't fit), it still follows gaplessly.
        guard isActive, let engine else { return }
        guard let (next, prepared) = engine.takeUpcoming(after: item(for: decoder), crossfadeOnly: false) else { return }
        do {
            let nextDecoder = try prepared ?? engine.makeDecoder(for: next)
            register(nextDecoder, item: next.itemID)
            try audioPlayer.enqueue(nextDecoder)
            engine.eventLog.add("Queued \(next.url.lastPathComponent)\(prepared == nil ? ", opened at the join" : "")")
        } catch {
            engine.eventLog.add("Could not queue \(next.url.lastPathComponent): \(error.localizedDescription)")
            forward(.upcomingFailed(next.itemID, error.localizedDescription))
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        forward(.nowPlayingChanged(item(for: nowPlaying)))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: PCMDecoding) {
        forget(decoder)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, decoderCanceled decoder: PCMDecoding, framesRendered: AVAudioFramePosition) {
        // Skipped or stopped before its end: renderingComplete never comes for it.
        forget(decoder)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        let s: EnginePlaybackState
        switch playbackState {
        case .playing: s = .playing
        case .paused: s = .paused
        default: s = .stopped
        }
        forward(.stateChanged(s))
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        forward(.endOfAudio)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        engine?.eventLog.add("Player error: \(error.localizedDescription)")
        forward(.error(error.localizedDescription, nil))
    }

    /// SFBAudioEngine stops without an end of audio after this, so without the event playback would
    /// sit silent in "playing". (`PlaybackDecoder` already turns errors in a track's last half
    /// second into a normal end.)
    func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: PCMDecoding, error: Error, framesRendered: AVAudioFramePosition) {
        let name = (decoder as? PlaybackDecoder)?.fileName ?? "a track"
        engine?.eventLog.add("Decoding of \(name) stopped after \(framesRendered) frames: \(error.localizedDescription)")
        forward(.endedEarly(item(for: decoder), error.localizedDescription))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        guard let deck else { return audioPlayer.mainMixerNode }
        return deck.reconnectProcessingNodes(engine: engine, format: format)
    }
}
