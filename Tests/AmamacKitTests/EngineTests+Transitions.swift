@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import AmamacModels
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// Joins between tracks: exact ReplayGain, format changes without engine restarts, LAME MP3s and
/// seeking through sample-rate conversion. Muted like the other engine tests.
extension EngineTests {
    /// Level and zero crossings of every 256-frame block a deck's mixer puts out, in order (left
    /// channel). The crossings tell the tracks apart when they are sines of very different pitch.
    final class LevelMeter: Sendable {
        struct Block: Sendable {
            let rms: Float
            let crossings: Int
        }

        private let blocks = Mutex<[Block]>([])

        func install(on deck: Deck) {
            deck.player.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.block(self))
        }

        private static func block(_ meter: LevelMeter) -> AVAudioNodeTapBlock {
            { buffer, _ in meter.append(buffer) }
        }

        private func append(_ buffer: AVAudioPCMBuffer) {
            guard let left = buffer.floatChannelData?[0] else { return }
            var measured: [Block] = []
            var start = 0
            while start + 256 <= Int(buffer.frameLength) {
                var sum: Float = 0, crossings = 0
                for i in start..<(start + 256) {
                    sum += left[i] * left[i]
                    if i > start, (left[i - 1] < 0) != (left[i] < 0) { crossings += 1 }
                }
                measured.append(Block(rms: (sum / 256).squareRoot(), crossings: crossings))
                start += 256
            }
            blocks.withLock { $0 += measured }
        }

        var all: [Block] { blocks.withLock { $0 } }
    }

    @Test func replayGainChangesExactlyAtTheJoin() async throws {
        let dir = temporaryDirectory()
        // A low and loud, B high and 12 dB down: every block shows which track it holds and at what level.
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1.2, frequency: 220, amplitude: 0.4), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1.2, frequency: 1_760, amplitude: 0.4), in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        let meter = LevelMeter()
        meter.install(on: engine.decks[0])
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, gainDB: -12, after: idA))
        try engine.play(url: a, itemID: idA, gainDB: 0)
        let events = try await recorder.collect(seconds: 8) { Self.hasEnd($0) }
        engine.decks[0].player.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        #expect(Self.nowPlaying(events) == [idA, idB])
        // A: 0.4 / √2 ≈ 0.28 RMS, about 2–3 crossings a block; B: ≈ 0.07 RMS, about 18 crossings.
        // A block of B at A's level means the gain came late; A at B's level means it came early.
        // Only the one block holding the join may be in between.
        let blocks = meter.all.filter { $0.rms > 0.02 }
        let a_ = blocks.filter { $0.crossings <= 6 }, b_ = blocks.filter { $0.crossings >= 12 }
        #expect(a_.count > 50 && b_.count > 50, "A: \(a_.count) blocks, B: \(b_.count) blocks")
        let late = b_.filter { $0.rms > 0.15 }.count, early = a_.filter { $0.rms < 0.2 }.count
        #expect(late + early <= 1, "\(late) blocks of B at A's level, \(early) blocks of A at B's level")
    }

    @Test func formatChangesChainWithoutStoppingTheEngine() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1, sampleRate: 44_100), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1, sampleRate: 48_000, channels: 1), in: dir)
        let c = try AudioFixtures.make(.init("c.flac", seconds: 1, sampleRate: 96_000), in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        let ids = [PlaylistItemID(), PlaylistItemID(), PlaylistItemID()]
        engine.setUpcoming(UpcomingTrack(itemID: ids[1], url: b, after: ids[0]))
        try engine.play(url: a, itemID: ids[0])
        var events = try await recorder.collect(seconds: 6) { Self.nowPlaying($0).contains(ids[1]) }
        let format = engine.decks[0].player.sourceNode.outputFormat(forBus: 0)
        engine.setUpcoming(UpcomingTrack(itemID: ids[2], url: c, after: ids[1]))
        var formats = [format]
        events += try await recorder.collect(seconds: 6) { events in
            formats.append(engine.decks[0].player.sourceNode.outputFormat(forBus: 0))
            return Self.hasEnd(events)
        }
        engine.stop()
        #expect(Self.errors(events).isEmpty)
        #expect(Self.nowPlaying(events) == ids)
        // SFBAudioEngine stops, rebuilds and restarts its engine when the player's input format changes.
        #expect(formats.allSatisfy { $0 == format }, "the player's format changed: \(Set(formats.map(\.sampleRate)))")
    }

    @Test func lameMP3sChainGaplessly() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.mp3", seconds: 1.2), in: dir)
        let b = try AudioFixtures.make(.init("b.mp3", seconds: 1.2, frequency: 660), in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA))
        try engine.play(url: a, itemID: idA)
        let events = try await recorder.collect(seconds: 8) { Self.hasEnd($0) }
        engine.stop()
        #expect(Self.errors(events).isEmpty)
        #expect(Self.nowPlaying(events) == [idA, idB])
    }

    @Test func seekingWorksThroughSampleRateConversion() async throws {
        let dir = temporaryDirectory()
        // 22.05 kHz is always converted: the playback rate never goes below 44.1 kHz.
        let a = try AudioFixtures.make(.init("a.flac", seconds: 4, sampleRate: 22_050), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        try engine.play(url: a, itemID: PlaylistItemID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs((engine.totalTime ?? 0) - 4) < 0.05, "length \(engine.totalTime ?? 0)")
        #expect(engine.seek(to: 2.5))
        try await Task.sleep(for: .milliseconds(300))
        let time = engine.currentTime ?? 0
        engine.stop()
        #expect(time >= 2.4 && time < 3.1, "position after seek was \(time)")
    }
}
