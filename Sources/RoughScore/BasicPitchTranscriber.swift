import AVFoundation
import CoreML
import Foundation
import RoughScoreCore

/// Polyphonic note candidates from Spotify Basic Pitch (Apache-2.0; ICASSP 2022 `nmp` model,
/// spotify/basic-pitch 9991303, v0.4.0; see Resources/BasicPitch). Candidates, not truth.
/// Pass one channel per call (L and R separately); nothing here downmixes. Run off the UI actor.
struct BasicPitchTranscriber: Sendable {
    enum TranscriptionError: Error, Equatable {
        case invalidSampleRate, invalidTimeOrigin, regionTooLong, nonfiniteSample, modelUnavailable, resamplingFailed
    }

    static let modelSampleRate = 22_050.0
    static let hop = 256
    /// Model input: 2 s minus one hop. Windows overlap by 30 frames; half is trimmed per side.
    static let windowSamples = 43_844
    static let windowFrames = 172
    static let overlapFrames = 30

    var settings = BasicPitchDecoder.Settings()

    /// `timeOrigin` is the original-recording time of `samples[0]`; results are in that timeline.
    /// Regions are limited to 60 s. Cancellation is checked between model windows and throws
    /// `CancellationError`; no partial result is returned.
    func transcribe(samples: [Float], sampleRate: Double, timeOrigin: Double = 0,
                    isCancelled: () -> Bool = { false }) throws -> [PolyNoteCandidate] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw TranscriptionError.invalidSampleRate }
        guard timeOrigin.isFinite, timeOrigin >= 0 else { throw TranscriptionError.invalidTimeOrigin }
        guard Double(samples.count) / sampleRate <= 60 else { throw TranscriptionError.regionTooLong }
        guard samples.allSatisfy(\.isFinite) else { throw TranscriptionError.nonfiniteSample }
        func checkpoint() throws { if isCancelled() { throw CancellationError() } }
        try checkpoint()
        guard !samples.isEmpty else { return [] }

        let audio = try Self.resample(samples, from: sampleRate)
        let model = try Self.loadModel()
        let hop = Self.hop, trim = Self.overlapFrames / 2
        let step = Self.windowSamples - Self.overlapFrames * hop
        // Like Basic Pitch, prepend half the overlap so the first kept frame is sample 0.
        let padded = [Float](repeating: 0, count: trim * hop) + audio
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
        let window = input.dataPointer.assumingMemoryBound(to: Float.self)
        var activations = BasicPitchDecoder.Activations()
        // A window's first kept frame is at original sample `start`; later windows add nothing.
        for start in stride(from: 0, to: audio.count, by: step) {
            try checkpoint()
            let count = min(Self.windowSamples, padded.count - start)
            padded.withUnsafeBufferPointer { window.update(from: $0.baseAddress! + start, count: count) }
            window.advanced(by: count).update(repeating: 0, count: Self.windowSamples - count)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
            func rows(_ name: String) throws -> [Float] {
                guard let array = output.featureValue(for: name)?.multiArrayValue else { throw TranscriptionError.modelUnavailable }
                return MLShapedArray<Float>(converting: array).scalars
            }
            let contour = try rows("Identity"), note = try rows("Identity_1"), onset = try rows("Identity_2")
            let noteBins = BasicPitchDecoder.noteBins, contourBins = BasicPitchDecoder.contourBins
            // Frame f of this window is centred on original 22.05 kHz sample start + (f - trim) * hop.
            // Basic Pitch instead assumes an 86 fps grid and applies an empirical drift correction.
            for frame in trim..<(Self.windowFrames - trim) {
                let position = start + (frame - trim) * hop
                guard position < audio.count else { break }
                activations.note += note[frame * noteBins..<(frame + 1) * noteBins]
                activations.onset += onset[frame * noteBins..<(frame + 1) * noteBins]
                activations.contour += contour[frame * contourBins..<(frame + 1) * contourBins]
                activations.frameTimes.append(timeOrigin + Double(position) / Self.modelSampleRate)
            }
        }
        try checkpoint()
        return try BasicPitchDecoder.decode(activations, settings: settings, isCancelled: isCancelled)
    }

    /// The delivered app has Contents/Resources/BasicPitch (scripts/delivery/build.py);
    /// `swift run` and tests use the SwiftPM resource bundle.
    static var modelURL: URL? {
        Bundle.main.url(forResource: "nmp", withExtension: "mlmodelc", subdirectory: "BasicPitch")
            ?? Bundle.module.url(forResource: "nmp", withExtension: "mlmodelc", subdirectory: "BasicPitch")
    }

    static func loadModel() throws -> MLModel {
        guard let url = modelURL else { throw TranscriptionError.modelUnavailable }
        let configuration = MLModelConfiguration()
        // Basic Pitch's own Core ML path is CPU-only; it is also fast enough and repeatable across Macs.
        configuration.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Band-limited conversion to the model rate. AVAudioConverter's default priming keeps
    /// output sample 0 aligned with input sample 0.
    static func resample(_ samples: [Float], from sampleRate: Double) throws -> [Float] {
        guard sampleRate != modelSampleRate else { return samples }
        let expected = Int((Double(samples.count) * modelSampleRate / sampleRate).rounded())
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: modelSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(expected + 1024))
        else { throw TranscriptionError.resamplingFailed }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw TranscriptionError.resamplingFailed }
        let converted = UnsafeBufferPointer(start: output.floatChannelData![0], count: min(expected, Int(output.frameLength)))
        return Array(converted) + [Float](repeating: 0, count: expected - converted.count)
    }
}
