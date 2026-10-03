import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
private final class TestPlayer: AudioPlayerTransport {
    private var storedTime = 0.0
    var timeRead: (() -> Double)?
    var seekCount = 0
    var currentTime: Double {
        get { timeRead?() ?? storedTime }
        set { seekCount += 1; storedTime = newValue }
    }
    var rate: Float = 1
    var volume: Float = 1
    var enableRate = false
    var isPlaying = false
    var deviceCurrentTime = 100.0
    var scheduledEpochs: [Double] = []
    var advancesDeviceOnSchedule = true
    func play(atTime time: TimeInterval) -> Bool {
        scheduledEpochs.append(time)
        if advancesDeviceOnSchedule { deviceCurrentTime = time }
        return play()
    }
    var prepares = 0
    var playTimes: [Double] = []
    var preparationSucceeds = true
    var playbackSucceeds = true
    func prepareToPlay() -> Bool { prepares += 1; return preparationSucceeds }
    func play() -> Bool {
        playTimes.append(currentTime)
        isPlaying = playbackSucceeds
        return playbackSucceeds
    }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class TransportFixture {
    let root: URL
    let audio: PreparedAudio
    let stereo = TestPlayer(), left = TestPlayer(), right = TestPlayer()
    var constructions: [URL] = []
    var failURL: URL?
    var duringConstruction: (() -> Void)?
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audio = PreparedAudio(original: root.appendingPathComponent("stereo.caf"),
            left: root.appendingPathComponent("left.caf"), right: root.appendingPathComponent("right.caf"),
            directory: root.appendingPathComponent("prepared"), duration: 20, isMono: false,
            leftPeaks: [], rightPeaks: [])
    }
    func services() -> WorkspaceServices {
        let audio = audio
        var services = WorkspaceServices.live
        services.prepare = { _, _ in audio }
        services.makePlayer = { [self] url in
            constructions.append(url)
            duringConstruction?()
            if url == failURL { throw AudioIssue.unsupported }
            return url == audio.original ? stereo : url == audio.left ? left : right
        }
        services.lastProject = { nil }; services.rememberProject = { _ in }
        services.chooseSaveDestination = { [root] _ in root.appendingPathComponent("saved.roughscore") }
        return services
    }
    func loaded() async throws -> Workspace {
        let workspace = Workspace(services: services())
        let load = try #require(workspace.loadAudio(at: audio.original))
        #expect(await load.value)
        return workspace
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct WorkspaceTransportTests {
    @Test(arguments: [Float(0.5), 0.75, 1])
    func switchCapturesLiveTimeAfterPreparationAndReusesPlayers(rate: Float) async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.rate = rate; w.seek(2); w.togglePlayback()
        f.stereo.currentTime = 2.327 // deliberately ahead of the 30ms published cursor
        w.switchSource(.left)
        #expect(f.left.currentTime == 2.327)
        #expect(w.cursor == 2.327 && w.rate == rate && f.left.rate == rate)
        #expect(w.playing && f.left.isPlaying && f.stereo.volume == 0)
        f.duringConstruction = nil
        f.left.currentTime = 3.213; w.switchSource(.right)
        #expect(f.right.currentTime == 3.213 && w.playing)
        f.right.currentTime = 4.083; w.switchSource(.stereo)
        #expect(f.stereo.currentTime == 4.083 && w.playing)
        f.stereo.currentTime = 4.217; w.switchSource(.left)
        #expect(f.left.currentTime == 4.217 && w.playing)
        #expect(f.constructions.count == 3 && f.left.prepares == 2 && f.stereo.prepares == 2)
    }

    @Test func pendingScheduledSeekSourceAndPauseKeepAnchorInsteadOfNativePreroll() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        for player in [f.stereo, f.left, f.right] { player.advancesDeviceOnSchedule = false }
        w.seek(2); w.togglePlayback()
        for player in [f.stereo, f.left, f.right] { player.currentTime = 1.86 }
        let seeks = f.left.seekCount
        w.tick(); #expect(w.cursor == 2 && w.playing)
        w.switchSource(.left)
        #expect(w.cursor == 2 && w.playing && f.left.seekCount == seeks)
        w.togglePlayback()
        #expect(!w.playing && w.cursor == 2 && [f.stereo, f.left, f.right].allSatisfy { $0.currentTime == 2 && !$0.isPlaying })
        w.togglePlayback()
        for player in [f.stereo, f.left, f.right] { player.deviceCurrentTime = 100.25; player.currentTime = 2.213 }
        w.switchSource(.right)
        #expect(w.cursor == 2.213 && w.playing)
    }

