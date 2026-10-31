import Foundation
import Testing
@testable import AmamacModels
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// Crossfades between the two decks, muted like the other engine tests.
extension EngineTests {
    struct FadeSample: Sendable {
        let time: TimeInterval
        let crossfading: Bool
        let playing: [Bool]
        let gains: [Float]
    }

    /// Records both decks every 15 ms for `seconds`. Gains are read before the decks' states: the
    /// crossfader stops the old deck before resetting its gain, so a reset gain always comes with
    /// that deck already shown as stopped.
    static func sample(_ engine: LocalAudioEngine, for seconds: TimeInterval) async -> [FadeSample] {
        let start = Date()
        var samples: [FadeSample] = []
        while Date().timeIntervalSince(start) < seconds {
            let gains = engine.decks.map(\.transitionGain)
            samples.append(FadeSample(time: Date().timeIntervalSince(start), crossfading: engine.isCrossfading,
                                      playing: engine.decks.map(\.isPlaying), gains: gains))
            try? await Task.sleep(for: .milliseconds(15))
        }
        return samples
    }

    static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func endCount(_ events: [EngineEvent]) -> Int {
        events.filter { if case .endOfAudio = $0 { true } else { false } }.count
    }

    @Test func crossfadeOverlapsTheNextTrack() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 3), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 3, frequency: 880), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA, transition: .crossfade(seconds: 1)))
        async let sampled = Self.sample(engine, for: 4)
        try engine.play(url: a, itemID: idA)
        let events = try await collect(engine, seconds: 10) { Self.hasEnd($0) }
        let samples = await sampled
        engine.stop()

        #expect(Self.errors(events).isEmpty)
        #expect(Self.nowPlaying(events) == [idA, idB])
        #expect(Self.endCount(events) == 1, "only the new track's end is reported")
        let fading = samples.filter(\.crossfading)
        let start = try #require(fading.first?.time, "no crossfade happened")
        #expect(start > 1.6 && start < 2.5, "the fade started at \(start) s instead of about 1 s before the end")
        let fadeTime = (fading.last?.time ?? 0) - start
        #expect(fadeTime > 0.7 && fadeTime < 1.4, "the fade lasted \(fadeTime) s")
        let overlap = fading.filter { $0.playing == [true, true] }
        #expect(overlap.count > 20, "both decks play during the fade")
        for s in overlap {
            let power = s.gains[0] * s.gains[0] + s.gains[1] * s.gains[1]
            #expect(abs(power - 1) < 0.1, "loudness dipped to \(power) at \(s.time) s")
        }
        let after = try #require(samples.last { !$0.crossfading && $0.time > start })
        #expect(after.playing == [false, true], "the old deck stops after the fade")
        #expect(after.gains == [1, 1])
    }

    @Test func pauseHoldsTheFadeAndSeekingEndsIt() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 3), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 5, frequency: 880), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA, transition: .crossfade(seconds: 1.5)))
        try engine.play(url: a, itemID: idA)
        #expect(await Self.waitUntil(4) { engine.isCrossfading && (engine.currentTime ?? 0) > 0.3 })

        engine.pause()
        try await Task.sleep(for: .milliseconds(100))
        let held = engine.decks.map(\.transitionGain)
        #expect(engine.decks.allSatisfy { !$0.isPlaying }, "pausing pauses both decks")
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.isCrossfading)
        #expect(engine.decks.map(\.transitionGain) == held, "the fade holds while paused")

        engine.resume()
        #expect(await Self.waitUntil(1) { engine.decks.allSatisfy(\.isPlaying) }, "resuming resumes both decks")
        #expect(engine.seek(to: 3))
        #expect(!engine.isCrossfading, "seeking finishes the fade first")
        #expect(engine.decks.filter(\.isPlaying).count == 1)
        #expect(engine.activeDeck.transitionGain == 1)
        #expect(engine.activeDeck.nowPlayingItem == idB)
        engine.stop()
    }

    @Test func stoppingDuringAFadeSilencesBothDecks() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 2.5), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 4, frequency: 880), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA, transition: .crossfade(seconds: 1)))
        try engine.play(url: a, itemID: idA)
        #expect(await Self.waitUntil(4) { engine.isCrossfading })
        engine.stop()
        #expect(!engine.isCrossfading)
        #expect(engine.decks.allSatisfy { !$0.isPlaying && !$0.isPaused })
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.decks.allSatisfy { !$0.isPlaying }, "nothing starts again after Stop")
    }

    @Test func gaplessTransitionsStayOnOneDeck() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 1.5), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 1.5, frequency: 660), in: dir)
        // A crossfade that can't fit (half of a 1.5 s track is under a second) falls back to gapless too.
        for transition in [TrackTransition.gapless, .crossfade(seconds: 1)] {
            let engine = LocalAudioEngine()
            engine.setVolume(0)
            let idA = PlaylistItemID(), idB = PlaylistItemID()
            engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: idA, transition: transition))
            async let sampled = Self.sample(engine, for: 3)
            try engine.play(url: a, itemID: idA)
            let events = try await collect(engine, seconds: 8) { Self.hasEnd($0) }
            let samples = await sampled
            engine.stop()
            #expect(Self.nowPlaying(events) == [idA, idB], "\(transition)")
            #expect(!samples.contains { $0.crossfading || $0.playing[1] }, "\(transition) used the second deck")
        }
    }

    @Test func staleCrossfadeIsIgnored() async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 2.5), in: dir)
        let b = try AudioFixtures.make(.init("b.flac", seconds: 2.5), in: dir)
        let engine = LocalAudioEngine()
        engine.setVolume(0)
        let idA = PlaylistItemID(), idB = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idB, url: b, after: PlaylistItemID(), transition: .crossfade(seconds: 1)))
        async let sampled = Self.sample(engine, for: 3)
        try engine.play(url: a, itemID: idA)
        let events = try await collect(engine, seconds: 8) { Self.hasEnd($0) }
        let samples = await sampled
        engine.stop()
        #expect(Self.nowPlaying(events) == [idA])
        #expect(!samples.contains { $0.crossfading })
    }
}
