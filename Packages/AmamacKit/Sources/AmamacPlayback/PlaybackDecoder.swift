@preconcurrency import AVFoundation
import Accelerate
import Foundation
@preconcurrency import SFBAudioEngine
import Synchronization
import os

/// One track on its way to a deck, in the deck's playback format. SFBAudioEngine stops, rebuilds
/// and restarts its engine whenever the next track's format differs, which pops and sometimes fails
/// to restart; with every track in one format the player never has to.
/// - Converts the decoder's audio to deinterleaved float at the deck's sample rate (mastering-quality
///   sample-rate conversion); mono and stereo become stereo, more channels keep their layout.
/// - Applies the track's ReplayGain in the samples, so the level changes exactly at the join.
/// - Treats a decoding error in the last half second as the end of the track: the truncated final
///   frame LAME leaves in MP3s would otherwise abort decoding.
final class PlaybackDecoder: NSObject, PCMDecoding, @unchecked Sendable {
    /// Decoding errors this close to the end count as the end of the track (seconds).
    static let tolerantTail: TimeInterval = 0.5
    /// Frames pulled from the wrapped decoder at a time when converting.
    private static let chunk: AVAudioFrameCount = 4096

    let decoder: PCMDecoding
    /// The deck's playback sample rate.
    let sampleRate: Double
    private let gainFactor: Mutex<Float>
    private let log = Logger(subsystem: "local.amamac", category: "engine")

    // Used only on SFBAudioEngine's decoding thread (or before the decoder is enqueued).
    private var format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer?
    private var scratch: AVAudioPCMBuffer?
    private var inputEnded = false
    private var pendingError: Error?
    private var outputPosition: AVAudioFramePosition = 0

    init(decoder: PCMDecoding, sampleRate: Double, gainDB: Float) {
        self.decoder = decoder
        self.sampleRate = sampleRate
        gainFactor = Mutex(Self.factor(gainDB))
        format = Self.playbackFormat(sampleRate: sampleRate)
    }

    convenience init(url: URL, sampleRate: Double, gainDB: Float) throws {
        self.init(decoder: try AudioDecoder(url: url), sampleRate: sampleRate, gainDB: gainDB)
    }

    /// Stereo deinterleaved float at `sampleRate`: the format of every mono or stereo track.
    static func playbackFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    static func factor(_ gainDB: Float) -> Float {
        gainDB == 0 || !gainDB.isFinite ? 1 : powf(10, max(-60, min(24, gainDB)) / 20)
    }

    /// Changes the ReplayGain for audio decoded from now on (about a quarter second ahead of output).
    func setGain(_ gainDB: Float) {
        gainFactor.withLock { $0 = Self.factor(gainDB) }
    }

    override var description: String { "PlaybackDecoder(\(decoder))" }

    // MARK: AudioDecoding

    var inputSource: InputSource { decoder.inputSource }
    var sourceFormat: AVAudioFormat { decoder.sourceFormat }
    var processingFormat: AVAudioFormat { format }
    var decodingIsLossless: Bool { decoder.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { decoder.properties }
    var isOpen: Bool { decoder.isOpen }
    var supportsSeeking: Bool { decoder.supportsSeeking }

    func open() throws {
        if !decoder.isOpen { try decoder.open() }
        let source = decoder.processingFormat
        if source.channelCount > 2, let layout = source.channelLayout {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        } else {
            format = Self.playbackFormat(sampleRate: sampleRate)
        }
        if source != format {
            guard let converter = AVAudioConverter(from: source, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: Self.chunk) else {
                throw PlaybackDecoderError.unsupportedFormat(source.description)
            }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            if source.channelCount == 1 { converter.channelMap = [0, 0] }
            self.converter = converter
            self.input = input
        }
        outputPosition = outputFrames(fromSource: decoder.position) ?? 0
    }

    func close() throws {
        converter = nil
        input = nil
        scratch = nil
        try decoder.close()
    }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let buffer = buffer as? AVAudioPCMBuffer else { throw PlaybackDecoderError.unsupportedFormat(buffer.format.description) }
        try decode(into: buffer, length: buffer.frameCapacity)
    }

    // MARK: PCMDecoding

    var position: AVAudioFramePosition { outputPosition }

