import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

private actor SummaryInputGate {
    var continuation: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor SummaryInputCounter {
    var calls = 0
    func record() { calls += 1 }
}

@Suite struct SummaryBackendInputTests {
    @Test func canonicalCAFSupportsAVURLAssetColdAndWarmWithoutAnotherDecodeOrCAF() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 2); defer { fixture.clean() }
        let io = PreparationInstrumentation()
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache), instrumentation: io)
        let audio = try await environment.preparation.prepare(fixture.source)
        let expected = try audio.lease.url(audio.metadata.stereo), counter = SummaryInputCounter()
        let before = try FileManager.default.contentsOfDirectory(atPath: audio.lease.directoryURL.path).sorted()
        io.reset()
        let producer: @Sendable (URL, Double) async throws -> AnalysisSummary = { url, duration in
            #expect(url == expected && url != fixture.source && !url.path.hasPrefix("/dev/fd/"))
            let asset = AVURLAsset(url: url)
            let actualDuration = try await asset.load(.duration).seconds
            #expect(abs(actualDuration - duration) < 0.001)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
            await counter.record()
            return AnalysisSummary(beats: [0.2])
        }
        let cold = try await environment.summary(audio, channel: .stereo, modelVersion: "normal-file-v1",
            inputMode: .canonicalFile, produce: producer)
        let warm = try await environment.summary(audio, channel: .stereo, modelVersion: "normal-file-v1",
            inputMode: .canonicalFile, produce: producer)
        #expect(cold == warm && warm.provenance == nil)
        #expect(await counter.calls == 1)
        #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: audio.lease.directoryURL.path).sorted() == before)
    }

    @Test func genericProducerKeepsIndependentDescriptorSemantics() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let audio = try await environment.preparation.prepare(fixture.source)
        _ = try await environment.summary(audio, channel: .left, modelVersion: "descriptor-v1") { url, _ in
            #expect(url.path.hasPrefix("/dev/fd/"))
            let fd = try #require(Int32(url.lastPathComponent))
            let file = try AVAudioFile(forReading: url)
            #expect(fcntl(fd, F_GETFD) >= 0)
            #expect(file.length == audio.metadata.outputFrames)
            return AnalysisSummary(beats: [0.2])
        }
    }

    @Test(arguments: ["payload", "symlink", "entry", "root-marker"])
    func canonicalBindingChangesDuringAwaitCannotCommitSummary(change: String) async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let audio = try await environment.preparation.prepare(fixture.source)
        let original = try Data(contentsOf: fixture.source)
        await #expect(throws: (any Error).self) {
            _ = try await environment.summary(audio, channel: .stereo, modelVersion: "binding-v1",
                inputMode: .canonicalFile) { url, _ in
                let expected = try audio.lease.url(audio.metadata.stereo)
                #expect(url == expected)
                await Task.yield()
                switch change {
                case "payload":
                    try FileManager.default.removeItem(at: url)
                    try original.write(to: url)
                case "symlink":
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.source)
                case "entry":
                    try FileManager.default.moveItem(at: audio.lease.directoryURL,
                        to: fixture.cache.appendingPathComponent("retired-entry"))
                default:
                    let marker = fixture.cache.appendingPathComponent("root-version")
                    try FileManager.default.removeItem(at: marker)
                    try Data("foreign marker".utf8).write(to: marker)
                }
                return AnalysisSummary(beats: [0.2])
            }
        }
        let manifests = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("result.json")) }
        #expect(manifests.isEmpty)
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test func canonicalReaderRetainsGenerationAcrossConsumerCancellationAndQuota() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let gate = SummaryInputGate()
        var audio: CachedAudioPreparation.Result? = try await environment.preparation.prepare(fixture.source)
        let directory = try #require(audio).lease.directoryURL
        // Only the pending task/producer own the audio after this lexical scope exits.
        func pending(_ value: CachedAudioPreparation.Result) -> Task<AnalysisSummary, Error> {
            Task {
                try await environment.summary(value, channel: .stereo, modelVersion: "late-normal-file-v1",
                    inputMode: .canonicalFile) { url, _ in
                    await gate.pause() // Deliberately ignore cancellation until the native-style read settles.
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration).seconds
                    #expect(duration == 1)
                    return AnalysisSummary(beats: [0.2])
                }
            }
        }
        var task: Task<AnalysisSummary, Error>? = pending(try #require(audio))
        await gate.started(); audio = nil
        try await environment.preparation.store.setQuota(0)
        task?.cancel()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task?.value }
        task = nil
        for _ in 0..<100 {
            try await environment.preparation.store.trim()
            if !FileManager.default.fileExists(atPath: directory.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await environment.preparation.store.diskBytes() == 0)
    }
}
