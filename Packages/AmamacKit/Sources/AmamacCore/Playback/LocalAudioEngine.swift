@preconcurrency import AVFoundation
@preconcurrency import SFBAudioEngine
import Foundation
import os
import Synchronization

/// The track the engine should enqueue when the current one finishes decoding.
public struct UpcomingTrack: Sendable, Equatable {
    public var itemID: PlaylistItemID
    public var url: URL
    /// ReplayGain + preamp in dB applied while this track renders.
    public var gainDB: Float
    /// The item this one follows; the bridge only enqueues it after that item's decoder.
    public var after: PlaylistItemID?

    public init(itemID: PlaylistItemID, url: URL, gainDB: Float = 0, after: PlaylistItemID?) {
        self.itemID = itemID
        self.url = url
        self.gainDB = gainDB
        self.after = after
    }
}

public enum EnginePlaybackState: Sendable, Equatable {
    case stopped, playing, paused
}

/// Events from the audio engines, delivered in order on one `AsyncStream`.
public enum EngineEvent: Sendable, Equatable {
    /// A new item started rendering (`nil` when playback ran out).
    case nowPlayingChanged(PlaylistItemID?)
    case stateChanged(EnginePlaybackState)
    /// Rendering finished and nothing else is queued.
    case endOfAudio
    case error(String, PlaylistItemID?)
    /// A stream reported a new title (ICY metadata).
    case streamTitle(String, PlaylistItemID)
    /// A stream is buffering / became ready.
    case buffering(Bool)
}