    var length: AVAudioFramePosition {
        let length = decoder.length
        guard length != unknownFrameLength else { return unknownFrameLength }
        return outputFrames(fromSource: length) ?? unknownFrameLength
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        let frames = min(length, buffer.frameCapacity)
        if let converter {
            try convert(into: buffer, frames: frames, converter)
        } else {
            try decodeDirectly(into: buffer, frames: frames)
        }
        applyGain(to: buffer)
        outputPosition += AVAudioFramePosition(buffer.frameLength)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let target = sourceFrames(fromOutput: frame) else { throw PlaybackDecoderError.invalidPosition(frame) }
        try decoder.seek(to: target)
        converter?.reset()
        inputEnded = false
        pendingError = nil
        outputPosition = outputFrames(fromSource: decoder.position) ?? frame
    }

    // MARK: Decoding

    private func decodeDirectly(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) throws {
        guard !inputEnded else { buffer.frameLength = 0; return }
        do {
            try decoder.decode(into: buffer, length: frames)
        } catch where isNearEnd {
            log.notice("Treating a decoding error near the end as the end of the track: \(error.localizedDescription, privacy: .public)")
            inputEnded = true
            buffer.frameLength = 0
        }
    }

    /// AVAudioConverter fills its whole output buffer (a short buffer tells SFBAudioEngine the track
    /// ended), so a request smaller than the buffer goes through a scratch buffer of that size.
    private func convert(into buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount, _ converter: AVAudioConverter) throws {
        let target: AVAudioPCMBuffer
        if frames == buffer.frameCapacity {
            target = buffer
        } else {
            if scratch?.frameCapacity != frames { scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) }
            guard let scratch else { throw PlaybackDecoderError.unsupportedFormat(format.description) }
            target = scratch
        }
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { [unowned self] _, status in
            self.nextInput(status)
        }
        if status == .error { throw error ?? PlaybackDecoderError.conversionFailed }
        if let pendingError {
            self.pendingError = nil
            throw pendingError
        }
        if target !== buffer { copy(target, to: buffer) }
    }

    private func nextInput(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !inputEnded, let input else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try decoder.decode(into: input, length: input.frameCapacity)
        } catch {
            if isNearEnd {
                log.notice("Treating a decoding error near the end as the end of the track: \(error.localizedDescription, privacy: .public)")
            } else {
                pendingError = error
            }
            inputEnded = true
            status.pointee = .endOfStream
            return nil
        }
        guard input.frameLength > 0 else {
            inputEnded = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return input
    }

    private func copy(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        let frames = min(source.frameLength, destination.frameCapacity)
        if let from = source.floatChannelData, let to = destination.floatChannelData {
            for channel in 0..<Int(min(source.format.channelCount, destination.format.channelCount)) {
                to[channel].update(from: from[channel], count: Int(frames))
            }
        }
        destination.frameLength = frames
    }

    private func applyGain(to buffer: AVAudioPCMBuffer) {
        var gain = gainFactor.withLock { $0 }
        guard gain != 1, buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(channels[channel], 1, &gain, channels[channel], 1, vDSP_Length(buffer.frameLength))
        }
    }

    // MARK: Positions

    /// Whether the wrapped decoder is within `tolerantTail` of its end.
    private var isNearEnd: Bool {
        let length = decoder.length, position = decoder.position
        guard length != unknownFrameLength, position != unknownFramePosition, length >= position else { return false }
        return Double(length - position) <= Self.tolerantTail * decoder.processingFormat.sampleRate
    }

    private var ratio: Double {
        let source = decoder.processingFormat.sampleRate
        return source > 0 && converter != nil ? sampleRate / source : 1
    }

    private func outputFrames(fromSource frames: AVAudioFramePosition) -> AVAudioFramePosition? {
        guard frames != unknownFramePosition else { return nil }
        return Self.frames(Double(frames) * ratio)
    }

    private func sourceFrames(fromOutput frames: AVAudioFramePosition) -> AVAudioFramePosition? {
        Self.frames(Double(frames) / ratio)
    }

    /// Frame counts come from the file, so a corrupt length must not trap the conversion.
    private static func frames(_ value: Double) -> AVAudioFramePosition? {
        guard value.isFinite, value >= 0, value < Double(Int64.max / 2) else { return nil }
        return AVAudioFramePosition(value.rounded())
    }
}

enum PlaybackDecoderError: LocalizedError {
    case unsupportedFormat(String)
    case conversionFailed
    case invalidPosition(AVAudioFramePosition)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): "Unsupported audio format: \(format)"
        case .conversionFailed: "The audio could not be converted for playback"
        case .invalidPosition(let frame): "Invalid playback position \(frame)"
        }
    }
}
