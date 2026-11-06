@preconcurrency import AVFoundation
import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine
import Synchronization

/// One SFBAudioEngine player with its own 10-band equalizer and volume stages (ReplayGain is applied
/// in the samples by `PlaybackDecoder`). `LocalAudioEngine` owns two, so one track can fade out while the
/// next fades in; both play to the same output device.
final class Deck: @unchecked Sendable {
    let index: Int
    let player = AudioPlayer()
    let bridge: EngineBridge
    let eq = AVAudioUnitEQ(numberOfBands: LocalAudioEngine.equalizerFrequencies.count)
    private let settings = Mutex(Settings())

    struct Settings {
        var equalizerEnabled = false
        var preamp: Float = 0
        var bands = [Float](repeating: 0, count: LocalAudioEngine.equalizerFrequencies.count)
        /// Crossfade envelope, 0...1.
        var transitionGain: Float = 1
        /// Stop / pause fade, 0...1. The mixer plays at `transitionGain * fadeGain`.
        var fadeGain: Float = 1
    }

    init(index: Int, continuation: AsyncStream<EngineEvent>.Continuation) {
        self.index = index
        bridge = EngineBridge(continuation: continuation)
        bridge.deck = self
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

    /// SFBAudioEngine's event thread holds the player while it reports a stop or a canceled
    /// decoder. Were that the last reference, the player would be destroyed on its own event thread,
    /// which aborts (its destructor joins that thread), so a released deck keeps it a moment longer.
    deinit {
        let player = self.player
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { withExtendedLifetime(player) {} }
    }

    private func configureEqualizerBands() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = LocalAudioEngine.equalizerFrequencies[i]
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

    enum OutputCheck {
        case unchanged
        case reconnected(AVAudioFormat)
        case failed(Error)
    }

    /// Reconnects the mixer to the output in the hardware's format if they differ, restarting the
    /// engine if it was running. Waits while the hardware reports no valid format.
    func revalidateOutput() -> OutputCheck {
        var result = OutputCheck.unchanged
        player.modifyProcessingGraph { engine in
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  hardware.sampleRate != mixer.sampleRate || hardware.channelCount != mixer.channelCount else { return }
            let running = engine.isRunning
            if running { engine.stop() }
            engine.disconnectNodeInput(engine.outputNode, bus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
            engine.prepare()
            result = .reconnected(hardware)
            if running {
                do { try engine.start() } catch { result = .failed(error) }
            }
        }
        return result
    }

    // MARK: Transport

    /// Starts `decoder` now on this deck, replacing whatever it was playing.
    func play(_ decoder: PlaybackDecoder, itemID: PlaylistItemID) throws {
        bridge.register(decoder, item: itemID)
        try player.play(decoder)
    }

    var isPlaying: Bool { player.isPlaying }
    var isPaused: Bool { player.isPaused }
    var currentTime: TimeInterval? { player.currentTime }
    var totalTime: TimeInterval? { player.totalTime }
    /// The playlist item whose audio is rendering now.
    var nowPlayingItem: PlaylistItemID? { bridge.item(for: player.nowPlaying) }

    // MARK: Gain stages

    func setEqualizer(enabled: Bool, preamp: Float, bands: [Float]) {
        settings.withLock {
            $0.equalizerEnabled = enabled
            $0.preamp = preamp
            $0.bands = bands
        }
        applyEqualizer()
    }

    private func applyEqualizer() {
        let s = settings.withLock { $0 }
        for (i, band) in eq.bands.enumerated() {
            band.gain = i < s.bands.count ? max(-12, min(12, s.bands[i])) : 0
            band.bypass = !s.equalizerEnabled
        }
        eq.globalGain = s.equalizerEnabled ? max(-96, min(24, s.preamp)) : 0
    }

    func setTransitionGain(_ gain: Float) {
        let volume = settings.withLock { s -> Float in
            s.transitionGain = gain
            return s.transitionGain * s.fadeGain
        }
        player.mainMixerNode.outputVolume = volume
    }

    func setFadeGain(_ gain: Float) {
        let volume = settings.withLock { s -> Float in
            s.fadeGain = gain
            return s.transitionGain * s.fadeGain
        }
        player.mainMixerNode.outputVolume = volume
    }

    var transitionGain: Float { settings.withLock { $0.transitionGain } }
    var fadeGain: Float { settings.withLock { $0.fadeGain } }

    // MARK: Analyzer

    func installTap(_ tap: SpectrumTap) {
        player.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.tapBlock(tap))
    }

    func removeTap() { player.mainMixerNode.removeTap(onBus: 0) }

    static func tapBlock(_ tap: SpectrumTap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.append(buffer) }
    }
}
