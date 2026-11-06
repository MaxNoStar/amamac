import Foundation
import Testing
@testable import AmamacModels
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// A next track that can't be opened is reported as `upcomingFailed` (so the controller skips
/// it) while the current track plays out and ends normally. Muted like the other engine tests.
extension EngineTests {
    /// A ".flac" that is only noise: a decoder is chosen by its name, but opening it fails.
    static func unreadableFile(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("broken.flac")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        return url
    }

    static func failedUpcoming(_ events: [EngineEvent]) -> [PlaylistItemID] {
        events.compactMap { if case .upcomingFailed(let id, _) = $0 { id } else { nil } }
    }

    @Test(arguments: [TrackTransition.gapless, .crossfade(seconds: 1)])
    func unreadableNextTrackIsReportedAndTheCurrentOneEnds(_ transition: TrackTransition) async throws {
        let dir = temporaryDirectory()
        let a = try AudioFixtures.make(.init("a.flac", seconds: 2.5), in: dir)
        let broken = try Self.unreadableFile(in: dir)
        let engine = LocalAudioEngine()
        let recorder = EngineEventRecorder(engine)
        engine.setVolume(0)
        let idA = PlaylistItemID(), idBroken = PlaylistItemID()
        engine.setUpcoming(UpcomingTrack(itemID: idBroken, url: broken, after: idA, transition: transition))
        async let sampled = Self.sample(engine, for: 3)
        try engine.play(url: a, itemID: idA)
        let events = try await recorder.collect(seconds: 8) { Self.hasEnd($0) }
        let samples = await sampled
        engine.stop()
        #expect(Self.failedUpcoming(events) == [idBroken], "\(transition)")
        #expect(Self.errors(events).isEmpty, "\(transition): \(Self.errors(events))")
        #expect(Self.nowPlaying(events) == [idA], "\(transition)")
        #expect(!samples.contains { $0.crossfading }, "\(transition) started a fade into a file it couldn't open")
        #expect(!engine.isCrossfading)
        #expect(engine.eventLog.all.contains { $0.message.contains("broken.flac") }, "the failure is in the event log")
    }
}
