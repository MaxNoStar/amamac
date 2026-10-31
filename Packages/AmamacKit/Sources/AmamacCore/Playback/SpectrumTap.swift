@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Synchronization

/// Collects output samples from an audio tap and computes log-spaced spectrum bands on demand
/// (the Analyzer applet polls this at display rate).
public final class SpectrumTap: @unchecked Sendable {
    struct Ring {
        var samples: [Float]
        var writeIndex = 0
        var filled = 0
        var sampleRate: Double = 44_100
        var lastWrite = Date.distantPast
    }

    private let ring: Mutex<Ring>
    public let capacity: Int

    public init(capacity: Int = 16_384) {
        self.capacity = capacity
        ring = Mutex(Ring(samples: [Float](repeating: 0, count: capacity)))
    }

    /// Called on the audio tap thread.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let rate = buffer.format.sampleRate
        ring.withLock { r in
            r.sampleRate = rate
            r.lastWrite = Date()
            for i in 0..<frames {
                var v: Float = 0
                for c in 0..<channelCount { v += channels[c][i] }
                r.samples[r.writeIndex] = v / Float(channelCount)
                r.writeIndex = (r.writeIndex + 1) % capacity
            }
            r.filled = min(capacity, r.filled + frames)
        }
    }

    public func reset() {
        ring.withLock { r in
            r.samples = [Float](repeating: 0, count: capacity)
            r.filled = 0
        }
    }

    /// Band levels in 0...1, log-spaced between `minFrequency` and `maxFrequency`.
    public func spectrum(bands: Int, sampleSize: Int = 2048, minFrequency: Float = 30, maxFrequency: Float = 16_000) -> [Float] {
        let n = max(256, min(capacity, 1 << Int(log2(Double(sampleSize)).rounded())))
        let (window, rate, stale) = ring.withLock { r -> ([Float], Double, Bool) in
            var out = [Float](repeating: 0, count: n)
            guard r.filled > 0 else { return (out, r.sampleRate, true) }
            var idx = (r.writeIndex - n + capacity) % capacity
            for i in 0..<n {
                out[i] = r.samples[idx]
                idx = (idx + 1) % capacity
            }
            return (out, r.sampleRate, Date().timeIntervalSince(r.lastWrite) > 0.5)
        }
        guard !stale, bands > 0 else { return [Float](repeating: 0, count: max(bands, 0)) }
        let magnitudes = Self.magnitudes(window)
        let binWidth = Float(rate) / Float(n)
        let lo = log10(max(minFrequency, binWidth)), hi = log10(min(maxFrequency, Float(rate) / 2))
        var result = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let f0 = pow(10, lo + (hi - lo) * Float(b) / Float(bands))
            let f1 = pow(10, lo + (hi - lo) * Float(b + 1) / Float(bands))
            let i0 = max(1, Int(f0 / binWidth)), i1 = max(i0 + 1, Int(f1 / binWidth))
            var peak: Float = 0
            for i in i0..<min(i1, magnitudes.count) { peak = max(peak, magnitudes[i]) }
            // Convert to dB and map -70...0 dB to 0...1.
            let db = 20 * log10(max(peak, 1e-7))
            result[b] = max(0, min(1, (db + 70) / 70))
        }
        return result
    }

    static func magnitudes(_ samples: [Float]) -> [Float] {
        let n = samples.count
        let log2n = vDSP_Length(log2(Double(n)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // Normalise: real FFT output is scaled by 2, Hann window halves the amplitude.
        let scale = 1 / Float(n)
        return vDSP.multiply(scale * 2, mags)
    }
}
