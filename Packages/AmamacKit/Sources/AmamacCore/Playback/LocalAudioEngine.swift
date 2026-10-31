@preconcurrency import AVFoundation
@preconcurrency import SFBAudioEngine
import Foundation
import os
import Synchronization

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
