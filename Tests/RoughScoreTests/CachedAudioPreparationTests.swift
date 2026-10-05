import AVFoundation
import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

/// Generated media only. Fixture generation and sample verification both stream bounded buffers.
@Suite struct CachedAudioPreparationTests {
    @Test func genuineThreeMinuteWarmPrepareAndRenamePreserveFramesEnvelopeAndBytes() async throws {
        let fixture = try StreamingCacheFixture(seconds: 180, channels: 2)
        defer { fixture.clean() }
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let counters = PreparationInstrumentation()
        let pipeline = CachedAudioPreparation(store: store, instrumentation: counters)
        let cold = try await pipeline.prepare(fixture.source)
        #expect(!cold.lease.cacheHit && counters.snapshot.decodeCalls > 0 && counters.snapshot.cafWrites > 0)
        counters.reset()
        let warm = try await pipeline.prepare(fixture.source)
        #expect(warm.lease.cacheHit && counters.snapshot.decodeCalls == 0 && counters.snapshot.cafWrites == 0)
        #expect(cold.metadata.identity == warm.metadata.identity && cold.metadata.outputFrames == 7_938_000)
        #expect(cold.leftPeaks == warm.leftPeaks && cold.rightPeaks == warm.rightPeaks)
        let renamed = fixture.root.appendingPathComponent("renamed.caf")
        try FileManager.default.moveItem(at: fixture.source, to: renamed)
        let moved = try await pipeline.prepare(renamed)
        #expect(moved.lease.cacheHit && moved.lease.directoryURL == warm.lease.directoryURL)
        #expect(counters.snapshot.decodeCalls == 0 && counters.snapshot.cafWrites == 0)
        try fixture.verify(warm)
        print("ISSUE13 three-minute generated stereo cold/warm frames=7938000 warmDecode=0 warmCAFWrite=0 renameHit=true")
    }
    @Test func monoOnePayloadAndSettingsMissAndAlignedGridIdentity() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1.0001, channels: 1)
        defer { fixture.clean() }
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let pipeline = CachedAudioPreparation(store: store)
        let raw = try await pipeline.prepare(fixture.source)
        #expect(raw.metadata.left == raw.metadata.right && raw.metadata.left == raw.metadata.stereo)
        #expect(raw.leftPeaks == raw.rightPeaks)
        #expect(try FileManager.default.contentsOfDirectory(atPath: raw.lease.directoryURL.path).filter { $0.hasSuffix(".caf") } == ["left.caf"])
        var changed = pipeline; changed.settings.decoderVersion += "-changed"
        #expect(try await changed.prepare(fixture.source).lease.cacheHit == false)
        var asset = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: fixture.source.path), identity: raw.metadata.identity,
                               originalTimeOffset: 0.1234567)
        let aligned = try await pipeline.align(raw, asset: asset, duration: 2)
        #expect(aligned.metadata.outputFrames == 88_200 && aligned.leftPeaks == aligned.rightPeaks)
        let mapping = try AssetTimeMapping(asset: asset, originalDuration: 2)
        let file = try aligned.lease.withPinnedFile(aligned.metadata.left) { try AVAudioFile(forReading: $0) }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var position: Int64 = 0
        while position < file.length {
            try file.read(into: buffer)
            for i in 0..<Int(buffer.frameLength) {
                let sourceFrame = mapping.assetFrame(originalTime: 0) + position + Int64(i)
                let sample = buffer.floatChannelData![0][i]
                let expected = (0..<raw.metadata.identity.frameCount).contains(sourceFrame) ? StreamingCacheFixture.sample(sourceFrame, channel: 0) : 0
                #expect(sample == expected)
            }
            position += Int64(buffer.frameLength)
        }
        #expect(try await pipeline.align(raw, asset: asset, duration: 2).lease.cacheHit)
        asset.originalTimeOffset += 1 / 44100
        #expect(try await pipeline.align(raw, asset: asset, duration: 2).lease.cacheHit == false)
        #expect(try await pipeline.align(raw, asset: asset, duration: 2.1).lease.cacheHit == false)
    }
    @Test(arguments: [0.25, -0.25, 5.0, -5.0])
    func alignedMonoStereoBackingDuplicatesBothChannelsIncludingSilence(offset: Double) async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1)
        defer { fixture.clean() }
        let pipeline = CachedAudioPreparation(store: try OwnedArtifactCache(configuration: .init(root: fixture.cache)))
        let raw = try await pipeline.prepare(fixture.source)
        let asset = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: fixture.source.path),
                               identity: raw.metadata.identity, originalTimeOffset: offset)
        let aligned = try await pipeline.align(raw, asset: asset, duration: 3)
        let audio = try PreparedAudio.cached(aligned, original: fixture.source,
                                             mapping: AssetTimeMapping(asset: asset, originalDuration: 3))
        let file = try aligned.lease.withPinnedFile(aligned.metadata.stereo) { try AVAudioFile(forReading: $0) }
        #expect(file.length == 132300 && file.processingFormat.channelCount == 2)
        #expect(audio.isMono && audio.left == audio.right && audio.url(for: .stereo) != audio.left)
        guard file.processingFormat.channelCount == 2 else { return } // Failure recorded above; avoid out-of-bounds access.
        let mapping = try AssetTimeMapping(asset: asset, originalDuration: 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var position: Int64 = 0
        while position < file.length {
            try file.read(into: buffer)
            for i in 0..<Int(buffer.frameLength) {
                let sourceFrame = mapping.assetFrame(originalTime: 0) + position + Int64(i)
                let expected = (0..<raw.metadata.outputFrames).contains(sourceFrame) ? StreamingCacheFixture.sample(sourceFrame, channel: 0) : 0
                #expect(buffer.floatChannelData![0][i] == expected && buffer.floatChannelData![1][i] == expected)
            }
            position += Int64(buffer.frameLength)
        }
        let warm = try await pipeline.align(raw, asset: asset, duration: 3)
        #expect(warm.lease.cacheHit && warm.metadata.stereo == "stereo.caf")
    }
    @Test func oldOneChannelAlignedEntryCannotSatisfyStereoTransform() async throws {
        let fixture = try StreamingCacheFixture(seconds: 0.1, channels: 1); defer { fixture.clean() }
        let io = PreparationInstrumentation()
        let pipeline = CachedAudioPreparation(store: try OwnedArtifactCache(configuration: .init(root: fixture.cache)), instrumentation: io)
        let raw = try await pipeline.prepare(fixture.source), identity = raw.metadata.identity
        // Reproduce the exact previous transform key and its valid one-channel payload.
        let key = OwnedArtifactCache.Key(contentSHA256: identity.sha256, kind: "aligned-audio",
            algorithm: "original-grid-floor-offset-v1", settings: ["decoder": pipeline.settings.decoderVersion,
                "envelope": pipeline.settings.envelopeVersion, "payload": "caf-float32-interleaved-callbacks-v1",
                "channels": "1", "rate": String(identity.sampleRate), "sourceFrames": String(identity.frameCount),
                "originalOffset": "0.0", "offsetFrames": "0", "duration": String(raw.metadata.duration), "outputFrames": String(identity.frameCount)])
        let legacy = try await pipeline.store.acquire(key) { stage in
            try stage.write("left.caf", data: raw.lease.data("left.caf", maximum: 100_000))
            try stage.write("envelope.bin", data: raw.lease.data("envelope.bin", maximum: 100_000))
            var metadata = raw.metadata; metadata.offset = 0; metadata.originalDuration = metadata.duration
            return try JSONEncoder().encode(metadata)
        }
        let legacyFile = try legacy.withPinnedFile("left.caf") { try AVAudioFile(forReading: $0) }
        #expect(legacyFile.processingFormat.channelCount == 1)
        let asset = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: fixture.source.path), identity: identity)
        let fixed = try await pipeline.align(raw, asset: asset, duration: raw.metadata.duration)
        #expect(!fixed.lease.cacheHit && fixed.lease.directoryURL != legacy.directoryURL)
        #expect(fixed.metadata.stereo == "stereo.caf")
        io.reset()
        #expect(try await pipeline.align(raw, asset: asset, duration: raw.metadata.duration).lease.cacheHit)
        #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0)
        #expect(try legacy.data("left.caf", maximum: 100_000) == raw.lease.data("left.caf", maximum: 100_000))
    }
    @Test func replacementContentAndEnvelopeVersionMiss() async throws {
        let fixture = try StreamingCacheFixture(seconds: 0.5, channels: 2)
        defer { fixture.clean() }
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let pipeline = CachedAudioPreparation(store: store)
        let cold = try await pipeline.prepare(fixture.source)
        var changed = pipeline; changed.settings.envelopeVersion += "-different"
        #expect(try await changed.prepare(fixture.source).lease.cacheHit == false)
        try StreamingCacheFixture.write(fixture.source, seconds: 0.6, channels: 2)
        let replaced = try await pipeline.prepare(fixture.source)
        #expect(!replaced.lease.cacheHit && replaced.metadata.identity != cold.metadata.identity)
    }
    @Test func generatedColdWarmProfile() async throws {
        guard let value = ProcessInfo.processInfo.environment["ROUGH_SCORE_CACHE_PROFILE_SECONDS"], let seconds = Double(value),
              let path = ProcessInfo.processInfo.environment["ROUGH_SCORE_CACHE_PROFILE_OUTPUT"] else { return }
        let channels = UInt32(ProcessInfo.processInfo.environment["ROUGH_SCORE_CACHE_PROFILE_CHANNELS"] ?? "2") ?? 2
        let fixture = try StreamingCacheFixture(seconds: seconds, channels: channels)
        defer { fixture.clean() }
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let counters = PreparationInstrumentation()
        let pipeline = CachedAudioPreparation(store: store, instrumentation: counters)
        let clock = ContinuousClock(), start = clock.now
        let cold = try await pipeline.prepare(fixture.source)
        let coldSeconds = Self.seconds(start.duration(to: clock.now)), coldIO = counters.snapshot
        let storage = try await store.diskBytes()
        counters.reset(); let warmStart = clock.now
        let warm = try await pipeline.prepare(fixture.source)
        let warmSeconds = Self.seconds(warmStart.duration(to: clock.now)), warmIO = counters.snapshot
        #expect(warm.lease.cacheHit && warmIO.decodeCalls == 0 && warmIO.cafWrites == 0)
        #expect(cold.leftPeaks == warm.leftPeaks && cold.rightPeaks == warm.rightPeaks && cold.metadata.identity == warm.metadata.identity)
        try fixture.verify(warm)
        let waveStart = clock.now
        var checksum: Float = 0
        let rowDuration = min(12, seconds), rowStart = max(0, (seconds - rowDuration) / 2)
        for _ in 0..<100 {
            for column in 0..<512 {
                let lower = rowStart + rowDuration * Double(column) / 512
                let upper = rowStart + rowDuration * Double(column + 1) / 512
                checksum += WaveformEnvelope.peak(warm.leftPeaks, duration: seconds, from: lower, to: upper)
                checksum += WaveformEnvelope.peak(warm.rightPeaks, duration: seconds, from: lower, to: upper)
            }
        }
        let rowMilliseconds = Self.seconds(waveStart.duration(to: clock.now)) * 1000 / 100
        let overviewStart = clock.now
        for _ in 0..<20 {
            for column in 0..<512 {
                let lower = seconds * Double(column) / 512, upper = seconds * Double(column + 1) / 512
                checksum += WaveformEnvelope.peak(warm.leftPeaks, duration: seconds, from: lower, to: upper)
                checksum += WaveformEnvelope.peak(warm.rightPeaks, duration: seconds, from: lower, to: upper)
            }
        }
        let overviewMilliseconds = Self.seconds(overviewStart.duration(to: clock.now)) * 1000 / 20
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["seconds": seconds, "channels": channels, "sampleRate": 44100, "frames": cold.metadata.outputFrames,
            "coldWallSeconds": coldSeconds, "warmWallSeconds": warmSeconds, "coldDecodeCalls": coldIO.decodeCalls,
            "coldCAFWrites": coldIO.cafWrites, "warmDecodeCalls": warmIO.decodeCalls, "warmCAFWrites": warmIO.cafWrites,
            "ownedDiskBytes": storage, "peakRSSBytes": usage.ru_maxrss, "envelopesEqual": true,
            "waveform12SecondRowMilliseconds": rowMilliseconds, "waveformFullClipOverviewMilliseconds": overviewMilliseconds,
            "waveformQueryScope": "512 columns per lane; 100 row/20 overview repetitions; query math only, excluding SwiftUI drawing", "waveformChecksum": checksum,
            "environment": ProcessInfo.processInfo.operatingSystemVersionString, "memoryScope": "test-process peak including fixture, cold, warm and verification; no per-phase attribution"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("ISSUE13 PROFILE \(report)")
    }
    private static func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }
}

