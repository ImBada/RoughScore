import AVFoundation
import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

private actor CacheCompletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor CacheAnalysisCounter {
    private(set) var calls = 0
    func summary(_ url: URL, duration: Double) throws -> AnalysisSummary {
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
        calls += 1
        return AnalysisSummary(bpm: 120, beats: [0.2], bars: [0.2])
    }
}
private actor CacheReadEvidence {
    private(set) var frames = 0
    func record(_ value: Int) { frames = value }
}
@MainActor private final class CacheGraphCapture { var graph: AudioEngineGraph? }
@MainActor private final class CacheFailureControl { var failOriginal = false }
@MainActor private final class CacheNativePort: AudioPlayerTransport {
    let native: AudioEnginePlayer
    let original: Bool
    let control: CacheFailureControl
    init(_ native: AudioEnginePlayer, original: Bool, control: CacheFailureControl) {
        self.native = native; self.original = original; self.control = control
    }
    var currentTime: Double { get { native.currentTime } set { native.currentTime = newValue } }
    var rate: Float { get { native.rate } set { native.rate = newValue } }
    var volume: Float { get { native.volume } set { native.volume = newValue } }
    var enableRate: Bool { get { native.enableRate } set { native.enableRate = newValue } }
    var isPlaying: Bool { native.isPlaying }
    var deviceCurrentTime: Double { native.deviceCurrentTime }
    var sharedClockID: UUID? { native.sharedClockID }
    func clockSnapshot() -> PlaybackClockSnapshot { native.clockSnapshot() }
    func prepareToPlay() -> Bool { native.prepareToPlay() }
    func play() -> Bool { !(original && control.failOriginal) && native.play() }
    func play(atTime time: Double) -> Bool { !(original && control.failOriginal) && native.play(atTime: time) }
    func pause() { native.pause() }
    func stop() { native.stop() }
}

