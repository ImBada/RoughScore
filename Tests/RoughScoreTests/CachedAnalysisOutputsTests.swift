import CryptoKit
import Foundation
import Testing
@testable import RoughScoreCore

@Suite struct CachedAnalysisOutputsTests {
    @Test func genuineMonoMeasurementsWarmReuseAndThresholdRangeKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-measurement-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        let rate = 16000.0
        let samples: [Float] = (0..<8000).map { index in
            let t = Double(index) / rate
            return Float(0.2 * min(1, t / 0.005) * exp(-t * 2) * sin(2 * .pi * 220 * t))
        }
        let sha = samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
        let settings = MonophonicTranscriber.Settings()
        let key = OwnedArtifactCache.Key(contentSHA256: sha, kind: "pitch", algorithm: MonophonicTranscriber.version,
            settings: ["channel": "left", "firstFrame": "0", "lastFrame": "8000", "minimumRMS": String(settings.minimumRMS), "attackRatio": String(settings.attackRatio)])
        let cold = try await CachedAnalysisOutputs.pitches(store: store, key: key, range: 0..<0.5, settings: settings) {
            try MonophonicTranscriber(settings: settings).analyze(samples: samples, sampleRate: rate)
        }
        #expect(!cold.proposals.isEmpty && cold.proposals.contains { $0.qualified })
        let warm = try await CachedAnalysisOutputs.pitches(store: store, key: key, range: 0..<0.5, settings: settings) {
            Issue.record("measurement cache reran analysis"); throw AudioFailure.unavailable
        }
        #expect(warm.proposals == cold.proposals && warm.version == cold.version && warm.settings == cold.settings)
        let changedSettings = MonophonicTranscriber.Settings(minimumRMS: 0.004, attackRatio: 1.9)
        var changedKey = key; changedKey.settings["minimumRMS"] = "0.004"; changedKey.settings["attackRatio"] = "1.9"
        let changed = try await CachedAnalysisOutputs.pitches(store: store, key: changedKey, range: 0..<0.5, settings: changedSettings) {
            try MonophonicTranscriber(settings: changedSettings).analyze(samples: samples, sampleRate: rate)
        }
        #expect(changed.settings == changedSettings)
        // Incompatible result metadata cannot masquerade as the current model/settings.
        await #expect(throws: ProjectError.self) {
            _ = try await CachedAnalysisOutputs.pitches(store: store, key: key, range: 0.1..<0.5, settings: settings) {
                throw AudioFailure.unavailable
            }
        }
        try await store.setQuota(0)
        #expect(try await store.diskBytes() == 0)
        // Copied algorithm outputs and project-owned review data survive storage eviction.
        #expect(warm.proposals == cold.proposals)
    }
    @Test func unavailableAndInvalidBackendNeverPublishFabricatedSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-summary-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        let key = OwnedArtifactCache.Key(contentSHA256: String(repeating: "a", count: 64), kind: "summary", algorithm: "test-backend-v1")
        await #expect(throws: AudioFailure.self) {
            _ = try await CachedAnalysisOutputs.summary(store: store, key: key, duration: 3) { throw AudioFailure.unavailable }
        }
        await #expect(throws: ProjectError.self) {
            _ = try await CachedAnalysisOutputs.summary(store: store, key: key, duration: 3) { AnalysisSummary(beats: [99]) }
        }
        #expect(try await store.diskBytes() == 0)
    }
    private enum AudioFailure: Error { case unavailable }
}