/// Receives SFBAudioEngine delegate callbacks on its internal threads. Gapless decisions are made
/// here synchronously; everything else is forwarded as `EngineEvent`s.
final class EngineBridge: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    struct State {
        var upcoming: UpcomingTrack?
        var decoderItems: [ObjectIdentifier: PlaylistItemID] = [:]
        var decoderGains: [ObjectIdentifier: Float] = [:]
    }

    let state = Mutex(State())
    let continuation: AsyncStream<EngineEvent>.Continuation
    weak var engine: LocalAudioEngine?
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

    // MARK: AudioPlayer.Delegate

    func audioPlayer(_ audioPlayer: AudioPlayer, decodingComplete decoder: PCMDecoding) {
        // Enqueue the next track right here so a busy main thread can never cause a gap.
        let finished = item(for: decoder)
        let next: UpcomingTrack? = state.withLock { s in
            guard let upcoming = s.upcoming, upcoming.after == finished else { return nil }
            s.upcoming = nil
            return upcoming
        }
        guard let next else { return }
        do {
            let nextDecoder = try AudioDecoder(url: next.url)
            register(nextDecoder, item: next.itemID, gain: next.gainDB)
            try audioPlayer.enqueue(nextDecoder)
        } catch {
            log.error("Gapless enqueue failed for \(next.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            continuation.yield(.error(error.localizedDescription, next.itemID))
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingWillStart decoder: PCMDecoding, at hostTime: UInt64) {
        let key = ObjectIdentifier(decoder as AnyObject)
        guard let gain = state.withLock({ $0.decoderGains[key] }), let engine else { return }
        let delay = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        gainQueue.asyncAfter(deadline: .now() + max(0, delay)) { engine.applyGain(gain) }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        let id = item(for: nowPlaying)
        continuation.yield(.nowPlayingChanged(id))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: PCMDecoding) {
        let key = ObjectIdentifier(decoder as AnyObject)
        state.withLock {
            $0.decoderItems[key] = nil
            $0.decoderGains[key] = nil
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        let s: EnginePlaybackState
        switch playbackState {
        case .playing: s = .playing
        case .paused: s = .paused
        default: s = .stopped
        }
        continuation.yield(.stateChanged(s))
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        continuation.yield(.endOfAudio)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        log.error("Player error: \(error.localizedDescription, privacy: .public)")
        continuation.yield(.error(error.localizedDescription, nil))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: PCMDecoding, error: Error, framesRendered: AVAudioFramePosition) {
        // Truncated final frames (common in MP3s) end up here; treat as a normal end of track.
        log.notice("Decoding aborted after \(framesRendered) frames: \(error.localizedDescription, privacy: .public)")
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        guard let owner = self.engine else { return audioPlayer.mainMixerNode }
        return owner.reconnectProcessingNodes(engine: engine, format: format)
    }
}

/// Plays local files through SFBAudioEngine with gapless enqueueing, a 10-band equalizer whose
/// global gain also carries ReplayGain, fades, and an optional analyzer tap.
public final class LocalAudioEngine: @unchecked Sendable {
    /// Band centre frequencies (Hz).
    public static let equalizerFrequencies: [Float] = [29, 59, 119, 237, 474, 947, 1_900, 3_800, 7_500, 15_000]

    public let events: AsyncStream<EngineEvent>
    let player = AudioPlayer()
    let bridge: EngineBridge
    let eq = AVAudioUnitEQ(numberOfBands: LocalAudioEngine.equalizerFrequencies.count)
    private let settings = Mutex(EqualizerSettings())
    private let analyzer = Mutex<SpectrumTap?>(nil)
    /// Bumped by every fade and cancellation; a fade step only acts while its generation is current.
    private let fadeGeneration = Mutex(0)

    struct EqualizerSettings {
        var enabled = false
        var preamp: Float = 0
        var bands = [Float](repeating: 0, count: LocalAudioEngine.equalizerFrequencies.count)
        var trackGain: Float = 0
    }

    public init() {
        var continuation: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        bridge = EngineBridge(continuation: continuation)
        bridge.engine = self
        player.delegate = bridge
        configureEqualizerBands()
        let eq = self.eq
        let player = self.player
        player.modifyProcessingGraph { engine in
            engine.attach(eq)
            let mixer = player.mainMixerNode
            let format = player.sourceNode.outputFormat(forBus: 0)
            engine.disconnectNodeInput(mixer)
            engine.connect(eq, to: mixer, format: format)
            engine.connect(player.sourceNode, to: eq, format: format)
        }
        applyEqualizer()
    }

    private func configureEqualizerBands() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.equalizerFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = true
        }
        eq.bypass = false
    }

    func reconnectProcessingNodes(engine: AVAudioEngine, format: AVAudioFormat) -> AVAudioNode {
        engine.disconnectNodeOutput(eq)
        engine.connect(eq, to: player.mainMixerNode, format: format)
        return eq
    }

    // MARK: Transport

    /// Starts playing `url` immediately, replacing anything queued.
    public func play(url: URL, itemID: PlaylistItemID, gainDB: Float = 0) throws {
        let decoder = try AudioDecoder(url: url)
        bridge.register(decoder, item: itemID, gain: gainDB)
        applyGain(gainDB)
        cancelFade()
        try player.play(decoder)
    }

    /// Sets (or clears) the track to enqueue when the current one finishes decoding.
    public func setUpcoming(_ upcoming: UpcomingTrack?) {
        bridge.state.withLock { $0.upcoming = upcoming }
    }

    public func pause() { _ = player.pause() }
    public func resume() {
        cancelFade()
        _ = player.resume()
    }
    public func stop() {
        player.stop()
        bridge.state.withLock { $0.upcoming = nil }
    }

    public var isPlaying: Bool { player.isPlaying }
    public var isPaused: Bool { player.isPaused }
    public var currentTime: TimeInterval? { player.currentTime }
    public var totalTime: TimeInterval? { player.totalTime }
    public var supportsSeeking: Bool { player.supportsSeeking }

    @discardableResult
    public func seek(to time: TimeInterval) -> Bool { player.seek(time: max(0, time)) }

    /// Device volume, 0...1.
    public func setVolume(_ volume: Float) { try? player.setVolume(max(0, min(1, volume))) }

    /// Fades the mixer to silence over `duration`, then runs `completion` on the main queue.
    /// `play`, `resume` and `cancelFade` abandon the fade; its completion then never runs.
    public func fadeOut(duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
        let generation = fadeGeneration.withLock { g -> Int in
            g += 1
            return g
        }
        guard duration > 0 else { completion(); return }
        let mixer = player.mainMixerNode
        let steps = max(1, Int(duration / 0.02))
        let start = mixer.outputVolume
        let queue = DispatchQueue(label: "amamac.fade")
        for i in 1...steps {
            queue.asyncAfter(deadline: .now() + Double(i) * duration / Double(steps)) { [weak self] in
                guard let self, self.fadeGeneration.withLock({ $0 }) == generation else { return }
                mixer.outputVolume = start * Float(steps - i) / Float(steps)
                if i == steps {
                    DispatchQueue.main.async {
                        if self.fadeGeneration.withLock({ $0 }) == generation { completion() }
                    }
                }
            }
        }
    }

    /// Stops a running fade and restores full mixer volume.
    public func cancelFade() {
        fadeGeneration.withLock { $0 += 1 }
        player.mainMixerNode.outputVolume = 1
    }

    public var isFading: Bool { player.mainMixerNode.outputVolume < 1 }

    public func restoreMixerVolume() { cancelFade() }

    public var outputDeviceID: AudioObjectID { player.outputDeviceID }
    public func setOutputDevice(_ id: AudioObjectID) throws { try player.setOutputDeviceID(id) }

    // MARK: Equalizer / gain

    public func setEqualizer(enabled: Bool, preamp: Float, bands: [Float]) {
        settings.withLock {
            $0.enabled = enabled
            $0.preamp = preamp
            $0.bands = bands
        }
        applyEqualizer()
    }

    /// ReplayGain for the current track (dB), applied immediately.
    public func setTrackGain(_ gain: Float) { applyGain(gain) }

    func applyGain(_ gain: Float) {
        settings.withLock { $0.trackGain = gain }
        applyEqualizer()
    }

    private func applyEqualizer() {
        let s = settings.withLock { $0 }
        for (i, band) in eq.bands.enumerated() {
            band.gain = i < s.bands.count ? max(-12, min(12, s.bands[i])) : 0
            band.bypass = !s.enabled
        }
        eq.globalGain = max(-96, min(24, s.trackGain + (s.enabled ? s.preamp : 0)))
    }

    // MARK: Analyzer

    /// Starts copying output samples into `tap` (installed only while an analyzer is visible).
    public func setSpectrumTap(_ tap: SpectrumTap?) {
        let mixer = player.mainMixerNode
        let previous = analyzer.withLock { old -> SpectrumTap? in
            let o = old
            old = tap
            return o
        }
        if previous != nil { mixer.removeTap(onBus: 0) }
        guard let tap else { return }
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(tap))
    }

    static func tapBlock(_ tap: SpectrumTap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.append(buffer) }
    }
}
