import AVFoundation
import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@Suite struct AudioResourceOwnershipTests {
    @Test func explicitScratchWaitsForNativePinAndNeverDeletesForeignReplacement() throws {
        let fixture = try StreamingCacheFixture(seconds: 0.1, channels: 1)
        defer { fixture.clean() }
        let scratch = try OwnedAudioScratch(parent: fixture.root)
        let payload = try scratch.copy(from: fixture.source, named: "left.caf")
        var pin: OwnedAudioScratch.Pin? = try scratch.pin()
        let file = try scratch.withPinnedFile("left.caf") { try AVAudioFile(forReading: $0) }
        #expect(file.length == 4410 && pin != nil)
        scratch.dispose()
        #expect(FileManager.default.fileExists(atPath: payload.path))
        pin = nil
        #expect(!FileManager.default.fileExists(atPath: scratch.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        let replacement = try OwnedAudioScratch(parent: fixture.root)
        let oldPayload = try replacement.copy(from: fixture.source, named: "left.caf")
        try FileManager.default.removeItem(at: oldPayload)
        try Data("foreign bytes".utf8).write(to: oldPayload)
        replacement.dispose()
        #expect(try Data(contentsOf: oldPayload) == Data("foreign bytes".utf8))
    }
    @Test func pinnedCAFWriterCannotFollowStageSymlinkToOriginal() async throws {
        let fixture = try StreamingCacheFixture(seconds: 0.1, channels: 1)
        defer { fixture.clean() }
        let sourceBefore = try Data(contentsOf: fixture.source)
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let key = OwnedArtifactCache.Key(contentSHA256: String(repeating: "a", count: 64), kind: "write-race", algorithm: "v1")
        await #expect(throws: (any Error).self) {
            _ = try await store.acquire(key) { stage in
                let writer = try PinnedPCMWriter(file: stage.createPinnedFile("left.caf"), sampleRate: 44100, channels: 1)
                let path = stage.directoryURL.appendingPathComponent("left.caf")
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: fixture.source)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                buffer.frameLength = 4096; buffer.floatChannelData![0].initialize(repeating: 0.75, count: 4096)
                try writer.write(from: buffer); writer.close()
                return Data()
            }
        }
        #expect(try Data(contentsOf: fixture.source) == sourceBefore)
    }
    @Test func publishedPayloadReplacementIsNotEvictableForeignData() async throws {
        let fixture = try StreamingCacheFixture(seconds: 0.1, channels: 1)
        defer { fixture.clean() }
        let pipeline = CachedAudioPreparation(store: try OwnedArtifactCache(configuration: .init(root: fixture.cache)))
        var value: CachedAudioPreparation.Result? = try await pipeline.prepare(fixture.source)
        let path = try #require(value).lease.url("left.caf")
        value = nil
        try FileManager.default.removeItem(at: path)
        try Data("foreign regular file".utf8).write(to: path)
        let rebuilt = try await pipeline.prepare(fixture.source)
        #expect(!rebuilt.lease.cacheHit)
        try await pipeline.store.setQuota(0)
        #expect(try Data(contentsOf: path) == Data("foreign regular file".utf8))
    }
    @Test func rootMarkerReplacementRevokesCleanupAuthority() async throws {
        let fixture = try StreamingCacheFixture(seconds: 0.1, channels: 1)
        defer { fixture.clean() }
        let store = try OwnedArtifactCache(configuration: .init(root: fixture.cache))
        let value = try await CachedAudioPreparation(store: store).prepare(fixture.source)
        let marker = fixture.cache.appendingPathComponent("root-version")
        try FileManager.default.removeItem(at: marker)
        try Data("foreign root".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try value.lease.validate() }
        try await store.setQuota(0)
        #expect(try Data(contentsOf: marker) == Data("foreign root".utf8))
        #expect(FileManager.default.fileExists(atPath: value.lease.directoryURL.path))
    }
}
