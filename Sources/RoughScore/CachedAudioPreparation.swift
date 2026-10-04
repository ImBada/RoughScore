import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RoughScoreCore

/// App-owned prepared storage, independent of project references and accepted/reviewed proposals.
struct CachedAudioPreparation: Sendable {
    struct Settings: Sendable {
        var decoderVersion = "avfoundation-float32-v2-" + ProcessInfo.processInfo.operatingSystemVersionString
        var envelopeVersion = "uniform-100Hz-frame-bin-v1"
        var alignmentVersion = "original-grid-floor-offset-stereo-v2"
    }
    struct Metadata: Codable, Sendable {
        var identity: AudioContentIdentity
        var duration: Double
        var outputFrames: Int64
        var left: String
        var right: String
        var stereo: String
        var envelopeCount: Int
        var offset: Double?
        var originalDuration: Double?
    }
    struct Result: Sendable {
        var lease: OwnedArtifactCache.Lease
        var metadata: Metadata
        var leftPeaks: [Float]
        var rightPeaks: [Float]
    }
    let store: OwnedArtifactCache
    var settings = Settings()
    var instrumentation: PreparationInstrumentation? = nil

    func prepare(_ url: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> Result {
        try Task.checkCancellation()
        let source = try VerifiedAudioSource(url)
        let fingerprint = try await source.fingerprintAsync()
        let file = try AVAudioFile(forReading: source.pinnedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1...2).contains(format.channelCount), file.length > 0, format.sampleRate.isFinite,
              (8_000...192_000).contains(format.sampleRate), format.commonFormat == .pcmFormatFloat32 else { throw AudioIssue.unsupported }
        let duration = Double(file.length) / format.sampleRate
        guard duration <= 3600 else { throw AudioIssue.tooLong }
        let identity = AudioContentIdentity(sha256: fingerprint, channelCount: Int(format.channelCount), sampleRate: format.sampleRate, frameCount: file.length)
        let key = OwnedArtifactCache.Key(contentSHA256: fingerprint, kind: "prepared-audio", algorithm: settings.decoderVersion,
            settings: ["envelope": settings.envelopeVersion, "channels": String(format.channelCount), "rate": String(format.sampleRate),
                       "frames": String(file.length), "decoderPCM": "float32-noninterleaved", "payload": "caf-float32-interleaved-callbacks-v1", "offsetFrames": "0", "duration": String(duration)])
        let instrumentation = instrumentation
        let lease = try await store.acquire(key) { stage in
            await progress(0)
            let isMono = identity.channelCount == 1
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            let leftWriter = try PinnedPCMWriter(file: stage.createPinnedFile("left.caf"), sampleRate: format.sampleRate, channels: 1)
            let rightWriter = isMono ? nil : try PinnedPCMWriter(file: stage.createPinnedFile("right.caf"), sampleRate: format.sampleRate, channels: 1)
            let stereoWriter = isMono ? nil : try PinnedPCMWriter(file: stage.createPinnedFile("stereo.caf"), sampleRate: format.sampleRate, channels: 2)
            defer { leftWriter.close(); rightWriter?.close(); stereoWriter?.close() }
            let capacity: AVAudioFrameCount = 4096
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
            let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity)!
            let count = max(1, Int(ceil(duration * 100)))
            var leftPeaks = [Float](repeating: 0, count: count), rightPeaks = leftPeaks
            var offset: Int64 = 0
            while offset < file.length {
                try Task.checkCancellation()
                try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(capacity), file.length - offset)))
                instrumentation?.decoded()
                guard input.frameLength > 0, let channels = input.floatChannelData else { throw AudioIssue.unsupported }
                output.frameLength = input.frameLength
                for i in 0..<Int(input.frameLength) {
                    guard channels[0][i].isFinite, isMono || channels[1][i].isFinite else { throw AudioIssue.unsupported }
                    let bin = min(count - 1, Int(Double(offset + Int64(i)) / Double(file.length) * Double(count)))
                    leftPeaks[bin] = max(leftPeaks[bin], abs(channels[0][i]))
                    if !isMono { rightPeaks[bin] = max(rightPeaks[bin], abs(channels[1][i])) }
                }
                output.floatChannelData![0].update(from: channels[0], count: Int(input.frameLength))
                try leftWriter.write(from: output); instrumentation?.wrote()
                if let rightWriter {
                    output.floatChannelData![0].update(from: channels[1], count: Int(input.frameLength))
                    try rightWriter.write(from: output); instrumentation?.wrote()
                }
                if let stereoWriter { try stereoWriter.write(from: input); instrumentation?.wrote() }
                offset += Int64(input.frameLength)
                await progress(Double(offset) / Double(file.length))
            }
            leftWriter.close(); rightWriter?.close(); stereoWriter?.close()
            if isMono { rightPeaks = leftPeaks }
            try stage.write("envelope.bin", data: Self.envelopeData(leftPeaks, rightPeaks, isMono: isMono))
            guard try source.fingerprint() == fingerprint else { throw AudioIssue.sourceChanged }
            return try JSONEncoder().encode(Metadata(identity: identity, duration: duration, outputFrames: file.length,
                left: "left.caf", right: isMono ? "left.caf" : "right.caf", stereo: isMono ? "left.caf" : "stereo.caf",
                envelopeCount: count))
        }
        guard try await source.fingerprintAsync() == fingerprint else { throw AudioIssue.sourceChanged }
        let result = try Self.result(lease)
        guard result.metadata.identity == identity, result.metadata.duration == duration,
              result.metadata.outputFrames == file.length, result.metadata.offset == nil else { throw AudioIssue.sourceChanged }
        await progress(1)
        return result
    }

    /// Alignment consumes validated immutable PCM. The user's original source path remains provenance.
    func align(_ raw: Result, asset: AudioAsset, duration: Double) async throws -> Result {
        let mapping = try AssetTimeMapping(asset: asset, originalDuration: duration)
        guard raw.metadata.identity == asset.identity, raw.metadata.offset == nil else { throw AudioIssue.sourceChanged }
        let total = Int64(ceil(duration * mapping.sampleRate)), first = mapping.assetFrame(originalTime: 0)
        let key = OwnedArtifactCache.Key(contentSHA256: raw.metadata.identity.sha256, kind: "aligned-audio",
            algorithm: settings.alignmentVersion, settings: ["decoder": settings.decoderVersion, "envelope": settings.envelopeVersion,
                "payload": "caf-float32-interleaved-callbacks-v1", "alignedStereoChannels": "2", "monoStereo": "duplicate-left-right-v1", "channels": String(raw.metadata.identity.channelCount), "rate": String(mapping.sampleRate), "sourceFrames": String(mapping.frameCount),
                "originalOffset": String(mapping.offset), "offsetFrames": String(first), "duration": String(duration), "outputFrames": String(total)])
        let instrumentation = instrumentation
        let lease = try await store.acquire(key) { stage in
            let reader = try raw.lease.reader(raw.metadata.stereo)
            defer { withExtendedLifetime(reader) {} }
            let file = try AVAudioFile(forReading: reader.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length == mapping.frameCount, file.processingFormat.sampleRate == mapping.sampleRate else { throw AudioIssue.sourceChanged }
            let isMono = raw.metadata.identity.channelCount == 1
            let mono = AVAudioFormat(standardFormatWithSampleRate: mapping.sampleRate, channels: 1)!
            let stereo = AVAudioFormat(standardFormatWithSampleRate: mapping.sampleRate, channels: 2)!
            let leftWriter = try PinnedPCMWriter(file: stage.createPinnedFile("left.caf"), sampleRate: mapping.sampleRate, channels: 1)
            let rightWriter = isMono ? nil : try PinnedPCMWriter(file: stage.createPinnedFile("right.caf"), sampleRate: mapping.sampleRate, channels: 1)
            let stereoWriter = try PinnedPCMWriter(file: stage.createPinnedFile("stereo.caf"), sampleRate: mapping.sampleRate, channels: 2)
            defer { leftWriter.close(); rightWriter?.close(); stereoWriter.close() }
            let capacity: AVAudioFrameCount = 4096
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
            let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity)!
            let channel = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)!
            let bins = max(1, Int(ceil(duration * 100)))
            var left = [Float](repeating: 0, count: bins), right = left
            var position: Int64 = 0
            while position < total {
                try Task.checkCancellation()
                let count = Int(min(Int64(capacity), total - position))
                buffer.frameLength = AVAudioFrameCount(count); channel.frameLength = buffer.frameLength
                for c in 0..<Int(buffer.format.channelCount) { buffer.floatChannelData![c].update(repeating: 0, count: count) }
                let lower = max(0, first + position), upper = min(file.length, first + position + Int64(count))
                if lower < upper {
                    file.framePosition = lower
                    try file.read(into: input, frameCount: AVAudioFrameCount(upper - lower)); instrumentation?.decoded()
                    let destination = Int(lower - (first + position))
                    for c in 0..<Int(buffer.format.channelCount) {
                        buffer.floatChannelData![c].advanced(by: destination).update(from: input.floatChannelData![isMono ? 0 : c], count: Int(input.frameLength))
                    }
                }
                channel.floatChannelData![0].update(from: buffer.floatChannelData![0], count: count)
                try leftWriter.write(from: channel); instrumentation?.wrote()
                if let rightWriter {
                    channel.floatChannelData![0].update(from: buffer.floatChannelData![1], count: count)
                    try rightWriter.write(from: channel); instrumentation?.wrote()
                }
                try stereoWriter.write(from: buffer); instrumentation?.wrote()
                for i in 0..<count {
                    let bin = min(bins - 1, Int(Double(position + Int64(i)) / Double(total) * Double(bins)))
                    left[bin] = max(left[bin], abs(buffer.floatChannelData![0][i]))
                    if !isMono { right[bin] = max(right[bin], abs(buffer.floatChannelData![1][i])) }
                }
                position += Int64(count)
            }
            leftWriter.close(); rightWriter?.close(); stereoWriter.close()
            if isMono { right = left }
            try stage.write("envelope.bin", data: Self.envelopeData(left, right, isMono: isMono))
            try reader.validate()
            return try JSONEncoder().encode(Metadata(identity: raw.metadata.identity, duration: duration, outputFrames: total,
                left: "left.caf", right: isMono ? "left.caf" : "right.caf", stereo: "stereo.caf",
                envelopeCount: bins, offset: mapping.offset, originalDuration: duration))
        }
        let result = try Self.result(lease)
        guard result.metadata.identity == raw.metadata.identity, result.metadata.duration == duration,
              result.metadata.outputFrames == total, result.metadata.offset == mapping.offset else { throw AudioIssue.sourceChanged }
        return result
    }
    private static func envelopeData(_ left: [Float], _ right: [Float], isMono: Bool) -> Data {
        var data = left.withUnsafeBytes { Data($0) }
        if !isMono { right.withUnsafeBytes { data.append(contentsOf: $0) } }
        return data
    }
    private static func result(_ lease: OwnedArtifactCache.Lease) throws -> Result {
        let metadata = try JSONDecoder().decode(Metadata.self, from: lease.payload)
        _ = try metadata.identity.validated()
        guard metadata.duration.isFinite, metadata.duration > 0, metadata.duration <= 3600,
              (8_000...192_000).contains(metadata.identity.sampleRate),
              metadata.envelopeCount == max(1, Int(ceil(metadata.duration * 100))), metadata.outputFrames > 0,
              metadata.outputFrames == (metadata.offset == nil ? metadata.identity.frameCount : Int64(ceil(metadata.duration * metadata.identity.sampleRate))),
              metadata.left == "left.caf", metadata.right == (metadata.identity.channelCount == 1 ? "left.caf" : "right.caf"),
              metadata.stereo == (metadata.identity.channelCount == 1 && metadata.offset == nil ? "left.caf" : "stereo.caf") else { throw AudioIssue.unsupported }
        let mono = metadata.identity.channelCount == 1
        for name in Set([metadata.left, metadata.right, metadata.stereo]) {
            let file = try lease.withPinnedFile(name) { try AVAudioFile(forReading: $0) }
            let expectedChannels = name == "stereo.caf" ? 2 : 1
            guard file.length == metadata.outputFrames, file.processingFormat.sampleRate == metadata.identity.sampleRate,
                  file.processingFormat.channelCount == expectedChannels else { throw AudioIssue.unsupported }
        }
        let data = try lease.data("envelope.bin", maximum: 360_000 * 8)
        guard data.count == metadata.envelopeCount * 4 * (mono ? 1 : 2) else { throw AudioIssue.unsupported }
        var left = [Float](repeating: 0, count: metadata.envelopeCount)
        _ = left.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 0..<(metadata.envelopeCount * 4)) }
        var right = left
        if !mono { _ = right.withUnsafeMutableBytes { data.copyBytes(to: $0, from: (metadata.envelopeCount * 4)..<data.count) } }
        guard left.allSatisfy({ $0.isFinite && $0 >= 0 }), right.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw AudioIssue.unsupported }
        return Result(lease: lease, metadata: metadata, leftPeaks: left, rightPeaks: right)
    }
}

