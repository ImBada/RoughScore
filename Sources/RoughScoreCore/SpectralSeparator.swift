import Accelerate
import Foundation

/// Real STFT/iSTFT matching `torch.stft`/`torch.istft` with a periodic Hann window,
/// `center=True`, reflect padding, one-sided spectrum and no normalisation.
public final class TorchCompatibleSTFT {
    public let nFFT: Int
    public let hop: Int
    public var bins: Int { nFFT / 2 + 1 }
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var frameBuffer: [Float]

    public init(nFFT: Int, hop: Int) {
        precondition(nFFT >= 4 && nFFT & (nFFT - 1) == 0 && hop > 0)
        self.nFFT = nFFT; self.hop = hop
        log2n = vDSP_Length(log2(Double(nFFT)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = (0..<nFFT).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nFFT)) }
        realBuffer = [Float](repeating: 0, count: nFFT / 2)
        imagBuffer = realBuffer
        frameBuffer = [Float](repeating: 0, count: nFFT)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func frameCount(samples: Int) -> Int { samples / hop + 1 }

    /// Calls `emit(frame, real, imag)` with `bins` values per frame.
    public func forward(_ signal: [Float], emit: (Int, UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) -> Void) {
        let pad = nFFT / 2
        precondition(signal.count > pad, "reflect padding needs more samples than nFFT / 2")
        var padded = [Float](repeating: 0, count: signal.count + 2 * pad)
        for i in 0..<pad { padded[i] = signal[pad - i] }
        padded.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: pad).update(from: signal, count: signal.count) }
        for i in 0..<pad { padded[pad + signal.count + i] = signal[signal.count - 2 - i] }
        var real = [Float](repeating: 0, count: bins), imag = real
        let half = nFFT / 2
        for frame in 0..<frameCount(samples: signal.count) {
            let start = frame * hop
            padded.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &frameBuffer, 1, vDSP_Length(nFFT))
            }
            realBuffer.withUnsafeMutableBufferPointer { rp in
                imagBuffer.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frameBuffer.withUnsafeBufferPointer { fb in
                        fb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP returns 2 × DFT, with DC and Nyquist packed into element 0.
            real[0] = realBuffer[0] * 0.5; imag[0] = 0
            real[half] = imagBuffer[0] * 0.5; imag[half] = 0
            for k in 1..<half { real[k] = realBuffer[k] * 0.5; imag[k] = imagBuffer[k] * 0.5 }
            real.withUnsafeBufferPointer { r in imag.withUnsafeBufferPointer { i in emit(frame, r, i) } }
        }
    }

    /// Overlap-adds `frames` one-sided spectra (each `bins` real + `bins` imag via `spectrum`) and
    /// returns exactly `length` samples, dividing by the summed squared window like `torch.istft`.
    public func inverse(frames: Int, length: Int, spectrum: (Int, UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void) -> [Float] {
        let half = nFFT / 2
        let total = nFFT + hop * (frames - 1)
        var output = [Float](repeating: 0, count: total)
        var windowSum = [Float](repeating: 0, count: total)
        var squared = [Float](repeating: 0, count: nFFT)
        vDSP_vsq(window, 1, &squared, 1, vDSP_Length(nFFT))
        var real = [Float](repeating: 0, count: bins), imag = real
        var scale = 1 / Float(nFFT)
        for frame in 0..<frames {
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in spectrum(frame, r, i) } }
            realBuffer[0] = real[0]; imagBuffer[0] = real[half]
            for k in 1..<half { realBuffer[k] = real[k]; imagBuffer[k] = imag[k] }
            realBuffer.withUnsafeMutableBufferPointer { rp in
                imagBuffer.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frameBuffer.withUnsafeMutableBufferPointer { fb in
                        fb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            vDSP_vsmul(frameBuffer, 1, &scale, &frameBuffer, 1, vDSP_Length(nFFT))
            vDSP_vmul(frameBuffer, 1, window, 1, &frameBuffer, 1, vDSP_Length(nFFT))
            let start = frame * hop
            output.withUnsafeMutableBufferPointer { out in
                vDSP_vadd(out.baseAddress! + start, 1, frameBuffer, 1, out.baseAddress! + start, 1, vDSP_Length(nFFT))
            }
            windowSum.withUnsafeMutableBufferPointer { sum in
                vDSP_vadd(sum.baseAddress! + start, 1, squared, 1, sum.baseAddress! + start, 1, vDSP_Length(nFFT))
            }
        }
        let pad = nFFT / 2
        var result = [Float](repeating: 0, count: length)
        for i in 0..<min(length, total - pad) {
            let w = windowSum[pad + i]
            result[i] = w > 1e-11 ? output[pad + i] / w : output[pad + i]
        }
        return result
    }
}

