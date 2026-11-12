import Foundation
@testable import RoughScoreCore
import Testing

struct SpectralSeparatorTests {
    private func signal(_ count: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
    }

    @Test func forwardMatchesNaiveCenteredReflectDFT() {
        let n = 16, hop = 4
        let x = signal(37)
        let stft = TorchCompatibleSTFT(nFFT: n, hop: hop)
        let pad = n / 2
        let padded = (0..<pad).map { x[pad - $0] } + x + (0..<pad).map { x[x.count - 2 - $0] }
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        var frames = 0
        stft.forward(x) { frame, real, imag in
            frames += 1
            for k in 0...(n / 2) {
                var re = 0.0, im = 0.0
                for t in 0..<n {
                    let v = Double(padded[frame * hop + t]) * window[t]
                    re += v * cos(-2 * Double.pi * Double(k * t) / Double(n))
                    im += v * sin(-2 * Double.pi * Double(k * t) / Double(n))
                }
                #expect(abs(Double(real[k]) - re) < 1e-4)
                #expect(abs(Double(imag[k]) - im) < 1e-4)
            }
        }
        #expect(frames == x.count / hop + 1)
    }

    @Test func inverseReconstructsTheSignal() {
        let stft = TorchCompatibleSTFT(nFFT: 64, hop: 16)
        let x = signal(1000)
        var spectra: [([Float], [Float])] = []
        stft.forward(x) { _, r, i in spectra.append((Array(r), Array(i))) }
        let y = stft.inverse(frames: spectra.count, length: x.count) { frame, r, i in
            _ = r.update(fromContentsOf: spectra[frame].0); _ = i.update(fromContentsOf: spectra[frame].1)
        }
        #expect(y.count == x.count)
        #expect(zip(x, y).map { abs($0 - $1) }.max()! < 1e-4)
    }

    private let config = SpectralSeparator.Configuration(sampleRate: 1000, nFFT: 64, hop: 16, chunkSamples: 640, overlap: 2)

    @Test func identityMaskReturnsInputAcrossChunkBoundaries() throws {
        let separator = SpectralSeparator(configuration: config)
        for length in [100, 500, 641, 3001] {  // shorter than a chunk, near half, just over, many chunks
            let l = signal(length, seed: 1), r = signal(length, seed: 2)
            var calls = 0
            let out = try separator.separate(left: l, right: r) { spectrum in
                calls += 1
                #expect(spectrum.count == config.frames * config.width)
                var mask = [Float](repeating: 0, count: spectrum.count)
                for i in stride(from: 0, to: mask.count, by: 2) { mask[i] = 1 }
                return mask
            }
            #expect(calls == separator.chunkCount(samples: length))
            #expect(out.left.count == length && out.right.count == length)
            #expect(zip(l, out.left).map { abs($0 - $1) }.max()! < 1e-3)
            #expect(zip(r, out.right).map { abs($0 - $1) }.max()! < 1e-3)
        }
    }

    @Test func channelLayoutKeepsLeftAndRightSeparate() throws {
        let separator = SpectralSeparator(configuration: config)
        let l = signal(2000, seed: 3), r = signal(2000, seed: 4)
        // Keep only stereo channel 0 (layout: (freq * 2 + channel) * 2 + complex).
        let out = try separator.separate(left: l, right: r) { spectrum in
            var mask = [Float](repeating: 0, count: spectrum.count)
            for row in stride(from: 0, to: mask.count, by: config.width) {
                for f in 0..<(config.nFFT / 2 + 1) { mask[row + f * 4] = 1 }
            }
            return mask
        }
        #expect(zip(l, out.left).map { abs($0 - $1) }.max()! < 1e-3)
        #expect(out.right.map { abs($0) }.max()! < 1e-5)
    }

    @Test func cancellationStopsBetweenChunks() {
        let separator = SpectralSeparator(configuration: config)
        var calls = 0
        #expect(throws: CancellationError.self) {
            _ = try separator.separate(left: signal(5000), right: signal(5000), isCancelled: { calls >= 2 }) { spectrum in
                calls += 1; return spectrum
            }
        }
        #expect(calls == 2)
    }

    @Test func wrongModelOutputSizeIsRejected() {
        let separator = SpectralSeparator(configuration: config)
        #expect(throws: SpectralSeparator.SeparationError.modelOutputShape) {
            _ = try separator.separate(left: signal(700), right: signal(700)) { _ in [0] }
        }
    }
}
