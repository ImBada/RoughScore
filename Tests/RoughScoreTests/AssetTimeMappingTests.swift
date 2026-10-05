import Foundation
import RoughScoreCore
import Testing

struct AssetTimeMappingTests {
    @Test func storedNumericMappingIsRateIndependentAndV1RoundTripsWithoutGuessedOffset() throws {
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 2,
            sampleRate: 48000, frameCount: 120000)
        let asset = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: "/generated/stem.caf"),
            identity: identity, originalTimeOffset: -0.25)
        let mapping = try AssetTimeMapping(asset: asset, originalDuration: 2)
        #expect(mapping.assetFrame(originalTime: 0.75) == 48000)
        #expect(mapping.originalTime(frame: 48000) == 0.75)
        #expect(mapping.validOriginalWindow == TimeSpan(start: 0, end: 2))
        let summary = mapping.mapped(AnalysisSummary(beats: [0, 1, 2.5], sections: [TimeSpan(start: 0, end: 0.5)]))
        #expect(summary.beats == [0.75] && summary.sections == [TimeSpan(start: 0, end: 0.25)])
        let legacy = Data(#"{"version":1,"title":"legacy","audioPath":"/generated/original.caf","duration":2,"tuning":["E","B","G","D","A","E"],"events":[],"analyses":{}}"#.utf8)
        let project = try JSONDecoder().decode(ScoreProject.self, from: legacy).validated()
        #expect(project.assets == nil && project.tuningDefinition == nil)
        let migrated = try project.attachingStem(asset)
        #expect(migrated.originalAsset?.identity == nil && migrated.originalAsset?.originalTimeOffset == 0)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(migrated)).validated() == migrated)
        var unsupported = migrated; unsupported.assets?[1].version = 2
        #expect(throws: ProjectError.self) { try unsupported.validated() }
    }
}
