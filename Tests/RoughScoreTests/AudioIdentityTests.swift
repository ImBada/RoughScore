import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
private struct IdentityFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func audio(_ name: String, duration: Double = 20, value: Float = 0.1) throws -> URL {
        let url = root.appendingPathComponent(name + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let count = AVAudioFrameCount(duration * 8_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(count))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
    func document(_ project: ScoreProject, name: String = "document") throws -> URL {
        let url = root.appendingPathComponent(name + ".roughscore")
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
        return url
    }
    func services() -> WorkspaceServices {
        var s = WorkspaceServices.live
        s.lastProject = { nil }; s.rememberProject = { _ in }; s.chooseSaveDestination = { _ in nil }
        return s
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    var manual: [TabEvent] {
        [TabEvent(time: 1.213456789, lane: .left, string: 6, memo: "unknown"),
         TabEvent(time: 3.083, lane: .right, string: 2, fret: 8, length: .eighth, tentative: true, memo: "right")]
    }
}

@MainActor
struct AudioIdentityTests {
    @Test func fortyMillisecondShrinkInvalidatesBoundaryAnalysisAndRoundTrips() async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let old = ScoreProject(title: "boundary", duration: 20, events: f.manual,
                               analyses: ["stereo": AnalysisSummary(beats: [19.99], bars: [19.99])])
        let doc = try f.document(old), audio = try f.audio("short", duration: 19.960)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: doc)?.value == true)
        #expect(await workspace.loadAudio(at: audio, relink: true)?.value == true)
        #expect(workspace.project.duration == 19.960 && workspace.project.analyses.isEmpty)
        #expect(workspace.project.events == old.events)
        #expect(try workspace.project.validated() == workspace.project)
        workspace.save()
        let saved = try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: doc)).validated()
        #expect(saved == workspace.project && !workspace.dirty)
        #expect(await workspace.loadProject(at: doc)?.value == true)
        #expect(workspace.project == saved && !workspace.dirty)
    }

    @Test func provenRelocationRetainsAnalysisButDifferentAndOverwrittenContentInvalidateIt() async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let original = try f.audio("original")
        let prepared = try await AudioPreparation.prepare(original)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let identity = try #require(prepared.identity)
        var project = try ScoreProject(title: "identity", events: f.manual).relinkingOriginal(
            path: original.path, identity: identity, duration: 20)
        let asset = try #require(project.originalAsset)
        let analysis = AnalysisSummary(bpm: 120, beats: [1, 2], provenance: AnalysisProvenance(
            assetID: asset.id, identity: identity, channel: "stereo", analyzerVersion: "test-real-source-v1"))
        project.analyses = ["stereo": analysis]
        let doc = try f.document(project)
        let moved = f.root.appendingPathComponent("moved.caf")
        try FileManager.default.copyItem(at: original, to: moved)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: doc)?.value == true)
        #expect(workspace.project == project && !workspace.dirty)
        #expect(await workspace.loadAudio(at: moved, relink: true)?.value == true)
        #expect(workspace.project.analyses == project.analyses)
        #expect(workspace.project.originalAsset?.id == asset.id)
        #expect(workspace.project.events == project.events && workspace.dirty)
        workspace.save()
        let different = try f.audio("different", value: 0.2)
        #expect(await workspace.loadAudio(at: different, relink: true)?.value == true)
        #expect(workspace.project.analyses.isEmpty && workspace.project.events == project.events)
        #expect(workspace.project.originalAsset?.identity != identity)
        workspace.save()

        // Same pathname, new bytes: reopening also detects replacement, rather than trusting path/duration.
        let overwriteProject = try f.document(project, name: "overwrite")
        _ = try f.audio("original", value: 0.3)
        let overwrite = Workspace(services: f.services()); defer { overwrite.shutdown() }
        #expect(await overwrite.loadProject(at: overwriteProject)?.value == true)
        #expect(overwrite.project.analyses.isEmpty && overwrite.project.events == project.events)
        #expect(overwrite.project.originalAsset?.identity != identity && overwrite.dirty)
    }

    @Test(arguments: ["missing", "corrupt", "inaccessible"]) func audioFailureOpensSameTABOffline(kind: String) async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let audio = f.root.appendingPathComponent(kind + ".caf")
        if kind != "missing" { try Data("not an audio file".utf8).write(to: audio) }
        let project = ScoreProject(title: kind, audioPath: audio.path, duration: 20, events: f.manual)
        let doc = try f.document(project)
        var services = f.services()
        if kind == "inaccessible" { services.prepare = { _, _ in throw CocoaError(.fileReadNoPermission) } }
        services.lastProject = { doc }
        let workspace = Workspace(services: services, awaitsStartup: true); defer { workspace.shutdown() }
        #expect(await workspace.start()?.value == true)
        #expect(workspace.project == project && !workspace.isDemo && workspace.hasSaveLocation)
        #expect(workspace.prepared == nil && workspace.audioConnection.contains("오프라인"))
        #expect(!workspace.dirty)
        workspace.addEvent(time: 4.123, string: 1); workspace.inputDigit(0, at: 100)
        workspace.save()
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: doc)) == workspace.project)
        #expect(!workspace.dirty)
    }

    @Test func outOfRangeRelinkIsAtomicAndKeepsPlaybackHistoryAndDestination() async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let original = try f.audio("old"), short = try f.audio("too-short", duration: 3)
        let project = ScoreProject(title: "preserved", audioPath: original.path, duration: 20, events: f.manual)
        let doc = try f.document(project)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: doc)?.value == true)
        workspace.save()
        workspace.select(workspace.project.events[0]); workspace.inputDigit(7, at: 100)
        let before = workspace.project, selected = workspace.selectedID, directory = workspace.prepared?.directory
        let bytes = try Data(contentsOf: doc)
        #expect(await workspace.loadAudio(at: short, relink: true)?.value == false)
        #expect(workspace.project == before && workspace.selectedID == selected && workspace.canUndo)
        #expect(workspace.prepared?.directory == directory && workspace.dirty)
        #expect(try Data(contentsOf: doc) == bytes)
        workspace.save()
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: doc)) == before)
        workspace.undoEdit(); #expect(workspace.project.events == project.events)
    }

    @Test(arguments: [false, true]) func analysisAttributesActualSourceAndRejectsConcurrentReplacement(replace: Bool) async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let audio = try f.audio("analysis")
        var services = f.services()
        services.analyzerVersion = "controlled-provenance-test-v1"
        services.analyze = { _, _ in
            if replace { try Data("changed while analyzing".utf8).write(to: audio, options: .atomic) }
            return AnalysisSummary(bpm: 120, beats: [1, 2])
        }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: audio)?.value == true)
        workspace.addEvent(time: 1.213, string: 6)
        let events = workspace.project.events
        let task = try #require(workspace.analyze()); await task.value
        #expect(workspace.project.events == events)
        if replace {
            #expect(workspace.project.analyses.isEmpty && workspace.error != nil)
        } else {
            let provenance = try #require(workspace.project.analyses["stereo"]?.provenance)
            #expect(provenance.assetID == workspace.project.originalAsset?.id)
            #expect(provenance.identity == workspace.prepared?.identity)
            #expect(provenance.channel == "stereo" && provenance.analyzerVersion == services.analyzerVersion)
            let decoded = try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(workspace.project)).validated()
            #expect(decoded == workspace.project)
        }
    }

    @Test func corruptReplacementInvalidatesDerivedDataWhileKeepingOfflineTAB() async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let original = try f.audio("corrupt-replacement")
        let audio = try await AudioPreparation.prepare(original)
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let identity = try #require(audio.identity)
        var project = try ScoreProject(title: "keep TAB", duration: 20, events: f.manual).relinkingOriginal(
            path: original.path, identity: identity, duration: 20)
        let asset = try #require(project.originalAsset)
        project.analyses["stereo"] = AnalysisSummary(bpm: 120, beats: [1], provenance: AnalysisProvenance(
            assetID: asset.id, identity: identity, channel: "stereo", analyzerVersion: "source-test-v1"))
        let doc = try f.document(project)
        try Data("corrupt replacement bytes".utf8).write(to: original, options: .atomic)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: doc)?.value == true)
        #expect(workspace.project.events == project.events && workspace.project.duration == project.duration)
        #expect(workspace.prepared == nil && workspace.project.analyses.isEmpty)
        #expect(workspace.project.originalAsset?.identity == nil && workspace.dirty)
        workspace.save()
        let saved = try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: doc)).validated()
        #expect(saved == workspace.project && !workspace.dirty)
    }

    @Test(arguments: [false, true]) func missingAudioKeepsOnlyProvenOfflineSummaries(proven: Bool) async throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let path = f.root.appendingPathComponent("missing.caf").path
        var project = ScoreProject(title: "offline provenance", audioPath: path, duration: 20, events: f.manual,
                                   analyses: ["stereo": AnalysisSummary(bpm: 120, beats: [1])])
        if proven {
            let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1, sampleRate: 8000, frameCount: 160000)
            let asset = AudioAsset(reference: AudioReference(path: path), identity: identity)
            project.assets = [asset]
            project.analyses["stereo"]?.provenance = AnalysisProvenance(assetID: asset.id, identity: identity,
                channel: "stereo", analyzerVersion: "known-source-v1")
        }
        let doc = try f.document(project)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: doc)?.value == true)
        #expect(workspace.project.events == project.events && workspace.project.duration == project.duration)
        #expect(workspace.prepared == nil)
        #expect(workspace.project.analyses.isEmpty == !proven)
        #expect(workspace.dirty == !proven)
    }

    @Test func legacyAnalysisWithoutProvenanceIsInvalidatedEvenForSameLength() throws {
        let f = try IdentityFixture(); defer { f.clean() }
        let legacy = ScoreProject(title: "legacy", duration: 20, events: f.manual,
                                  analyses: ["stereo": AnalysisSummary(bpm: 120)])
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1,
                                           sampleRate: 8_000, frameCount: 160_000)
        let relinked = try legacy.relinkingOriginal(path: "/generated/new.caf", identity: identity, duration: 20)
        #expect(relinked.analyses.isEmpty && relinked.events == legacy.events)
    }
}
