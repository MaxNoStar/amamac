import Foundation
import Synchronization
import Testing
@testable import AmamacModels
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// Real playback through the default output device, silenced with the player's own output volume
/// (the system volume is not touched). Run with `make test-engine`.
@Suite(.serialized)
struct EngineTests {
    struct Timeout: Error {}

    /// Collects engine events until `stop` returns true or `seconds` pass.
    func collect(_ engine: LocalAudioEngine, seconds: Double,
                 until stop: @escaping @Sendable ([EngineEvent]) -> Bool) async throws -> [EngineEvent] {
        try await withThrowingTaskGroup(of: [EngineEvent].self) { group in
            group.addTask {
                var events: [EngineEvent] = []
                for await event in engine.events {
                    events.append(event)
                    if stop(events) { break }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Timeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func nowPlaying(_ events: [EngineEvent]) -> [PlaylistItemID] {
        events.compactMap { if case .nowPlayingChanged(let id?) = $0 { id } else { nil } }
    }

    static func errors(_ events: [EngineEvent]) -> [String] {
        events.compactMap { if case .error(let message, _) = $0 { message } else { nil } }
    }

    static func hasEnd(_ events: [EngineEvent]) -> Bool {
        events.contains { if case .endOfAudio = $0 { true } else { false } }
    }

    @Test func enqueuedTrackPlaysGaplesslyAfterTheFirst() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1.5), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1.5, frequency: 660), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA))
        try engine.play(url: a, itemID: idA)
        let events = try await collect(engine, seconds: 10) { Self.hasEnd($0) }
        engine.stop()
        #expect(Self.errors(events).isEmpty)
        #expect(Self.nowPlaying(events) == [idA, idB])
    }

    @Test func upcomingTrackForAnotherItemIsNotEnqueued() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        // Pushed for a different current item (stale): must be ignored.
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: PlaylistItemID()))
        try engine.play(url: a, itemID: idA)
        let events = try await collect(engine, seconds: 8) { Self.hasEnd($0) }
        engine.stop()
        #expect(Self.nowPlaying(events) == [idA])
    }

    @Test func sampleRateChangeStillAdvances() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1, sampleRate: 44_100), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1, sampleRate: 48_000), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA))
        try engine.play(url: a, itemID: idA)
        var events = try await collect(engine, seconds: 8) { Self.hasEnd($0) }
        if !Self.nowPlaying(events).contains(idB) {
            // The engine could not chain a different format; the controller starts it explicitly.
            try engine.play(url: b, itemID: idB)
            events += try await collect(engine, seconds: 8) { Self.hasEnd($0) }
        }
        engine.stop()
        #expect(Self.errors(events).isEmpty)
        #expect(Self.nowPlaying(events).last == idB)
    }

    @Test func equalizerAndAnalyzerTapSurviveFormatChanges() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.wav", seconds: 1.5, sampleRate: 44_100), in: dir)
        let b = try AudioFixtures.make(.init("b.wav", seconds: 1.5, sampleRate: 48_000), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        engine.setEqualizer(enabled: true, preamp: -3, bands: [6, 4, 0, 0, 0, 0, 0, 0, 2, 4])
        let tap = SpectrumTap()
        engine.setSpectrumTap(tap)
        for (url, id) in [(a, PlaylistItemID()), (b, PlaylistItemID())] {
            tap.reset()
            try engine.play(url: url, itemID: id)
            try await Task.sleep(for: .milliseconds(700))
            #expect(engine.eq.engine != nil, "EQ node detached after playing \(url.lastPathComponent)")
            #expect(engine.eq.bands[0].bypass == false)
            let peak = tap.spectrum(bands: 16).max() ?? 0
            #expect(peak > 0, "analyzer saw no signal for \(url.lastPathComponent)")
        }
        engine.setSpectrumTap(nil)
        engine.stop()
    }

    @Test func seekingMovesThePlaybackPosition() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 4), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        try engine.play(url: a, itemID: PlaylistItemID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.supportsSeeking)
        #expect(engine.seek(to: 2.5))
        try await Task.sleep(for: .milliseconds(300))
        let time = engine.currentTime ?? 0
        engine.stop()
        #expect(time >= 2.4 && time < 3.6, "position after seek was \(time)")
    }

    @Test func cancelledFadeNeverCompletes() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 4), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        try engine.play(url: a, itemID: PlaylistItemID())
        try await Task.sleep(for: .milliseconds(200))
        let completed = Mutex(false)
        engine.fadeOut(duration: 0.6) { completed.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(250))
        #expect(engine.isFading, "the fade should have lowered the mixer volume")
        engine.resume()
        try await Task.sleep(for: .milliseconds(700))
        #expect(!engine.isFading)
        #expect(!completed.withLock { $0 })
        #expect(engine.isPlaying)

        engine.fadeOut(duration: 0.3) { completed.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(700))
        #expect(completed.withLock { $0 }, "an uninterrupted fade completes")
        engine.stop()
    }
}
