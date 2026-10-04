import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore
@testable import RoughScoreCore

/// Exercise real persistent preparation and Workspace handovers without starting native hardware.
@MainActor private final class CacheDeferredClock {
    var now = 100.0
    var players: [UUID: [ListeningSource: CacheDeferredPlayer]] = [:]
    func player(_ generation: UUID, _ source: ListeningSource) -> CacheDeferredPlayer {
        if let existing = players[generation]?[source] { return existing }
        let player = CacheDeferredPlayer(clock: self)
        players[generation, default: [:]][source] = player
        return player
    }
    func advance(to time: Double, position: Double) {
        now = time
        for group in players.values { for player in group.values { player.currentTime = position } }
    }
}
@MainActor private final class CacheDeferredPlayer: AudioPlayerTransport {
    // The fixture owns the clock; transports cannot create a retain cycle with its capture table.
    unowned let clock: CacheDeferredClock
    init(clock: CacheDeferredClock) { self.clock = clock }
    var currentTime = 0.0
    var rate: Float = 1
    var volume: Float = 1
    var enableRate = true
    var isPlaying = false
    var deviceCurrentTime: Double { clock.now }
    var stops = 0
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { isPlaying = true; return true }
    func play(atTime time: Double) -> Bool { play() }
    func pause() { isPlaying = false }
    func stop() { stops += 1; isPlaying = false }
}

private actor CacheDeferredAnalysisGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.serialized)
struct CacheDeferredOwnershipTests {
    private func services(_ environment: AudioCacheEnvironment, clock: CacheDeferredClock) -> WorkspaceServices {
        var service = WorkspaceServices.cachedLive(environment: environment)
        service.lastProject = { nil }; service.rememberProject = { _ in }
        service.chooseSaveDestination = { _ in nil }
        service.prepareTransport = { _ in }; service.discardPreparedTransport = { _ in }
        service.makePlayer = { clock.player($0.generation, $1) }
        return service
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func evict(_ directory: URL, environment: AudioCacheEnvironment) async throws {
        for _ in 0..<100 {
            try await environment.preparation.store.setQuota(0)
            if !exists(directory) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!exists(directory), "Retired outgoing lease must release after handover and close")
    }

    @Test func persistentShutdownRetainsLocalAudioUntilLastReaderReleased() async throws {
        let fixture = try StreamingCacheFixture(seconds: 1, channels: 1); defer { fixture.clean() }
        let bytes = try Data(contentsOf: fixture.source)
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let clock = CacheDeferredClock(), workspace = Workspace(services: services(environment, clock: clock))
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        var localPreparedAudio = workspace.prepared
        let directory = try #require(localPreparedAudio).directory
        let generation = try #require(localPreparedAudio).generation
        var reader: PreparedAudioFileAccess? = try #require(localPreparedAudio).fileAccess(for: .stereo)
        workspace.togglePlayback()
        #expect(clock.players[generation]?[.stereo]?.isPlaying == true)
        workspace.shutdown()
        #expect(clock.players[generation]?[.stereo]?.isPlaying == false)
        try await environment.preparation.store.setQuota(0)
        #expect(exists(directory), "Stopped playback does not release local PreparedAudio or independent readers")
        localPreparedAudio = nil
        try await environment.preparation.store.trim()
        #expect(exists(directory), "A reader alone must prevent quota eviction")
        try #require(reader).validate()
        reader = nil
        try await evict(directory, environment: environment)
        #expect(try Data(contentsOf: fixture.source) == bytes)
    }

    @Test func twoWorkspacesAndOffsetHistoryReleaseEachOwnerBeforeQuotaEviction() async throws {
        let fixture = try StreamingCacheFixture(seconds: 4, channels: 1); defer { fixture.clean() }
        let bytes = try Data(contentsOf: fixture.source), io = PreparationInstrumentation()
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache), instrumentation: io)
        let clock = CacheDeferredClock()
        let first = Workspace(services: services(environment, clock: clock)), second = Workspace(services: services(environment, clock: clock))
        defer { first.shutdown(); second.shutdown() }
        #expect(await first.loadAudio(at: fixture.source)?.value == true)
        let originalDirectory = try #require(first.prepared?.directory)
        io.reset()
        #expect(await second.loadAudio(at: fixture.source)?.value == true)
        #expect(second.prepared?.directory == originalDirectory && first.prepared?.generation != second.prepared?.generation)
        #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0)
        #expect(await first.attachStem(at: fixture.source, offset: -0.25)?.value == true)
        #expect(first.switchAsset(.importedGuitarStem))
        let oldStemDirectory = try #require(first.prepared?.directory)
        #expect(await first.setStemOffset(-0.5)?.value == true && first.canUndo)
        try await environment.preparation.store.setQuota(0)
        #expect(exists(oldStemDirectory), "The old offset generation must survive through undo history")
        first.undoEdit()
        #expect(first.project.stemAsset?.originalTimeOffset == -0.25 && first.canRedo)
        first.redoEdit()
        #expect(first.project.stemAsset?.originalTimeOffset == -0.5 && first.canUndo)
        first.shutdown() // Releases both history directions and all current/outgoing references.
        try await evict(oldStemDirectory, environment: environment)
        #expect(exists(originalDirectory), "Closing one Workspace cannot evict the second owner's generation")
        second.shutdown()
        try await evict(originalDirectory, environment: environment)
        #expect(try Data(contentsOf: fixture.source) == bytes)
    }

    @Test func lateSummaryCannotPublishIntoAnotherGenerationAtTheSameCachedURI() async throws {
        let fixture = try StreamingCacheFixture(seconds: 2, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let clock = CacheDeferredClock(), gate = CacheDeferredAnalysisGate()
        var service = services(environment, clock: clock)
        service.analyzerVersion = "generated-stale-generation-v1"
        service.analyze = { _, _ in
            await gate.pause() // The backend ignores replacement and consumer cancellation.
            return AnalysisSummary(beats: [0.2], bars: [0.2])
        }
        let workspace = Workspace(services: service); defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        let directory = try #require(workspace.prepared?.directory)
        let generation = try #require(workspace.prepared?.generation)
        let pending = try #require(workspace.analyze()); await gate.started()
        // Simulate a reused warm URI being installed while the old backend remains in flight.
        let replacement = try await service.prepare(fixture.source) { _ in }
        #expect(replacement.directory == directory && replacement.generation != generation)
        workspace.prepared = replacement
        await gate.release(); await pending.value
        #expect(workspace.project.analyses.isEmpty && workspace.summary == nil)
        #expect(workspace.prepared?.generation == replacement.generation)
    }

    @Test func warmCanonicalSummaryRechecksSourceAndAttributesOnlyCurrentProject() async throws {
        let fixture = try StreamingCacheFixture(seconds: 2, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let counter = DeferredSummaryCounter(), clock = CacheDeferredClock()
        var service = services(environment, clock: clock)
        service.analyzerVersion = "canonical-current-context-v1"
        service.analyze = { url, _ in
            #expect(!url.path.hasPrefix("/dev/fd/") && url != fixture.source)
            await counter.record()
            return AnalysisSummary(beats: [0.2])
        }
        let first = Workspace(services: service), second = Workspace(services: service)
        defer { first.shutdown(); second.shutdown() }
        #expect(await first.loadAudio(at: fixture.source)?.value == true)
        #expect(await second.loadAudio(at: fixture.source)?.value == true)
        await first.analyze()?.value; await second.analyze()?.value
        #expect(await counter.calls == 1)
        let firstAsset = try #require(first.project.originalAsset)
        let secondAsset = try #require(second.project.originalAsset)
        #expect(firstAsset.id != secondAsset.id)
        #expect(first.summary?.provenance?.assetID == firstAsset.id)
        #expect(second.summary?.provenance?.assetID == secondAsset.id)
        #expect(second.summary?.provenance?.identity == secondAsset.identity)
        second.project.analyses.removeAll()
        try StreamingCacheFixture.write(fixture.source, seconds: 0.5, channels: 1)
        await second.analyze()?.value // Hits the completed cache before original-source revalidation.
        #expect(await counter.calls == 1)
        #expect(second.project.analyses.isEmpty && second.summary == nil && second.error != nil)
        #expect(first.summary?.provenance?.assetID == firstAsset.id)
    }

    @Test func detachedOutgoingStemLeaseSurvivesEvictionUntilHandoverFinishes() async throws {
        let fixture = try StreamingCacheFixture(seconds: 4, channels: 1); defer { fixture.clean() }
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache))
        let clock = CacheDeferredClock(), workspace = Workspace(services: services(environment, clock: clock))
        defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        let original = try #require(workspace.prepared?.directory)
        #expect(await workspace.attachStem(at: fixture.source, offset: -0.25)?.value == true)
        #expect(workspace.switchAsset(.importedGuitarStem))
        let directory = try #require(workspace.prepared?.directory)
        let generation = try #require(workspace.prepared?.generation)
        workspace.seek(1); workspace.togglePlayback(); clock.advance(to: 101, position: 1.5)
        workspace.detachStem()
        #expect(workspace.project.stemAsset == nil && workspace.assetRole == .original)
        let outgoing = try #require(clock.players[generation]?[.stereo])
        #expect(outgoing.isPlaying && outgoing.volume == 1 && outgoing.stops == 0)
        try await environment.preparation.store.setQuota(0)
        #expect(exists(directory), "Detachment must retain the actual outgoing cache lease until its future epoch")
        clock.now = 102
        workspace.tick()
        #expect(!outgoing.isPlaying && outgoing.volume == 0)
        try await evict(directory, environment: environment)
        #expect(exists(original) && exists(fixture.source))
        workspace.shutdown()
        try await evict(original, environment: environment)
    }

    @Test func replacementAtSameCachedURIRejectsOldGenerationAndRateKeepsNewGroup() async throws {
        let fixture = try StreamingCacheFixture(seconds: 4, channels: 1); defer { fixture.clean() }
        let io = PreparationInstrumentation()
        let environment = try AudioCacheEnvironment(configuration: .init(root: fixture.cache), instrumentation: io)
        let clock = CacheDeferredClock(), workspace = Workspace(services: services(environment, clock: clock))
        defer { workspace.shutdown() }
        #expect(await workspace.loadAudio(at: fixture.source)?.value == true)
        #expect(await workspace.attachStem(at: fixture.source, offset: -0.25)?.value == true)
        #expect(workspace.switchAsset(.importedGuitarStem))
        let directory = try #require(workspace.prepared?.directory)
        let oldGeneration = try #require(workspace.prepared?.generation)
        workspace.seek(1); workspace.togglePlayback(); clock.advance(to: 101, position: 1.5)
        io.reset()
        #expect(await workspace.attachStem(at: fixture.source, offset: -0.25)?.value == true)
        #expect(io.snapshot.decodeCalls == 0 && io.snapshot.cafWrites == 0)
        #expect(!workspace.switchAsset(.importedGuitarStem), "Same URI cannot authorize reversal to a retired generation")
        #expect(workspace.assetRole == .original)
        let outgoing = try #require(clock.players[oldGeneration]?[.stereo])
        #expect(outgoing.isPlaying && outgoing.volume == 1 && outgoing.stops == 0)
        workspace.rate = 0.5
        #expect(outgoing.isPlaying && outgoing.rate == 0.5)
        clock.now = 102; workspace.tick()
        #expect(workspace.switchAsset(.importedGuitarStem))
        let replacementGeneration = try #require(workspace.prepared?.generation)
        #expect(workspace.prepared?.directory == directory && replacementGeneration != oldGeneration)
        let replacement = try #require(clock.players[replacementGeneration]?[.stereo])
        #expect(replacement !== outgoing && replacement.isPlaying && replacement.rate == 0.5)
        #expect(replacement.volume == 1 && !outgoing.isPlaying && outgoing.volume == 0)
        workspace.switchSource(.right)
        #expect(clock.players[replacementGeneration]?[.right]?.volume == 1 && replacement.volume == 0)
        workspace.shutdown()
        try await evict(directory, environment: environment)
        #expect(exists(fixture.source))
    }
}

private actor DeferredSummaryCounter {
    var calls = 0
    func record() { calls += 1 }
}
