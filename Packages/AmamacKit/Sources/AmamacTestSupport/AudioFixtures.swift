@preconcurrency import AVFoundation
import AmamacLibrary
import Foundation
import ImageIO
@preconcurrency import SFBAudioEngine

/// Generates short tagged audio files for tests, the decoder self-test and snapshot mode.
public enum AudioFixtures {
    public struct Spec: Sendable {
        public var relativePath: String
        public var seconds: Double = 2
        public var sampleRate: Double = 44_100
        public var channels: AVAudioChannelCount = 2
        public var frequency: Double = 440
        public var tags = TagChanges()

        public init(_ relativePath: String, seconds: Double = 2, sampleRate: Double = 44_100,
                    channels: AVAudioChannelCount = 2, frequency: Double = 440, tags: TagChanges = TagChanges()) {
            self.relativePath = relativePath
            self.seconds = seconds
            self.sampleRate = sampleRate
            self.channels = channels
            self.frequency = frequency
            self.tags = tags
        }
    }

    /// Formats the self-test checks: extension → whether it is produced via SFBAudioEngine's encoders.
    /// (APE is decodable but SFBAudioEngine 0.14 crashes when encoding it; CAF cannot carry tags, so neither is generated.)
    public static let selfTestExtensions = ["wav", "aiff", "m4a", "flac", "ogg", "opus", "mp3", "wv", "mpc", "tta"]

    /// Writes `spec` under `root`, creating directories. Returns the file URL.
    @discardableResult
    public static func make(_ spec: Spec, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(spec.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav", "aiff", "aif", "caf", "m4a":
            try writeNative(url: url, spec: spec)
        default:
            let wav = url.deletingPathExtension().appendingPathExtension("fixture-src.wav")
            try writeNative(url: wav, spec: spec)
            defer { try? FileManager.default.removeItem(at: wav) }
            try AudioConverter.convert(wav, to: url)
        }
        if !spec.tags.isEmpty { try TagWriter.write(spec.tags, to: url) }
        return url
    }

    static func writeNative(url: URL, spec: Spec) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: spec.sampleRate, channels: spec.channels)!
        var settings: [String: Any] = [AVSampleRateKey: spec.sampleRate, AVNumberOfChannelsKey: spec.channels]
        switch url.pathExtension.lowercased() {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 128_000
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension.lowercased().hasPrefix("aif")
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(spec.seconds * spec.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let twoPi = 2 * Double.pi
        for ch in 0..<Int(spec.channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(0.2 * sin(twoPi * spec.frequency * Double(i) / spec.sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    /// Decodes every frame of `url`; returns the number of frames decoded.
    public static func decodeAll(_ url: URL) throws -> AVAudioFramePosition {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        defer { try? decoder.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        var total: AVAudioFramePosition = 0
        while true {
            do {
                try decoder.decode(into: buffer, length: 4096)
            } catch {
                // Some decoders report an error at end of stream; accept it once everything is decoded.
                if decoder.length > 0 && total >= decoder.length - 4096 { break }
                throw DecodeError(underlying: error, framesDecoded: total, expected: decoder.length)
            }
            if buffer.frameLength == 0 { break }
            total += AVAudioFramePosition(buffer.frameLength)
        }
        return total
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public var underlying: Error
        public var framesDecoded: AVAudioFramePosition
        public var expected: AVAudioFramePosition
        public var description: String { "\(underlying.localizedDescription) after \(framesDecoded)/\(expected) frames" }
    }

    /// A small library covering formats, compilations, multi-disc albums, Unicode and missing tags.
    public static func standardLibrary() -> [Spec] {
        func tags(_ title: String, _ artist: String, _ album: String, track: Int, disc: Int? = nil, year: Int = 2001,
                  genre: String = "Rock", albumArtist: String? = nil, compilation: Bool? = nil) -> TagChanges {
            var t = TagChanges()
            t.title = title
            t.artist = artist
            t.album = album
            t.trackNumber = track
            t.discNumber = disc
            t.year = year
            t.genre = genre
            t.albumArtist = albumArtist
            t.compilation = compilation
            return t
        }
        var specs: [Spec] = []
        let formats = ["flac", "mp3", "ogg", "opus", "m4a", "wav"]
        for (i, ext) in formats.enumerated() {
            specs.append(Spec("The Synthetics/Sine Waves/\(String(format: "%02d", i + 1)) Tone \(i + 1).\(ext)",
                              frequency: 220 + Double(i) * 110,
                              tags: tags("Tone \(i + 1)", "The Synthetics", "Sine Waves", track: i + 1, year: 1999, genre: "Electronic")))
        }
        for i in 1...3 {
            specs.append(Spec("Gapless Group/Continuous/\(i) Part \(i).flac", sampleRate: 48_000, frequency: 330,
                              tags: tags("Part \(i)", "Gapless Group", "Continuous", track: i, year: 2010, genre: "Ambient")))
        }
        for disc in 1...2 {
            for i in 1...2 {
                specs.append(Spec("Björk Ensemble/Dïscs/\(disc)-\(i) Song.flac", frequency: 500 + Double(disc * 10 + i),
                                  tags: tags("Sóng \(disc).\(i)", "Björk Ensemble", "Dïscs", track: i, disc: disc, year: 2015, genre: "Pop")))
            }
        }
        // Tagged compilation.
        for (i, artist) in ["Alpha", "Beta", "Gamma"].enumerated() {
            specs.append(Spec("Compilations/Hits/\(i + 1) \(artist).mp3", frequency: 600 + Double(i) * 50,
                              tags: tags("\(artist) Hit", artist, "Hits", track: i + 1, year: 2020, genre: "Pop",
                                         albumArtist: "Various Artists", compilation: true)))
        }
        // Compilation detected by folder heuristics (no album artist, three artists).
        for (i, artist) in ["Delta", "Epsilon", "Zeta"].enumerated() {
            specs.append(Spec("Mixes/Summer Mix/\(i + 1) \(artist).ogg", frequency: 700 + Double(i) * 50,
                              tags: tags("\(artist) Groove", artist, "Summer Mix", track: i + 1, year: 2021, genre: "Dance")))
        }
        // Missing tags and a mono file.
        specs.append(Spec("Loose/untagged recording.wav", channels: 1, frequency: 880))
        return specs
    }

    /// Builds `standardLibrary()` under `root` (with a folder cover for one album).
    public static func buildStandardLibrary(at root: URL) throws -> [URL] {
        var urls: [URL] = []
        for spec in standardLibrary() { urls.append(try make(spec, in: root)) }
        let coverURL = root.appendingPathComponent("The Synthetics/Sine Waves/cover.png")
        try? coverPNG(text: "SW", hue: 0.58).write(to: coverURL)
        return urls
    }

    /// A tiny generated PNG used as album art in fixtures.
    public static func coverPNG(text: String, hue: Double, size: Int = 64) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let (r, g, b) = hsvToRGB(h: hue, s: 0.6, v: 0.85)
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.fillEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