/// Chunked stereo mask separation, following Music-Source-Separation-Training `demix`
/// (generic mode): reflect border padding, `overlap` chunks per window with linear fades,
/// weighted overlap-add. The model is supplied as a closure so this stays testable.
public struct SpectralSeparator {
    public struct Configuration: Equatable, Sendable, Codable {
        public var sampleRate: Double
        public var nFFT: Int
        public var hop: Int
        public var chunkSamples: Int
        public var overlap: Int
        public init(sampleRate: Double, nFFT: Int, hop: Int, chunkSamples: Int, overlap: Int) {
            self.sampleRate = sampleRate; self.nFFT = nFFT; self.hop = hop
            self.chunkSamples = chunkSamples; self.overlap = overlap
        }
        public var frames: Int { chunkSamples / hop + 1 }
        /// Model row width: freq × stereo × complex.
        public var width: Int { (nFFT / 2 + 1) * 4 }
    }

    public let configuration: Configuration
    public init(configuration: Configuration) {
        precondition(configuration.overlap >= 1 && configuration.chunkSamples > configuration.nFFT)
        self.configuration = configuration
    }

    /// Number of model calls for `samples` input samples (for progress reporting).
    public func chunkCount(samples: Int) -> Int {
        let c = configuration.chunkSamples, step = c / configuration.overlap, border = c - step
        let padded = samples > 2 * border && border > 0 ? samples + 2 * border : samples
        return max(1, (padded + step - 1) / step)
    }

    /// `mask` receives a `(frames × width)` row-major spectrum and returns a same-sized complex mask.
    /// Throws `CancellationError` when `isCancelled` turns true between chunks.
    public func separate(left: [Float], right: [Float],
                         isCancelled: () -> Bool = { false },
                         progress: (Double) -> Void = { _ in },
                         mask: ([Float]) throws -> [Float]) throws -> (left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        let length = left.count
        guard length > 0 else { return ([], []) }
        let c = configuration.chunkSamples, step = c / configuration.overlap, border = c - step
        let fade = c / 10
        let padBorder = length > 2 * border && border > 0
        let channels = [left, right].map { padBorder ? Self.reflectPad($0, border) : $0 }
        let total = channels[0].count
        var fadeWindow = [Float](repeating: 1, count: c)
        if fade > 1 {
            for i in 0..<fade {
                let ramp = Float(i) / Float(fade - 1)
                fadeWindow[i] = ramp; fadeWindow[c - fade + i] = 1 - ramp
            }
        }
        var result = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        var counter = [Float](repeating: 0, count: total)
        let stft = TorchCompatibleSTFT(nFFT: configuration.nFFT, hop: configuration.hop)
        let frames = configuration.frames, width = configuration.width, bins = stft.bins
        let chunks = chunkCount(samples: length)
        var index = 0, start = 0
        while start < total {
            if isCancelled() { throw CancellationError() }
            let segment = min(c, total - start)
            var parts = channels.map { Array($0[start..<(start + segment)]) }
            if segment < c {
                parts = parts.map { segment > c / 2 ? Self.reflectPadEnd($0, to: c) : $0 + [Float](repeating: 0, count: c - segment) }
            }
            var spectrum = [Float](repeating: 0, count: frames * width)
            for s in 0..<2 {
                stft.forward(parts[s]) { frame, real, imag in
                    let row = frame * width
                    for f in 0..<bins {
                        let o = row + (f * 2 + s) * 2
                        spectrum[o] = real[f]; spectrum[o + 1] = imag[f]
                    }
                }
            }
            let m = try mask(spectrum)
            guard m.count == spectrum.count else { throw SeparationError.modelOutputShape }
            var window = fadeWindow
            if start == 0 { for i in 0..<fade { window[i] = 1 } }
            if start + step >= total { for i in 0..<fade { window[c - fade + i] = 1 } }
            for s in 0..<2 {
                let audio = stft.inverse(frames: frames, length: c) { frame, real, imag in
                    let row = frame * width
                    for f in 0..<bins {
                        let o = row + (f * 2 + s) * 2
                        let xr = spectrum[o], xi = spectrum[o + 1], mr = m[o], mi = m[o + 1]
                        real[f] = xr * mr - xi * mi; imag[f] = xr * mi + xi * mr
                    }
                }
                for i in 0..<segment { result[s][start + i] += (audio[i].isFinite ? audio[i] : 0) * window[i] }
            }
            for i in 0..<segment { counter[start + i] += window[i] }
            index += 1; progress(Double(index) / Double(chunks))
            start += step
        }
        for s in 0..<2 { for i in 0..<total { result[s][i] = counter[i] > 0 ? result[s][i] / counter[i] : 0 } }
        if padBorder { result = result.map { Array($0[border..<(border + length)]) } }
        return (result[0], result[1])
    }

    public enum SeparationError: Error, Equatable { case modelOutputShape }

    /// numpy/torch "reflect": edge sample is not repeated.
    static func reflectPad(_ x: [Float], _ pad: Int) -> [Float] {
        let left = (0..<pad).map { x[pad - $0] }
        let right = (0..<pad).map { x[x.count - 2 - $0] }
        return left + x + right
    }

    static func reflectPadEnd(_ x: [Float], to length: Int) -> [Float] {
        let pad = length - x.count
        return x + (0..<pad).map { x[x.count - 2 - $0] }
    }
}
