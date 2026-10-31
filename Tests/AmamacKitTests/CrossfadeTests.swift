import Foundation
import Testing
@testable import AmamacModels
@testable import AmamacPlayback

/// Which automatic track changes crossfade, how long the fade is, and its curve.
struct CrossfadeTests {
    let on = CrossfadePolicy(enabled: true, seconds: 5, keepAlbumsGapless: true)

    @Test func offMeansGapless() {
        let policy = CrossfadePolicy(enabled: false, seconds: 5)
        #expect(policy.transition(from: makeTrack("A", album: "One"), to: makeTrack("B", album: "Two")) == .gapless)
    }

    @Test func differentAlbumsCrossfade() {
        #expect(on.transition(from: makeTrack("A", album: "One"), to: makeTrack("B", album: "Two")) == .crossfade(seconds: 5))
    }

    @Test func albumsStayGaplessOnlyWhileTheToggleIsOn() {
        let a = makeTrack("A", album: "Live at Leeds", track: 1)
        let b = makeTrack("B", artist: "ARTIST", album: "live at leeds", track: 2)
        #expect(on.transition(from: a, to: b) == .gapless)
        var everything = on
        everything.keepAlbumsGapless = false
        #expect(everything.transition(from: a, to: b) == .crossfade(seconds: 5))
    }

    @Test func sameTitleByAnotherArtistIsAnotherAlbum() {
        let a = makeTrack("A", artist: "Band", album: "Greatest Hits")
        let b = makeTrack("B", artist: "Other Band", album: "Greatest Hits")
        #expect(on.transition(from: a, to: b) == .crossfade(seconds: 5))
        // Compilations group under one album artist, so their tracks stay together.
        let c = makeTrack("C", artist: "Band", album: "Summer Mix", compilation: true)
        let d = makeTrack("D", artist: "Other Band", album: "Summer Mix", compilation: true)
        #expect(on.transition(from: c, to: d) == .gapless)
    }

    @Test func tracksWithoutAnAlbumCrossfade() {
        #expect(on.transition(from: makeTrack("A", album: ""), to: makeTrack("B", album: "")) == .crossfade(seconds: 5))
        #expect(on.transition(from: makeTrack("A", album: " "), to: makeTrack("B", album: " ")) == .crossfade(seconds: 5))
    }

    @Test func shortTracksShortenTheFadeOrStayGapless() {
        let long = makeTrack("Long", album: "One", durationMs: 240_000)
        #expect(on.transition(from: long, to: makeTrack("Short", album: "Two", durationMs: 6_000)) == .crossfade(seconds: 3))
        #expect(on.transition(from: makeTrack("Jingle", album: "Two", durationMs: 1_500), to: long) == .gapless)
        // An unknown duration (0) doesn't limit the fade.
        #expect(on.transition(from: makeTrack("A", album: "Three", durationMs: 0), to: long) == .crossfade(seconds: 5))
        #expect(CrossfadePolicy.fadeLength(requested: 30, outgoing: nil, incoming: nil) == CrossfadePolicy.longestFade)
        #expect(CrossfadePolicy.fadeLength(requested: 0.5, outgoing: nil, incoming: nil) == nil)
        #expect(CrossfadePolicy.fadeLength(requested: .nan, outgoing: nil, incoming: nil) == nil)
        #expect(CrossfadePolicy.fadeLength(requested: 5, outgoing: .infinity, incoming: -1) == 5)
    }

    @Test func curveKeepsEqualPower() {
        #expect(CrossfadePolicy.gains(progress: 0) == (1, 0))
        #expect(CrossfadePolicy.gains(progress: 1) == (0, 1))
        #expect(CrossfadePolicy.gains(progress: -3) == (1, 0))
        #expect(CrossfadePolicy.gains(progress: .nan) == (0, 1))
        var previous = CrossfadePolicy.gains(progress: 0)
        for step in 1...100 {
            let g = CrossfadePolicy.gains(progress: Double(step) / 100)
            #expect(abs(g.outgoing * g.outgoing + g.incoming * g.incoming - 1) < 0.0001)
            #expect(g.outgoing <= previous.outgoing && g.incoming >= previous.incoming)
            previous = g
        }
    }
}
