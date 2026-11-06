@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AmamacModels
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// Output changes: a stale mixer → output format is put right, a configuration change mid-track
/// or mid-fade keeps playing, engine failures are output failures, both decks follow the device.
/// Muted like the other engine tests; nothing here changes the system's devices.
extension EngineTests {
    final class EngineBox: @unchecked Sendable {
        var engine: AVAudioEngine?
    }

    static func avEngine(_ deck: Deck) -> AVAudioEngine? {
        let box = EngineBox()
        deck.player.modifyProcessingGraph { box.engine = $0 }
        return box.engine
    }

    /// Connects the deck's mixer to the output at half the hardware rate in mono, the way the
    /// format stays when SFBAudioEngine skips reconnecting while a device reports 0 Hz.
    static func makeOutputStale(_ deck: Deck) {
        deck.player.modifyProcessingGraph { engine in
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            guard let wrong = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate / 2, channels: 1) else { return }
            let running = engine.isRunning
            engine.stop()
            engine.disconnectNodeInput(engine.outputNode, bus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: wrong)
            engine.prepare()
            if running { try? engine.start() }
        }
    }

    static func outputMatchesHardware(_ deck: Deck) -> Bool {
        guard let engine = avEngine(deck) else { return false }
        let hardware = engine.outputNode.outputFormat(forBus: 0), mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        return hardware.sampleRate == mixer.sampleRate && hardware.channelCount == mixer.channelCount
    }

    static func outputFailures(_ events: [EngineEvent]) -> [String] {
        events.compactMap { if case .outputFailed(let m) = $0 { m } else { nil } }
    }

    @Test func revalidationRestoresTheHardwareFormatAndKeepsPlaying() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 4), in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        try engine.play(url: a, itemID: PlaylistItemID())
        #expect(await Self.waitUntil(2) { (engine.currentTime ?? 0) > 0.3 })
        Self.makeOutputStale(engine.decks[0])
        #expect(!Self.outputMatchesHardware(engine.decks[0]), "the test couldn't break the format")
        engine.revalidateOutput()
        #expect(Self.outputMatchesHardware(engine.decks[0]))
        #expect(engine.isPlaying)
        let before = engine.currentTime ?? 0
        try await Task.sleep(for: .milliseconds(600))
        let moved = (engine.currentTime ?? 0) - before
        engine.stop()
        #expect(moved > 0.45 && moved < 0.75, "the position moved \(moved) s in 0.6 s")
        #expect(engine.eventLog.all.contains { $0.message.contains("reconnected to the output") })
        let events = recorder.all
        #expect(Self.errors(events).isEmpty && Self.outputFailures(events).isEmpty)
    }

    @Test func configurationChangeMidFadeKeepsBothDecksPlaying() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 3), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 3, frequency: 880), in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA, transition: .crossfade(seconds: 1.5)))
        try engine.play(url: a, itemID: idA)
        #expect(await Self.waitUntil(4) { engine.isCrossfading && (engine.currentTime ?? 0) > 0.2 })
        for deck in engine.decks {
            Self.makeOutputStale(deck)
            // What AVAudioEngine posts when the hardware changes; SFBAudioEngine and the bridge react.
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: Self.avEngine(deck))
        }
        #expect(engine.decks.allSatisfy { Self.outputMatchesHardware($0) })
        #expect(engine.decks.allSatisfy { $0.isPlaying }, "both decks play on through the change")
        let events = try await recorder.collect(seconds: 8) { Self.hasEnd($0) }
        engine.stop()
        #expect(Self.nowPlaying(events) == [idA, idB])
        #expect(Self.errors(events).isEmpty && Self.outputFailures(events).isEmpty)
        #expect(engine.eventLog.all.contains { $0.message.contains("output now") })
    }

    @Test func engineErrorsAreOutputFailures() async throws {
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        let deck = engine.decks[0]
        deck.bridge.audioPlayer(deck.player, encounteredError: NSError(domain: NSOSStatusErrorDomain, code: -10_868))
        let events = try await recorder.collect(seconds: 2) { !Self.outputFailures($0).isEmpty }
        #expect(Self.errors(events).isEmpty, "not blamed on a track")
    }

    @Test func bothDecksFollowTheOutputDevice() throws {
        let engine = LocalAudioEngine()
        let device = try #require(AudioDevices.defaultOutputDevice())
        try engine.setOutputDevice(device)
        #expect(engine.outputDeviceIDs == [device, device])
        #expect(throws: (any Error).self) { try engine.setOutputDevice(0xDEAD) }
        #expect(engine.outputDeviceIDs == [device, device], "a failed switch leaves the decks where they were")
    }
}