    @Test func healthyAlignedGroupChangesOnlyGainsWithoutSeekOrResume() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.seek(2); w.togglePlayback()
        for player in [f.stereo, f.left, f.right] { player.currentTime = 2.327 }
        let seeks = [f.stereo, f.left, f.right].map(\.seekCount)
        let plays = [f.stereo, f.left, f.right].map { $0.playTimes.count }
        for source in [ListeningSource.left, .right, .stereo, .left] { w.switchSource(source) }
        #expect(w.cursor == 2.327 && w.playing && w.source == .left)
        #expect([f.stereo, f.left, f.right].map(\.seekCount) == seeks)
        #expect([f.stereo, f.left, f.right].map { $0.playTimes.count } == plays)
        #expect(f.left.volume == 1 && f.stereo.volume == 0 && f.right.volume == 0)
        #expect(f.constructions.count == 3)
    }

    @Test func laterDestinationClockReadDoesNotMistakeHardwareProgressForDrift() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.rate = 0.5; w.seek(2); w.togglePlayback()
        f.stereo.currentTime = 2.327
        let seeks = f.left.seekCount
        // Destination getter arrives200ms later on the same device clock at0.5x.
        f.left.timeRead = { f.left.deviceCurrentTime = f.stereo.deviceCurrentTime + 0.2; return 2.427 }
        w.switchSource(.left)
        #expect(w.cursor == 2.327 && w.playing && w.source == .left)
        #expect(f.left.seekCount == seeks && f.left.currentTime == 2.427)
    }

    @Test func preparationSamplesPausedLiveClockAndGroupControlsShareEpochRateSeekAndPause() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.seek(2); f.stereo.currentTime = 2.19
        f.duringConstruction = { f.stereo.currentTime += 0.137 }
        w.switchSource(.left)
        #expect(w.cursor == 2.327 && f.left.currentTime == 2.327 && !w.playing)
        f.duringConstruction = nil
        w.togglePlayback()
        #expect(f.stereo.scheduledEpochs.last == 100.25 && f.left.scheduledEpochs.last == 100.25)
        #expect(f.right.scheduledEpochs.last == 100.25 && w.playing)
        #expect(f.stereo.volume == 0 && f.left.volume == 1 && f.right.volume == 0)
        f.left.currentTime = 3.213; w.rate = 0.75
        #expect(w.cursor == 3.213 && w.playing && [f.stereo, f.left, f.right].allSatisfy { $0.rate == 0.75 && $0.currentTime == 3.213 })
        w.seek(4.083)
        #expect([f.stereo, f.left, f.right].allSatisfy { $0.currentTime == 4.083 && $0.isPlaying })
        f.left.currentTime = 4.217; w.togglePlayback()
        #expect(w.cursor == 4.217 && !w.playing && [f.stereo, f.left, f.right].allSatisfy { !$0.isPlaying })
    }

    @Test(arguments: ["construction", "preparation", "resume"])
    func failedDestinationRetainsLiveOldPlayerAndDocument(failure: String) async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.addEvent(time: 1.213, string: 6); w.updateSelected { $0.memo = "exact unknown" }
        w.addEvent(time: 3.083, string: 1); w.inputDigit(1, at: 100); w.inputDigit(2, at: 100.1)
        w.updateSelected { $0.lane = .right; $0.length = .eighth; $0.tentative = true }
        w.save()
        w.updateSelected { $0.memo = "unsaved" }
        w.rate = 0.75; w.seek(2)
        let project = w.project, state = w.saveState, selection = w.selectedID
        if failure == "construction" { f.failURL = f.audio.left }
        if failure == "preparation" { f.left.preparationSucceeds = false }
        if failure == "resume" { f.left.playbackSucceeds = false }
        w.togglePlayback(); f.stereo.currentTime = 2.19
        w.switchSource(.left)
        #expect(w.source == .stereo && w.playing && f.stereo.isPlaying && !f.left.isPlaying)
        #expect(w.error != nil && f.stereo.currentTime == 2.19)
        #expect(w.project == project && w.selectedID == selection && w.saveState == state && w.dirty)
        #expect(w.hasSaveLocation && w.canUndo && w.rate == 0.75)
        // Old transport is still controllable after failure, and pause captures its live position.
        w.togglePlayback()
        #expect(!w.playing && w.cursor == 2.19)
        w.togglePlayback(); #expect(w.playing && f.stereo.playTimes.last == 2.19)
    }

    @Test func pausedBoundsLoopAndActualPlaybackTruth() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.seek(19.999); f.stereo.currentTime = 25; w.switchSource(.left)
        #expect(w.cursor == 20.nextDown && f.left.currentTime == 20.nextDown && !w.playing)
        w.setLoop(from: 2.213, to: 5.083); w.rate = 0.5; w.togglePlayback()
        f.left.currentTime = 5.2; w.switchSource(.right)
        #expect(w.cursor == 2.213 && f.right.currentTime == 2.213)
        #expect(w.looping && w.loopStart == 2.213 && w.loopEnd == 5.083 && w.playing && w.rate == 0.5)
        w.togglePlayback(); f.right.currentTime = 3.083; w.switchSource(.stereo)
        #expect(!w.playing && w.cursor == 3.083 && w.looping)
        f.stereo.playbackSucceeds = false; w.togglePlayback()
        #expect(!w.playing && !f.stereo.isPlaying && w.error != nil)
        f.stereo.playbackSucceeds = true; w.togglePlayback()
        w.looping = false; f.stereo.isPlaying = false; f.stereo.currentTime = 20
        w.switchSource(.left)
        #expect(!w.playing && !f.left.isPlaying && w.cursor == 20.nextDown)
    }

    @Test func cancelledAsyncLoadCannotLoseTheActiveSourceOrItsLiveClock() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let pending = PendingTransportPreparation()
        let replacementURL = f.root.appendingPathComponent("replacement.caf")
        let oldAudio = f.audio
        var services = f.services()
        services.prepare = { url, _ in
            if url == replacementURL { return try await pending.value() }
            return oldAudio
        }
        let w = Workspace(services: services); defer { w.shutdown() }
        let initial = try #require(w.loadAudio(at: f.audio.original)); #expect(await initial.value)
        w.seek(2); w.togglePlayback(); f.stereo.currentTime = 2.19
        let project = w.project, state = w.saveState
        let replacement = try #require(w.loadAudio(at: replacementURL, relink: true))
        await pending.started()
        w.switchSource(.left)
        #expect(w.busy && w.source == .stereo && w.playing && f.stereo.isPlaying)
        w.cancelLoading(); f.stereo.currentTime = 3.213
        let directory = f.root.appendingPathComponent("late-prepared")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await pending.finish(PreparedAudio(original: replacementURL, left: replacementURL, right: replacementURL,
            directory: directory, duration: 20, isMono: false, leftPeaks: [], rightPeaks: []))
        #expect(!(await replacement.value))
        #expect(w.project == project && w.saveState == state && w.prepared?.directory == oldAudio.directory)
        #expect(w.playing && f.stereo.isPlaying && w.canEdit && w.source == .stereo)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        w.switchSource(.left)
        #expect(f.left.currentTime == 3.213 && w.cursor == 3.213 && w.playing)
    }

    @Test func switchesDoNotMutateSparseTabOrSaveHistory() async throws {
        let f = try TransportFixture(); defer { f.clean() }
        let w = try await f.loaded(); defer { w.shutdown() }
        w.project.events = [TabEvent(time: 1.213, lane: .left, string: 6, memo: "unknown"),
            TabEvent(time: 3.083, lane: .right, string: 1, fret: 12, length: .eighth, tentative: true)]
        w.save(); w.select(w.project.events[0]); w.updateSelected { $0.memo = "unsaved memo" }
        w.updateSelected { $0.tentative = true }; w.undoEdit()
        let project = w.project, state = w.saveState
        let bytes = try Data(contentsOf: f.root.appendingPathComponent("saved.roughscore"))
        for source in [ListeningSource.left, .right, .stereo, .left] { w.switchSource(source) }
        #expect(w.project == project && w.saveState == state && w.dirty && w.hasSaveLocation)
        #expect(w.canUndo && w.canRedo)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("saved.roughscore")) == bytes)
        w.redoEdit(); #expect(w.project.events[0].tentative)
        w.undoEdit(); #expect(w.project == project)
    }
}

private actor PendingTransportPreparation {
    private var continuation: CheckedContinuation<PreparedAudio, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func value() async throws -> PreparedAudio {
        try await withCheckedThrowingContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ audio: PreparedAudio) { continuation?.resume(returning: audio); continuation = nil }
}