@MainActor @Suite(.serialized)
struct CacheWorkspaceLifecycleTests {
    private func services(_ environment: AudioCacheEnvironment, control: CacheFailureControl? = nil) -> WorkspaceServices {
        var service = WorkspaceServices.cachedLive(environment: environment)
        service.lastProject = { nil }; service.rememberProject = { _ in }; service.chooseSaveDestination = { _ in nil }
        let make = service.makePlayer
        service.makePlayer = { audio, source in
            let player = try #require(make(audio, source) as? AudioEnginePlayer)
            #expect(player.source == source, "Mono aliases must keep their requested source")
            player.graph.engine.mainMixerNode.outputVolume = 0
            if let control { return CacheNativePort(player, original: audio.mapping == nil, control: control) }
            return player
        }
        return service
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func eventuallyEvicted(_ urls: [URL], store: OwnedArtifactCache) async throws {
        for _ in 0..<100 {
            try await store.setQuota(0)
            if urls.allSatisfy({ !exists($0) }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(urls.allSatisfy({ !exists($0) }), "All Workspace, graph, task and history pins must eventually release")
    }

    @Test func twoActualWorkspaceOwnersWarmReuseMonoSourcesAndIndependentShutdown() async throws {
        let fixture = try StreamingCacheFixture(seconds: 3, channels: 1); defer { fixture.clean() }
        let io = PreparationInstrumentation()
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache), instrumentation: io)
        let a = Workspace(services: services(environment)), b = Workspace(services: services(environment))
        defer { a.shutdown(); b.shutdown() }
        #expect(await a.loadAudio(at: fixture.source)?.value == true)
        let directory = try #require(a.prepared?.directory), generation = a.prepared?.generation
        io.reset()
        #expect(await b.loadAudio(at: fixture.source)?.value == true)
        #expect(b.prepared?.directory == directory && b.prepared?.generation != generation)
        #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0)
        #expect(b.prepared?.url(for: .stereo) != fixture.source)
        #expect(b.prepared?.left == b.prepared?.right && b.prepared?.left == b.prepared?.stereoURL)
        b.switchSource(.left); #expect(b.source == .left)
        b.switchSource(.right); #expect(b.source == .right)
        try await environment.preparation.store.setQuota(0)
        #expect(exists(directory))
        a.shutdown()
        try await environment.preparation.store.setQuota(0)
        #expect(exists(directory))
        // A later user-path replacement cannot retarget native playback away from leased CAFs.
        try StreamingCacheFixture.write(fixture.source, seconds: 0.1, channels: 1)
        #expect(b.prepared?.duration == 3)
        b.seek(0.2); b.togglePlayback(); try await Task.sleep(for: .milliseconds(120)); b.tick()
        #expect(b.playing && b.cursor > 0.2)
        b.shutdown()
        try await eventuallyEvicted([directory], store: environment.preparation.store)
        #expect(exists(fixture.source))
    }

    @Test func cancelledLatePreparedLeaseCannotDeleteAnotherWorkspaceGeneration() async throws {
        let fixture = try StreamingCacheFixture(seconds: 2, channels: 2); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let gate = CacheCompletionGate()
        var delayed = services(environment); let prepare = delayed.prepare
        delayed.prepare = { url, progress in
            let prepared = try await prepare(url, progress)
            await gate.pause() // Deliberately ignores cancellation after the producer finishes.
            return prepared
        }
        let cancelled = Workspace(services: delayed), owner = Workspace(services: services(environment))
        defer { cancelled.shutdown(); owner.shutdown() }
        let before = cancelled.project
        let late = try #require(cancelled.loadAudio(at: fixture.source))
        await gate.started()
        #expect(await owner.loadAudio(at: fixture.source)?.value == true)
        let directory = try #require(owner.prepared?.directory)
        cancelled.cancelLoading(); try await environment.preparation.store.setQuota(0)
        await gate.release(); #expect(await late.value == false)
        #expect(cancelled.project == before && cancelled.prepared == nil)
        #expect(exists(directory) && owner.canEdit)
        owner.switchSource(.left); owner.seek(0.1); owner.togglePlayback()
        #expect(owner.playing)
        owner.shutdown(); cancelled.shutdown()
        try await eventuallyEvicted([directory], store: environment.preparation.store)
        #expect(exists(fixture.source))
    }

    @Test func nativeUndoRedoFailureKeepsBothHistoryGenerationsUntilSuccessfulDetachAndClose() async throws {
        let fixture = try StreamingCacheFixture(seconds: 4, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let control = CacheFailureControl(), workspace = Workspace(services: services(environment, control: control))
        defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        let originalDirectory = try #require(workspace.prepared?.directory)
        #expect(await workspace.attachStem(at: fixture.source, offset: -0.25)?.value == true)
        #expect(workspace.switchAsset(.importedGuitarStem))
        let firstDirectory = try #require(workspace.prepared?.directory)
        #expect(workspace.switchAsset(.original))
        #expect(await workspace.setStemOffset(-0.5)?.value == true && workspace.canUndo)
        #expect(workspace.switchAsset(.importedGuitarStem))
        let secondDirectory = try #require(workspace.prepared?.directory)
        #expect(firstDirectory != secondDirectory)
        workspace.seek(0.5); workspace.togglePlayback(); try await Task.sleep(for: .milliseconds(120))
        try await environment.preparation.store.setQuota(0)
        control.failOriginal = true; let before = workspace.project
        workspace.undoEdit()
        #expect(workspace.project == before && workspace.canUndo && !workspace.canRedo && workspace.playing)
        #expect(exists(firstDirectory) && exists(secondDirectory))
        control.failOriginal = false; workspace.undoEdit()
        #expect(workspace.project.stemAsset?.originalTimeOffset == -0.25 && workspace.canRedo)
        #expect(workspace.switchAsset(.importedGuitarStem))
        try await Task.sleep(for: .milliseconds(120))
        control.failOriginal = true; let undone = workspace.project
        workspace.redoEdit()
        #expect(workspace.project == undone && workspace.canRedo && !workspace.canUndo)
        try await environment.preparation.store.setQuota(0)
        #expect(exists(firstDirectory) && exists(secondDirectory))
        control.failOriginal = false; workspace.redoEdit()
        #expect(workspace.project.stemAsset?.originalTimeOffset == -0.5 && workspace.canUndo)
        workspace.detachStem()
        #expect(workspace.project.stemAsset == nil && !workspace.canUndo && !workspace.canRedo)
        try await eventuallyEvicted([firstDirectory, secondDirectory], store: environment.preparation.store)
        #expect(exists(originalDirectory))
        workspace.shutdown()
        try await eventuallyEvicted([originalDirectory], store: environment.preparation.store)
    }

    @Test func borrowedResourcesSurviveActualWorkspaceClose() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        var service = services(environment)
        let borrowed = PreparedAudio(original: fixture.source, left: fixture.source, right: fixture.source,
            directory: fixture.root, duration: 1, isMono: true, leftPeaks: [], rightPeaks: [])
        service.prepare = { _, _ in borrowed }
        let workspace = Workspace(services: service)
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        workspace.switchSource(.left); workspace.shutdown()
        #expect(exists(fixture.root) && exists(fixture.source))
    }

    @Test func scratchNativeGraphPinOutlivesWorkspaceDisposalThenReleases() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let prepared = try await AudioPreparation.prepare(fixture.source)
        let directory = prepared.directory
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        var service = services(environment); let make = service.makePlayer
        let capture = CacheGraphCapture()
        service.prepare = { _, _ in prepared }
        service.makePlayer = { audio, source in
            let player = try #require(make(audio, source) as? AudioEnginePlayer)
            player.graph.engine.mainMixerNode.outputVolume = 0; capture.graph = player.graph
            return player
        }
        let workspace = Workspace(services: service)
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        workspace.shutdown()
        #expect(exists(directory), "Long-lived native files must keep scratch pins after disposal")
        capture.graph = nil
        #expect(!exists(directory) && exists(fixture.source))
    }

