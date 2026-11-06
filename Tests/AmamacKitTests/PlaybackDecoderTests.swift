@preconcurrency import AVFoundation
import Foundation
@preconcurrency import SFBAudioEngine
import Testing
@testable import AmamacPlayback
@testable import AmamacTestSupport

/// `PlaybackDecoder` on its own, without an audio device: conversion to the playback format,
/// ReplayGain in the samples, positions, and the tolerant end of a track.
@Suite struct PlaybackDecoderTests {
    /// Decodes to the end like SFBAudioEngine does: full buffers until a short one.
    static func decodeAll(_ decoder: PlaybackDecoder, chunk: AVAudioFrameCount = 4096) throws -> [[Float]] {
        try decoder.open()
        let format = decoder.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        while true {
            try decoder.decode(into: buffer, length: chunk)
            let data = try #require(buffer.floatChannelData)
            for c in channels.indices {
                channels[c] += UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength))
            }
            if buffer.frameLength < chunk { return channels }
        }
    }

    static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func convertsMonoToStereoAtThePlaybackRate() throws {
        let url = try AudioFixtures.make(.init("mono.flac", seconds: 1, sampleRate: 22_050, channels: 1), in: temporaryDirectory())
        let decoder = try PlaybackDecoder(url: url, sampleRate: 48_000, gainDB: 0)
        let channels = try Self.decodeAll(decoder)
        #expect(decoder.processingFormat.sampleRate == 48_000)
        #expect(decoder.processingFormat.channelCount == 2)
        #expect(abs(channels[0].count - 48_000) <= 64, "\(channels[0].count) frames")
        #expect(abs(Int(decoder.length) - 48_000) <= 64, "length \(decoder.length)")
        #expect(channels[0] == channels[1], "the mono channel feeds both sides")
        #expect(Self.rms(channels[0]) > 0.1)
    }

    @Test func keepsEveryFrameWhenTheRatesMatch() throws {
        let url = try AudioFixtures.make(.init("a.flac", seconds: 1, sampleRate: 48_000), in: temporaryDirectory())
        let decoder = try PlaybackDecoder(url: url, sampleRate: 48_000, gainDB: 0)
        let channels = try Self.decodeAll(decoder)
        #expect(channels[0].count == 48_000)
        #expect(decoder.length == 48_000)
        #expect(decoder.position == 48_000)
    }

    @Test func appliesReplayGainInTheSamples() throws {
        let url = try AudioFixtures.make(.init("a.flac", seconds: 1), in: temporaryDirectory())
        let plain = try Self.decodeAll(PlaybackDecoder(url: url, sampleRate: 44_100, gainDB: 0))
        let quieter = try Self.decodeAll(PlaybackDecoder(url: url, sampleRate: 44_100, gainDB: -12))
        let ratio = Self.rms(quieter[0]) / Self.rms(plain[0])
        #expect(abs(ratio - powf(10, -12 / 20)) < 0.005, "ratio \(ratio)")
    }

    @Test func seeksInPlaybackFrames() throws {
        let url = try AudioFixtures.make(.init("a.flac", seconds: 4, sampleRate: 22_050), in: temporaryDirectory())
        let decoder = try PlaybackDecoder(url: url, sampleRate: 48_000, gainDB: 0)
        try decoder.open()
        try decoder.seek(to: 96_000)
        #expect(abs(decoder.position - 96_000) <= 8, "position \(decoder.position)")
        let rest = try Self.decodeAll(decoder)
        #expect(abs(rest[0].count - 96_000) <= 64, "\(rest[0].count) frames after the seek")
    }

    @Test func playsLAMEFramesToTheEnd() throws {
        // SFBAudioEngine's LAME encoder leaves a truncated last frame (docs/PROGRESS.md, M0).
        let url = try AudioFixtures.make(.init("a.mp3", seconds: 2), in: temporaryDirectory())
        let decoder = try PlaybackDecoder(url: url, sampleRate: 44_100, gainDB: 0)
        let channels = try Self.decodeAll(decoder)
        #expect(Double(channels[0].count) > 1.9 * 44_100, "\(channels[0].count) frames")
    }

    @Test func toleratesAnErrorOnlyNearTheEnd() throws {
        let url = try AudioFixtures.make(.init("a.flac", seconds: 2), in: temporaryDirectory())
        // Fails 0.2 s before the end: counted as the end of the track.
        let late = try Self.decodeAll(PlaybackDecoder(decoder: FailingDecoder(url: url, failAt: 1.8), sampleRate: 48_000, gainDB: 0))
        #expect(Double(late[0].count) > 1.7 * 48_000)
        // Fails in the middle: a real error.
        #expect(throws: (any Error).self) {
            _ = try Self.decodeAll(PlaybackDecoder(decoder: FailingDecoder(url: url, failAt: 1), sampleRate: 48_000, gainDB: 0))
        }
    }
}

/// Decodes a real file but throws once its position passes `failAt` seconds.
final class FailingDecoder: NSObject, PCMDecoding, @unchecked Sendable {
    struct Failure: Error {}
    let inner: AudioDecoder
    let failFrame: AVAudioFramePosition

    init(url: URL, failAt seconds: Double) throws {
        inner = try AudioDecoder(url: url)
        try inner.open()
        failFrame = AVAudioFramePosition(seconds * inner.processingFormat.sampleRate)
    }

    var inputSource: InputSource { inner.inputSource }
    var sourceFormat: AVAudioFormat { inner.sourceFormat }
    var processingFormat: AVAudioFormat { inner.processingFormat }
    var decodingIsLossless: Bool { inner.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { inner.properties }
    var isOpen: Bool { inner.isOpen }
    var supportsSeeking: Bool { inner.supportsSeeking }
    var position: AVAudioFramePosition { inner.position }
    var length: AVAudioFramePosition { inner.length }
    func open() throws { if !inner.isOpen { try inner.open() } }
    func close() throws { try inner.close() }
    func decode(into buffer: AVAudioBuffer) throws { try inner.decode(into: buffer) }
    func seek(to frame: AVAudioFramePosition) throws { try inner.seek(to: frame) }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        if inner.position >= failFrame { throw Failure() }
        try inner.decode(into: buffer, length: length)
    }
}
