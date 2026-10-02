import Foundation
import RoughScoreCore
import Testing

struct AssetSchemaTests {
    @Test func versionOneAndExtensionsPreserveAllSparseData() throws {
        let legacyJSON = #"{"version":1,"title":"legacy","duration":20,"tuning":["E","B","G","D","A","D"],"events":[],"analyses":{}}"#
        let legacy = try JSONDecoder().decode(ScoreProject.self, from: Data(legacyJSON.utf8)).validated()
        #expect(legacy.assets == nil && legacy.tuningDefinition == nil)
        #expect(legacy.soundingMIDI(string: 6, fret: 0) == nil)
        #expect(legacy.tuning.last == "D") // Never guess octave from a label.
        var document = legacy
        document.audioPath = "/generated/original.caf"
        document.assets = [AudioAsset(reference: AudioReference(path: document.audioPath!)),
                           AudioAsset(role: .importedGuitarStem, reference: AudioReference(kind: .contained, path: "Media/stem.caf"), originalTimeOffset: -0.25)]
        document.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
        #expect(document.soundingMIDI(string: 6, fret: 0) == 40)
        document.events = [TabEvent(time: 1.213456789, lane: .right, string: 6, memo: "unknown")]
        let decoded = try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(document)).validated()
        #expect(decoded == document && decoded.events[0].length == nil && decoded.events[0].fret == nil)
    }

    @Test func unsupportedNestedVersionsAndUnsafeReferencesFailSafely() {
        var asset = AudioAsset(reference: AudioReference(path: "/generated/original.caf")); asset.version = 2
        #expect(throws: ProjectError.self) { try asset.validated() }
        var tuning = TuningDefinition(); tuning.version = 2
        #expect(throws: ProjectError.self) { try tuning.validated() }
        var identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1, sampleRate: 8000, frameCount: 1)
        identity.preparationVersion = 2
        #expect(throws: ProjectError.self) { try identity.validated() }
        for path in ["../outside.caf", "/absolute.caf", "Media/../outside.caf", "Media//stem.caf", "Media\\stem.caf"] {
            #expect(throws: ProjectError.self) { try AudioReference(kind: .contained, path: path).validated() }
        }
        var project = ScoreProject(); project.version = 2
        #expect(throws: ProjectError.self) { try project.validated() }
    }

    @Test func mismatchedAnalysisProvenanceCannotBeSaved() throws {
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1, sampleRate: 8000, frameCount: 160000)
        var project = try ScoreProject(duration: 20).relinkingOriginal(path: "/generated/original.caf", identity: identity, duration: 20)
        project.analyses["stereo"] = AnalysisSummary(provenance: AnalysisProvenance(assetID: UUID(), identity: identity, channel: "stereo", analyzerVersion: "test-v1"))
        #expect(throws: ProjectError.self) { try project.validated() }
    }
}
