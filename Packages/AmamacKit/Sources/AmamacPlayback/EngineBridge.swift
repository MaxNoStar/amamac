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
        var decoderGains: [ObjectIdentifier: Float] = [:]
    }

    let state = Mutex(State())
    let continuation: AsyncStream<EngineEvent>.Continuation
    weak var engine: LocalAudioEngine?
    weak var deck: Deck?
    private let log = Logger(subsystem: "local.amamac", category: "engine")
    private let gainQueue = DispatchQueue(label: "amamac.engine.gain")

    init(continuation: AsyncStream<EngineEvent>.Continuation) {
        self.continuation = continuation
    }

    func register(_ decoder: PCMDecoding, item: PlaylistItemID, gain: Float) {
        let key = ObjectIdentifier(decoder as AnyObject)
        state.withLock {
            $0.decoderItems[key] = item
            $0.decoderGains[key] = gain
        }
    }

    func item(for decoder: PCMDecoding?) -> PlaylistItemID? {
        guard let decoder else { return nil }
        let key = ObjectIdentifier(decoder as AnyObject)
        return state.withLock { $0.decoderItems[key] }
    }

    private func forget(_ decoder: PCMDecoding) {
        let key = ObjectIdentifier(decoder as AnyObject)
        state.withLock {
            $0.decoderItems[key] = nil
            $0.decoderGains[key] = nil
        }
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
        guard let next = engine.takeUpcoming(after: item(for: decoder), crossfadeOnly: false) else { return }
        do {
            let nextDecoder = try AudioDecoder(url: next.url)
            register(nextDecoder, item: next.itemID, gain: next.gainDB)
            try audioPlayer.enqueue(nextDecoder)
        } catch {
            log.error("Gapless enqueue failed for \(next.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            forward(.error(error.localizedDescription, next.itemID))
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingWillStart decoder: PCMDecoding, at hostTime: UInt64) {
        let key = ObjectIdentifier(decoder as AnyObject)
        guard let gain = state.withLock({ $0.decoderGains[key] }), let deck else { return }
        let delay = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        gainQueue.asyncAfter(deadline: .now() + max(0, delay)) { deck.applyGain(gain) }
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
        log.error("Player error: \(error.localizedDescription, privacy: .public)")
        forward(.error(error.localizedDescription, nil))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: PCMDecoding, error: Error, framesRendered: AVAudioFramePosition) {
        // Truncated final frames (common in MP3s) end up here; treat as a normal end of track.
        log.notice("Decoding aborted after \(framesRendered) frames: \(error.localizedDescription, privacy: .public)")
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        guard let deck else { return audioPlayer.mainMixerNode }
        return deck.reconnectProcessingNodes(engine: engine, format: format)
    }
}