/// File descriptions remain pinned across source renames. No decode reads a reopened user pathname.
private final class VerifiedAudioSource: @unchecked Sendable {
    private let fd: Int32
    private let info: stat
    private let url: URL
    var pinnedURL: URL { URL(fileURLWithPath: "/dev/fd/\(fd)") }
    init(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AudioIssue.unsupported }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw AudioIssue.unsupported }
        fd = descriptor; info = value; self.url = url
    }
    deinit { close(fd) }
    func fingerprintAsync() async throws -> String {
        let task = Task.detached { try self.fingerprint() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func fingerprint() throws -> String {
        var hash = SHA256(), offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = pread(fd, &buffer, buffer.count, offset)
            guard count >= 0 else { throw AudioIssue.sourceChanged }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        var now = stat(), bound = stat()
        guard lstat(url.path, &bound) == 0, bound.st_dev == info.st_dev, bound.st_ino == info.st_ino,
              fstat(fd, &now) == 0, now.st_dev == info.st_dev, now.st_ino == info.st_ino, now.st_size == info.st_size,
              now.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, now.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              now.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, now.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw AudioIssue.sourceChanged }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-injection measured IO counters; no global hooks or machine-performance promises.
final class PreparationInstrumentation: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, writes = 0
    var snapshot: (decodeCalls: Int, cafWrites: Int) { lock.withLock { (reads, writes) } }
    func decoded() { lock.withLock { reads += 1 } }
    func wrote() { lock.withLock { writes += 1 } }
    func reset() { lock.withLock { reads = 0; writes = 0 } }
}