    @Test func actualWorkspacePitchAnalysisWarmCacheAndSelectedReadRetainAudio() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        var service = services(environment)
        let gate = CacheCompletionGate(), evidence = CacheReadEvidence()
        service.detectPitch = { url, _ in
            await gate.pause()
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
            try file.read(into: buffer)
            await evidence.record(Int(buffer.frameLength))
            return nil
        }
        let workspace = Workspace(services: service)
        defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        workspace.switchSource(.left)
        await workspace.proposePitches(from: 0, to: 0.5)?.value
        let proposals = workspace.pitchProposals, bytes = try await environment.preparation.store.diskBytes()
        #expect(!proposals.isEmpty)
        await workspace.proposePitches(from: 0, to: 0.5)?.value
        #expect(workspace.pitchProposals == proposals && workspace.error == nil)
        #expect(try await environment.preparation.store.diskBytes() == bytes)
        let directory = try #require(workspace.prepared?.directory)
        let note = TabEvent(time: 0.2, lane: .left, string: 1, fret: 0)
        workspace.project.events = [note]; workspace.select(note)
        let pending = try #require(workspace.detectSelectedPitch())
        await gate.started()
        workspace.shutdown(); try await environment.preparation.store.setQuota(0)
        #expect(exists(directory), "A cancellation-ignoring selected reader must retain its lease")
        await gate.release(); await pending.value
        #expect(await evidence.frames == 64)
        #expect(workspace.detectedPitch == nil)
        try await eventuallyEvicted([directory], store: environment.preparation.store)
    }

    @Test func cancelledSummaryProducerRetainsReaderUntilItsLateBackendFinishes() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let gate = CacheCompletionGate(), evidence = CacheReadEvidence()
        var service = services(environment)
        service.analyzerVersion = "generated-late-summary-v1"
        service.analyze = { url, _ in
            await gate.pause() // The backend deliberately ignores producer cancellation.
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
            try file.read(into: buffer); await evidence.record(Int(buffer.frameLength))
            return AnalysisSummary(beats: [0.2])
        }
        let workspace = Workspace(services: service)
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        let directory = try #require(workspace.prepared?.directory)
        let pending = try #require(workspace.analyze()); await gate.started()
        workspace.shutdown()
        try await environment.preparation.store.setQuota(0)
        #expect(exists(directory), "A running cache producer must retain the immutable audio after its consumer cancels")
        await gate.release(); await pending.value
        try await eventuallyEvicted([directory], store: environment.preparation.store)
        #expect(await evidence.frames == 64 && workspace.project.analyses.isEmpty)
        #expect(try await environment.preparation.store.diskBytes() == 0)
    }

    @Test func warmSummaryIsReattributedToEachActualWorkspaceAssetAndOffset() async throws {
        let fixture = try StreamingCacheFixture(seconds: 2, channels: 1); defer { fixture.clean() }
        let io = PreparationInstrumentation()
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache), instrumentation: io)
        let counter = CacheAnalysisCounter()
        var service = services(environment)
        service.analyze = { try await counter.summary($0, duration: $1) }
        service.analyzerVersion = "generated-workspace-cache-test-v1"
        let a = Workspace(services: service)
        // Each Workspace needs a separate native factory, but the same analysis producer/store.
        var other = services(environment); other.analyze = service.analyze; other.analyzerVersion = service.analyzerVersion
        let second = Workspace(services: other)
        defer { a.shutdown(); second.shutdown() }
        #expect(await a.loadAudio(at: fixture.source)?.value == true)
        #expect(await second.loadAudio(at: fixture.source)?.value == true)
        await a.analyze()?.value; await second.analyze()?.value
        #expect(await counter.calls == 1)
        #expect(a.summary?.provenance?.assetID == a.project.originalAsset?.id)
        #expect(second.summary?.provenance?.assetID == second.project.originalAsset?.id)
        #expect(a.project.originalAsset?.id != second.project.originalAsset?.id)
        for workspace in [a, second] {
            io.reset()
            #expect(await workspace.attachStem(at: fixture.source, offset: -0.25)?.value == true)
            if workspace === second { #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0) }
            #expect(workspace.switchAsset(.importedGuitarStem))
            await workspace.analyze()?.value
            #expect(workspace.summary?.provenance?.assetID == workspace.project.stemAsset?.id)
            #expect(workspace.summary?.provenance?.settings == "original-seconds-v1;offset=-0.25")
            #expect(workspace.summary?.provenance?.identity == workspace.project.stemAsset?.identity)
        }
        #expect(await counter.calls == 2, "Same immutable aligned data must reuse analysis without reusing project provenance")
        #expect(a.project.stemAsset?.id != second.project.stemAsset?.id)
    }
}