struct StreamingCacheFixture {
    let root: URL
    var source: URL { root.appendingPathComponent("generated.caf") }
    var cache: URL { root.appendingPathComponent("cache") }
    init(seconds: Double, channels: UInt32) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RoughScore-generated-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Self.write(source, seconds: seconds, channels: channels)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    static func sample(_ frame: Int64, channel: Int) -> Float {
        // Exact binary fractions, asymmetric channels, attacks and silence: strict bit equality is meaningful.
        frame % 44_100 < 2048 ? Float((frame % 31) - 15) / (channel == 0 ? 32 : -64) : 0
    }
    static func write(_ url: URL, seconds: Double, channels: UInt32) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: channels)!
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { writer.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let frames = Int64(ceil(seconds * 44100)), capacity = Int64(buffer.frameCapacity)
        var position: Int64 = 0
        while position < frames {
            let count = Int(min(capacity, frames - position)); buffer.frameLength = AVAudioFrameCount(count)
            for c in 0..<Int(channels) { for i in 0..<count { buffer.floatChannelData![c][i] = sample(position + Int64(i), channel: c) } }
            try writer.write(from: buffer); position += Int64(count)
        }
    }
    func verify(_ result: CachedAudioPreparation.Result) throws {
        for name in Set([result.metadata.left, result.metadata.right, result.metadata.stereo]) {
            let file = try result.lease.withPinnedFile(name) { try AVAudioFile(forReading: $0) }
            #expect(file.length == result.metadata.outputFrames)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            var position: Int64 = 0
            while position < file.length {
                try file.read(into: buffer)
                // Check actual sample positions at each chunk boundary and asymmetric transients, bounded memory.
                for i in Set([0, min(31, Int(buffer.frameLength) - 1), Int(buffer.frameLength) - 1]) {
                    for c in 0..<Int(file.processingFormat.channelCount) {
                        let sourceChannel = name == "right.caf" ? 1 : c
                        #expect(buffer.floatChannelData![c][i] == Self.sample(position + Int64(i), channel: sourceChannel))
                    }
                }
                position += Int64(buffer.frameLength)
            }
        }
    }
}
