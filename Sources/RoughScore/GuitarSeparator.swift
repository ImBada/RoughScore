import AVFoundation
import CoreML
import Foundation
import RoughScoreCore

/// On-device stereo guitar separation with the BS-RoFormer SW guitar head (Core ML).
/// The model is not bundled: `scripts/separation/install-guitar-separator.sh` converts the pinned
/// checkpoint into `modelDirectory`. Output is a new stereo CAF at the original's sample rate and
/// frame count (offset 0); the user's file is only read.
struct GuitarSeparator: Sendable {
    enum SeparatorError: LocalizedError {
        case modelMissing, modelInvalid, unreadableAudio, resamplingFailed, writeFailed
        var errorDescription: String? {
            switch self {
            case .modelMissing: "기타 분리 모델이 설치되어 있지 않습니다. scripts/separation/install-guitar-separator.sh를 실행하세요."
            case .modelInvalid: "기타 분리 모델을 읽을 수 없습니다. 설치 스크립트를 다시 실행하세요."
            case .unreadableAudio: "원곡 오디오를 읽을 수 없습니다."
            case .resamplingFailed: "샘플레이트 변환에 실패했습니다."
            case .writeFailed: "분리된 기타 파일을 저장하지 못했습니다."
            }
        }
    }

    struct Metadata: Codable, Sendable {
        var schemaVersion: Int
        var checkpointSHA256: String
        var sampleRate: Double
        var nFFT: Int
        var hop: Int
        var chunkSamples: Int
        var frames: Int
        var overlap: Int
        var configuration: SpectralSeparator.Configuration {
            .init(sampleRate: sampleRate, nFFT: nFFT, hop: hop, chunkSamples: chunkSamples, overlap: overlap)
        }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoughScore", isDirectory: true)
    }
    static var modelDirectory: URL { supportDirectory.appendingPathComponent("Models/GuitarSeparator", isDirectory: true) }
    static var outputDirectory: URL { supportDirectory.appendingPathComponent("SeparatedStems", isDirectory: true) }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelDirectory.appendingPathComponent("separator.json").path)
            && (fm.fileExists(atPath: modelDirectory.appendingPathComponent("GuitarSeparator.mlmodelc").path)
                || fm.fileExists(atPath: modelDirectory.appendingPathComponent("GuitarSeparator.mlpackage").path))
    }

    static func loadMetadata() throws -> Metadata {
        guard let data = try? Data(contentsOf: modelDirectory.appendingPathComponent("separator.json")) else { throw SeparatorError.modelMissing }
        guard let meta = try? JSONDecoder().decode(Metadata.self, from: data), meta.schemaVersion == 1,
              meta.frames == meta.chunkSamples / meta.hop + 1 else { throw SeparatorError.modelInvalid }
        return meta
    }

    /// Compiles the installed `.mlpackage` once and keeps the `.mlmodelc` next to it.
    static func loadModel() throws -> MLModel {
        let fm = FileManager.default
        let compiled = modelDirectory.appendingPathComponent("GuitarSeparator.mlmodelc")
        if !fm.fileExists(atPath: compiled.path) {
            let package = modelDirectory.appendingPathComponent("GuitarSeparator.mlpackage")
            guard fm.fileExists(atPath: package.path) else { throw SeparatorError.modelMissing }
            let temporary = try MLModel.compileModel(at: package)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: temporary, to: compiled)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        do { return try MLModel(contentsOf: compiled, configuration: configuration) }
        catch { throw SeparatorError.modelInvalid }
    }

    /// Where the separated stem for an original with `sha256` content is cached.
    static func outputURL(originalSHA256: String, checkpoint: String) -> URL {
        outputDirectory.appendingPathComponent("\(originalSHA256.prefix(32))-bsroformer-\(checkpoint.prefix(12))-guitar.caf")
    }

    /// Separates `original` and returns the stem URL (reused when already separated).
    /// `progress` is called from the separation thread with 0...1.
    static func separate(original: URL, originalSHA256: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            let meta = try loadMetadata()
            let destination = outputURL(originalSHA256: originalSHA256, checkpoint: meta.checkpointSHA256)
            if let file = try? AVAudioFile(forReading: destination), file.length > 0 { progress(1); return destination }
            let model = try loadModel()
            let (channels, sampleRate) = try readStereo(original)
            try Task.checkCancellation()
            let input = try channels.map { try resample($0, from: sampleRate, to: meta.sampleRate) }
            let separator = SpectralSeparator(configuration: meta.configuration)
            let frames = meta.frames, width = meta.configuration.width
            let array = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: width)], dataType: .float32)
            let separated = try separator.separate(left: input[0], right: input[1],
                isCancelled: { Task.isCancelled }, progress: { progress($0 * 0.98) }) { spectrum in
                let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
                spectrum.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: spectrum.count) }
                let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spectrum": array]))
                guard let mask = output.featureValue(for: "mask")?.multiArrayValue else { throw SeparatorError.modelInvalid }
                return MLShapedArray<Float>(converting: mask).scalars
            }
            try Task.checkCancellation()
            let frameCount = channels[0].count
            let restored = try [separated.left, separated.right].map {
                try fit(resample($0, from: meta.sampleRate, to: sampleRate), to: frameCount)
            }
            try write(restored, sampleRate: sampleRate, to: destination)
            progress(1)
            return destination
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func readStereo(_ url: URL) throws -> ([[Float]], Double) {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0, file.length < Int64(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SeparatorError.unreadableAudio }
        do { try file.read(into: buffer) } catch { throw SeparatorError.unreadableAudio }
        let count = Int(buffer.frameLength), channelCount = Int(file.processingFormat.channelCount)
        guard count > 0, channelCount >= 1, let data = buffer.floatChannelData else { throw SeparatorError.unreadableAudio }
        let left = Array(UnsafeBufferPointer(start: data[0], count: count))
        let right = channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: count)) : left
        return ([left, right], file.processingFormat.sampleRate)
    }

    private static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard source != target else { return samples }
        let expected = Int((Double(samples.count) * target / source).rounded())
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(expected + 4096))
        else { throw SeparatorError.resamplingFailed }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw SeparatorError.resamplingFailed }
        return fit(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))), to: expected)
    }

    private static func fit(_ samples: [Float], to count: Int) -> [Float] {
        samples.count >= count ? Array(samples.prefix(count)) : samples + [Float](repeating: 0, count: count - samples.count)
    }

    private static func write(_ channels: [[Float]], sampleRate: Double, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { throw SeparatorError.writeFailed }
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let capacity = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else { throw SeparatorError.writeFailed }
            var position = 0
            while position < channels[0].count {
                let count = min(capacity, channels[0].count - position)
                for c in 0..<2 {
                    channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress! + position, count: count) }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                position += count
            }
            file.close()
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            try? fm.removeItem(at: temporary)
            throw (error as? SeparatorError) ?? SeparatorError.writeFailed
        }
    }
}
