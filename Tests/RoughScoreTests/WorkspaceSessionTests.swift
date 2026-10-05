import AVFoundation
import Foundation
import RoughScoreCore
import Testing
import SwiftUI
@testable import RoughScore

@MainActor
private final class SessionCapture {
    var documentWrites = 0
    var sessionWrites = 0
    var failSession = false
    var failRightChannel = false
    var players: [UUID: [ListeningSource: AudioEnginePlayer]] = [:]
}

@MainActor
private struct SessionFixture {
    let root: URL
    let capture = SessionCapture()
    var store: WorkspaceSessionStore { .files(at: root.appendingPathComponent("sessions")) }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoughScore-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func clean() { capture.players.removeAll(); try? FileManager.default.removeItem(at: root) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func write(_ project: ScoreProject, name: String) throws -> URL {
        let destination = url(name)
        try JSONEncoder().encode(project).write(to: destination)
        return destination
    }
    func services(native: Bool = false) throws -> WorkspaceServices {
        let environment = try AudioCacheEnvironment(configuration: .init(root: url("cache")))
        var services = WorkspaceServices.cachedLive(environment: environment)
        services.initialProject = { nil }; services.lastProject = { nil }; services.rememberProject = { _ in }
        services.chooseSaveDestination = { _ in nil }; services.nativeTextUndo = { nil }
        services.sessionStore = store
        let write = store.write, capture = capture
        services.sessionStore.write = { value, url, project in
            capture.sessionWrites += 1
            if capture.failSession { throw CocoaError(.fileWriteNoPermission) }
            try write(value, url, project)
        }
        services.writeProject = { bytes, url in
            capture.documentWrites += 1
            try bytes.write(to: url, options: .atomic)
        }
        if native {
            let make = services.makePlayer
            services.makePlayer = { audio, channel in
                if capture.failRightChannel && channel == .right { throw AudioIssue.playbackFailed }
                let player = try #require(make(audio, channel) as? AudioEnginePlayer)
                player.graph.engine.mainMixerNode.outputVolume = 0
                capture.players[audio.generation, default: [:]][channel] = player
                return player
            }
        }
        return services
    }
    func notes() -> [TabEvent] {
        [TabEvent(time: 1.213456789012, lane: .left, string: 6, memo: "미확인\n?"),
         TabEvent(time: 2.083456789012, lane: .right, string: 2, fret: 12, length: nil, tentative: true)]
    }
    func configure(_ workspace: Workspace) {
        workspace.seek(100); workspace.switchSource(.right); workspace.lane = .right
        workspace.windowLength = 2; workspace.windowStart = 99
        workspace.scoreView = false; workspace.measuresPerSystem = 2
        workspace.showBothLanes = true; workspace.followScore = false; workspace.scorePage = 3
        workspace.showScoreWaveforms = false; workspace.showLengths = true; workspace.snapToBeat = true
        workspace.rate = 0.75; workspace.loopStart = 99; workspace.loopEnd = 105; workspace.looping = true
    }
    func expectView(_ workspace: Workspace, asset: AudioAsset.Role = .original) {
        #expect(abs(workspace.cursor - 100) < 0.0001)
        #expect(workspace.lane == .right && workspace.source == .right && workspace.assetRole == asset)
        #expect(workspace.windowLength == 2 && workspace.windowStart == 99 && !workspace.scoreView)
        #expect(workspace.measuresPerSystem == 2 && workspace.showBothLanes && workspace.scorePage == 3)
        #expect(!workspace.followScore && !workspace.showScoreWaveforms && workspace.showLengths && workspace.snapToBeat)
        #expect(workspace.rate == 0.75 && workspace.loopStart == 99 && workspace.loopEnd == 105 && workspace.looping)
        #expect(!workspace.playing && workspace.selectedID == nil && workspace.selectedIDs.isEmpty)
        #expect(workspace.positionDrag == nil && !workspace.inspectorVisible && workspace.activeString == 6)
    }
}

@MainActor @Suite(.serialized)
struct WorkspaceSessionTests {
    @Test(arguments: [AudioAsset.Role.original, .importedGuitarStem])
    func nativeLongSongQuitReopenRestoresActualTransportAndExactTab(role: AudioAsset.Role) async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let original = f.url("generated-original.caf"), stem = f.url("generated-stem.caf")
        try StreamingCacheFixture.write(original, seconds: 120, channels: 2)
        try StreamingCacheFixture.write(stem, seconds: 120.25, channels: 2)
        let services = try f.services(native: true)
        let w = Workspace(services: services)
        #expect(await w.loadAudio(at: original)?.value == true)
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        w.project.events = f.notes()
        #expect(w.setTuning(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2))
        let asset = try #require(w.project.stemAsset), identity = try #require(asset.identity)
        let summary = AnalysisSummary(bpm: 120, bars: [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110],
            provenance: AnalysisProvenance(assetID: asset.id, identity: identity, channel: "right", analyzerVersion: "session-test"))
        w.project.analyses[w.project.analysisKey(asset: asset, channel: .right)] = summary
        let projectURL = f.url(role == .original ? "long.roughscore" : "long.roughscorepkg")
        #expect(w.saveAs(to: projectURL, format: role == .original ? .linked : .collected))
        f.configure(w); #expect(w.switchAsset(role))
        // Page three is valid for Original; stem's distinct bars have three pages, so choose its last page.
        w.scorePage = role == .original ? 3 : 2
        let expectedLayout = w.scoreLayout, exactProject = w.project
        let documentFile = role == .original ? projectURL : projectURL.appendingPathComponent("project.json")
        let bytes = try Data(contentsOf: documentFile), writes = f.capture.documentWrites
        w.beginPositionDrag(w.project.events[1]); w.previewPositionDrag(time: 8, string: 1)
        w.inspectorVisible = true; w.activeString = 2
        await w.awaitSessionPersistence()
        #expect(w.project == exactProject && !w.dirty && f.capture.documentWrites == writes)
        #expect(try Data(contentsOf: documentFile) == bytes)
        w.shutdown()
        if role == .importedGuitarStem {
            try FileManager.default.removeItem(at: original); try FileManager.default.removeItem(at: stem)
            try PortableProjectPackage.read(at: projectURL).validate()
        }
        let reopened = Workspace(services: services); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: projectURL)?.value == true)
        #expect(reopened.project == exactProject) // UUIDs, nil rhythm, tuning and provenance are exact.
        #expect(reopened.project.events.map(\.time) == exactProject.events.map(\.time))
        #expect(reopened.project.events.allSatisfy { $0.length == nil })
        #expect(!reopened.dirty && !reopened.canUndo && !reopened.canRedo)
        #expect(reopened.scoreLayout == expectedLayout)
        #expect(reopened.summary == (role == .importedGuitarStem ? summary : nil))
        if role == .original { f.expectView(reopened) }
        else {
            #expect(reopened.assetRole == role && reopened.cursor == 100 && reopened.source == .right && reopened.lane == .right)
            #expect(reopened.scorePage == 2 && reopened.windowLength == 2 && reopened.looping && !reopened.playing)
            #expect(reopened.positionDrag == nil && reopened.selectedID == nil && reopened.activeString == 6)
        }
        let generation = try #require(reopened.prepared?.generation)
        let player = try #require(f.capture.players[generation]?[.right])
        #expect(player.source == .right && abs(player.currentTime - 100) < 0.0001 && player.rate == 0.75 && !player.isPlaying)
        reopened.togglePlayback(); try await Task.sleep(for: .milliseconds(100)); reopened.tick()
        #expect(reopened.playing && reopened.cursor > 100 && reopened.cursor < 101)
        reopened.togglePlayback()
        #expect(!reopened.dirty && !reopened.canUndo && f.capture.documentWrites == writes)
        #expect(try Data(contentsOf: documentFile) == bytes)
    }

    @Test func independentABDirectBindingsCleanBaselineAndNormalNoteAutosaveUndo() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let a = try f.write(ScoreProject(title: "A", duration: 120, events: f.notes()), name: "A.roughscore")
        let b = try f.write(ScoreProject(title: "B", duration: 120, events: f.notes()), name: "B.roughscore")
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: a)?.value == true)
        let exact = w.project, bytes = try Data(contentsOf: a)
        f.configure(w)
        // No explicit save/flush: native property bindings use the live throttled writer.
        await w.awaitSessionPersistence()
        #expect(f.capture.sessionWrites == 1 && f.capture.documentWrites == 0)
        #expect(!w.dirty && !w.canUndo && !w.canRedo && w.project == exact)
        #expect(try Data(contentsOf: a) == bytes)
        w.addEvent(time: 11, string: 3); w.inputDigit(7, at: 100)
        #expect(w.dirty && w.canUndo)
        await w.awaitAutosave()
        #expect(!w.dirty && f.capture.documentWrites == 1)
        w.undoEdit(); #expect(w.project.events == exact.events && w.dirty)
        await w.awaitAutosave(); #expect(!w.dirty && f.capture.documentWrites == 2)
        f.configure(w)
        #expect(await w.loadProject(at: b)?.value == true)
        #expect(w.cursor == 0 && w.lane == .left && w.source == .stereo && w.windowLength == 12 && w.rate == 1)
        w.seek(30); w.windowLength = 6; w.showLengths = false
        #expect(await w.loadProject(at: a)?.value == true)
        f.expectView(w)
        #expect(await w.loadProject(at: b)?.value == true)
        #expect(w.cursor == 30 && w.windowLength == 6 && !w.showLengths && w.lane == .left)
    }

    @Test func saveAsAndCopySeedSeparateSessionsWithoutRetargetingCopyOrPackagePollution() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let linked = try f.write(ScoreProject(title: "portable", duration: 120, events: f.notes()), name: "source.roughscore")
        let services = try f.services(), w = Workspace(services: services); defer { w.shutdown() }
        #expect(await w.loadProject(at: linked)?.value == true)
        w.addEvent(time: 15, string: 4); f.configure(w)
        let copy = f.url("copy.roughscorepkg"), destination = f.url("active.roughscorepkg")
        #expect(w.saveCopy(to: copy, format: .collected))
        #expect(w.activeProjectURL == linked && w.dirty && w.canUndo)
        #expect(try PortableProjectPackage.read(at: copy).project == w.project)
        await w.awaitAutosave()
        #expect(try !w.dirty && JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: linked)) == w.project)
        #expect(w.saveAs(to: destination, format: .collected))
        #expect(w.activeProjectURL == destination && !w.dirty && w.canUndo)
        w.seek(50); w.flushSession()
        w.addEvent(time: 20, string: 2); w.seek(50); await w.awaitAutosave()
        #expect(try PortableProjectPackage.read(at: destination).project == w.project)
        let openedCopy = Workspace(services: services); defer { openedCopy.shutdown() }
        #expect(await openedCopy.loadProject(at: copy)?.value == true)
        f.expectView(openedCopy)
        let openedActive = Workspace(services: services); defer { openedActive.shutdown() }
        #expect(await openedActive.loadProject(at: destination)?.value == true)
        #expect(openedActive.cursor == 50 && openedActive.windowLength == 2)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)) == ["project.json"])
        // Moving a package preserves TAB/media portability; view state is local to the new path.
        let moved = f.url("moved.roughscorepkg")
        try FileManager.default.moveItem(at: copy, to: moved)
        #expect(await openedCopy.loadProject(at: moved)?.value == true)
        #expect(openedCopy.cursor == 0 && openedCopy.source == .stereo && openedCopy.project.events.count == 3)
    }

    @Test func failedSessionWriteNeverRollsBackDurablePublicationOrConsumesNoteHistory() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let source = try f.write(ScoreProject(title: "failure", duration: 120), name: "source.roughscore")
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: source)?.value == true)
        f.capture.failSession = true
        w.seek(100); w.flushSession()
        #expect(w.sessionPersistenceError != nil && !w.dirty && !w.canUndo && f.capture.documentWrites == 0)
        w.addEvent(time: 2.213456789, string: 6)
        let copy = f.url("copy.roughscore"), destination = f.url("published.roughscorepkg")
        #expect(w.saveCopy(to: copy) && w.dirty && w.activeProjectURL == source && w.canUndo)
        #expect(w.saveAs(to: destination, format: .collected))
        #expect(w.activeProjectURL == destination && !w.dirty && w.saveState == .saved && w.canUndo)
        #expect(try PortableProjectPackage.read(at: destination).project == w.project)
        #expect(w.sessionPersistenceError != nil)
        w.undoEdit(); #expect(w.dirty && w.project.events.isEmpty)
        await w.awaitAutosave(); #expect(!w.dirty && w.sessionPersistenceError != nil)
        f.capture.failSession = false; w.flushSession()
        #expect(w.sessionPersistenceError == nil && !w.dirty && w.canRedo)
    }

    @Test func missingStemInvalidFieldsAndActualShorterRelinkUseCurrentBounds() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let original = f.url("generated-short.caf")
        try StreamingCacheFixture.write(original, seconds: 5, channels: 1)
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1, sampleRate: 44100, frameCount: 5292000)
        let asset = AudioAsset(reference: AudioReference(path: original.path), identity: identity)
        let stem = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: f.url("missing.caf").path), identity: identity)
        var project = ScoreProject(title: "short", audioPath: original.path, duration: 120, events: f.notes())
        project.assets = [asset, stem]
        let url = try f.write(project, name: "short.roughscore")
        var session = WorkspaceSession()
        session.cursor = 100; session.asset = "importedGuitarStem"; session.lane = "right"; session.channel = "invalid"
        session.windowStart = 99; session.windowLength = -2; session.rate = 9
        session.measuresPerSystem = Int.max; session.followScore = false; session.scorePage = Int.max
        session.loopStart = 100; session.loopEnd = 104; session.looping = true
        try f.store.write(session, url, project)
        let w = Workspace(services: try f.services(native: true)); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.project.duration == 5 && w.cursor == 5.nextDown && w.windowLength == 5 && w.windowStart == 0)
        #expect(w.assetRole == .original && w.source == .stereo && w.lane == .right && w.rate == 1)
        #expect(w.measuresPerSystem == 8 && w.scorePage == w.scoreLayout.pageCount - 1)
        #expect(w.loopStart == 0 && w.loopEnd == 4 && !w.looping && !w.playing)
        #expect(w.project.events == project.events)
        // Relink an already active project too: keep the view, clamp to the freshly decoded duration.
        let shorter = f.url("generated-shorter.caf")
        try StreamingCacheFixture.write(shorter, seconds: 3, channels: 1)
        w.windowLength = 2; w.windowStart = 3; w.loopStart = 4; w.loopEnd = 5; w.looping = true
        #expect(await w.loadAudio(at: shorter, relink: true)?.value == true)
        #expect(w.cursor == 3.nextDown && w.windowLength == 2 && w.windowStart == 1 && !w.looping)
        #expect(w.project.events == project.events && w.positionDrag == nil && !w.playing)
    }

    @Test func sessionlessV1DefaultsDoNotInheritTransientEntrySelectionOrDisplayState() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let project = ScoreProject(title: "v1", duration: 120, events: f.notes())
        let url = try f.write(project, name: "v1.roughscore")
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        f.configure(w); w.activeString = 1; w.inspectorVisible = true
        w.addEvent(time: 1, string: 1); w.inputDigit(1, at: 100)
        #expect(w.saveAs(to: f.url("prior.roughscore")))
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.project == project && !w.dirty && !w.canUndo)
        #expect(w.cursor == 0 && w.windowStart == 0 && w.windowLength == 12 && w.rate == 1)
        #expect(w.scoreView && w.followScore && w.scorePage == 0 && w.measuresPerSystem == 4)
        #expect(!w.showBothLanes && w.showScoreWaveforms && !w.showLengths && !w.snapToBeat)
        #expect(w.source == .stereo && w.lane == .left && !w.looping && w.loopEnd == 4)
        #expect(w.selectedID == nil && !w.inspectorVisible && w.activeString == 6)
        w.seekForEditing(10); w.inputDigit(2, at: 100.1)
        #expect(w.selected?.fret == 2 && w.project.events.prefix(2).elementsEqual(project.events))
    }
}

private actor SessionLookupGate {
    private var continuation: CheckedContinuation<WorkspaceSession?, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> WorkspaceSession? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ value: WorkspaceSession?) { continuation?.resume(returning: value); continuation = nil }
}

private actor SessionPreparationGate {
    private var continuation: CheckedContinuation<PreparedAudio, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func prepare() async -> PreparedAudio {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ value: PreparedAudio) { continuation?.resume(returning: value); continuation = nil }
}

extension WorkspaceSessionTests {
    @Test(arguments: ["malformed", "unsupported", "stale", "oversized", "foreign", "symlink"])
    func invalidDiskSessionsFallBackWithoutChangingExactV1OrForeignFiles(kind: String) async throws {
        let f = try SessionFixture(); defer { f.clean() }
        var project = ScoreProject(title: "fallback", duration: 120, events: f.notes())
        let url = try f.write(project, name: "fallback.roughscore")
        var state = WorkspaceSession(); state.cursor = 100; state.channel = "right"; state.windowLength = 2
        try f.store.write(state, url, project)
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.url("sessions"), includingPropertiesForKeys: nil).first)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sentinel: URL?
        switch kind {
        case "malformed": try Data("{broken".utf8).write(to: file)
        case "oversized": try Data(repeating: 65, count: 20_000).write(to: file)
        case "unsupported":
            envelope["version"] = 2; try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        case "foreign":
            envelope["owner"] = "Unrelated"; try JSONSerialization.data(withJSONObject: envelope).write(to: file)
        case "symlink":
            let other = f.url("unrelated.txt"); try Data("untouched".utf8).write(to: other); sentinel = other
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        default:
            project.title = "replaced document at same path"
            try JSONEncoder().encode(project).write(to: url)
        }
        let originalRecord = try Data(contentsOf: file), documentBytes = try Data(contentsOf: url)
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.cursor == 0 && w.source == .stereo && w.windowLength == 12 && w.lane == .left)
        #expect(w.project == project && !w.dirty && !w.canUndo && !w.playing)
        w.flushSession()
        #expect(try Data(contentsOf: url) == documentBytes)
        if kind != "stale" {
            #expect(w.sessionPersistenceError != nil)
            #expect(try Data(contentsOf: file) == originalRecord)
        }
        if let sentinel { #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched") }
    }

    @Test func symlinkedStoreRootAndLookupFailureAreAdvisory() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let url = try f.write(ScoreProject(title: "failure", duration: 120, events: f.notes()), name: "failure.roughscore")
        let foreign = f.url("foreign-root"), link = f.url("sessions-link")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        var services = try f.services()
        services.sessionStore = .files(at: link)
        services.sessionStore.read = { _, _ in throw CocoaError(.fileReadNoPermission) }
        let w = Workspace(services: services); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.cursor == 0 && !w.dirty && w.error == nil)
        w.seek(100); w.flushSession()
        #expect(w.sessionPersistenceError != nil && !w.dirty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelledOrShutdownLateSessionLookupCannotPublishOverAnotherProject(shutdown: Bool) async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let a = try f.write(ScoreProject(title: "late A", duration: 120), name: "A.roughscore")
        let b = try f.write(ScoreProject(title: "current B", duration: 40, events: f.notes()), name: "B.roughscore")
        let gate = SessionLookupGate()
        var services = try f.services()
        services.sessionStore.read = { url, _ in url == a ? await gate.read() : nil }
        let w = Workspace(services: services); defer { w.shutdown() }
        let late = try #require(w.loadProject(at: a)); await gate.started()
        w.cancelLoading()
        #expect(await w.loadProject(at: b)?.value == true)
        w.seek(30); w.windowLength = 6
        let current = w.project
        if shutdown { w.shutdown() }
        var stale = WorkspaceSession(); stale.cursor = 100; stale.channel = "right"; stale.lane = "right"; stale.windowLength = 2
        await gate.finish(stale)
        #expect(!(await late.value))
        #expect(w.project == current && w.cursor == 30 && w.windowLength == 6 && w.source == .stereo && w.activeProjectURL == b)
        #expect(!w.busy && !w.playing && !w.dirty && !w.canUndo)
        #expect(w.canEdit == !shutdown)
    }

    @Test func cancellationIgnoringRealPreparationCannotApplyOldSessionAndReleasesScratch() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let audioURL = f.url("generated.caf")
        try StreamingCacheFixture.write(audioURL, seconds: 4, channels: 2)
        let project = ScoreProject(title: "late decoded", audioPath: audioURL.path, duration: 4)
        let a = try f.write(project, name: "A.roughscore")
        let b = try f.write(ScoreProject(title: "B", duration: 40), name: "B.roughscore")
        var session = WorkspaceSession(); session.cursor = 3; session.channel = "right"; session.windowLength = 2
        try f.store.write(session, a, project)
        let gate = SessionPreparationGate(), decoded = try await AudioPreparation.prepare(audioURL)
        var services = try f.services(); services.prepare = { _, _ in await gate.prepare() }
        let w = Workspace(services: services); defer { w.shutdown() }
        let late = try #require(w.loadProject(at: a)); await gate.started()
        w.cancelLoading(); #expect(await w.loadProject(at: b)?.value == true)
        w.seek(20); let current = w.project
        await gate.finish(decoded)
        #expect(!(await late.value))
        #expect(w.project == current && w.cursor == 20 && w.source == .stereo && w.prepared == nil && w.activeProjectURL == b)
        #expect(!FileManager.default.fileExists(atPath: decoded.directory.path))
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @Test func nonfiniteInjectedSessionAndSubframeDurationRemainValid() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let duration = 1.0 / 44100
        let project = ScoreProject(title: "one frame", duration: duration, events: [TabEvent(time: 0, lane: .right, string: 1)])
        let url = try f.write(project, name: "frame.roughscore")
        var state = WorkspaceSession()
        state.cursor = .nan; state.windowStart = .infinity; state.windowLength = .nan
        state.lane = "unknown"; state.channel = "unknown"; state.asset = "unknown"; state.rate = .nan
        state.measuresPerSystem = Int.min; state.scorePage = Int.min
        state.loopStart = .nan; state.loopEnd = .infinity; state.looping = true
        var services = try f.services()
        let immutable = state; services.sessionStore.read = { _, _ in immutable }
        let w = Workspace(services: services); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.cursor == 0 && w.windowStart == 0 && w.windowLength == duration && w.loopEnd == duration && !w.looping)
        #expect(w.scorePage == 0 && w.measuresPerSystem == 1 && w.source == .stereo && w.lane == .left && w.rate == 1)
        #expect(w.project == project && !w.dirty)
        w.flushSession()
        #expect(w.sessionPersistenceError == nil)
    }

    @Test func continuousPlaybackTicksAreCoalescedButPersistBeforePlaybackStops() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let url = try f.write(ScoreProject(title: "ticks", duration: 120), name: "ticks.roughscore")
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        let started = ContinuousClock.now
        for tick in 0..<70 {
            w.cursor = Double(tick) * 0.03
            try await Task.sleep(for: .milliseconds(30))
        }
        let writes = f.capture.sessionWrites
        let elapsedSeconds = Int(started.duration(to: .now).components.seconds)
        // Other native suites can occupy MainActor: bound writes by elapsed time, not assumed timer precision.
        #expect(writes >= 1 && writes <= elapsedSeconds + 1 && f.capture.documentWrites == 0 && !w.dirty && !w.canUndo)
        let persisted = try #require(await f.store.read(url, w.project))
        #expect(persisted.cursor > 0 && persisted.cursor <= w.cursor)
        w.shutdown()
        #expect(f.capture.sessionWrites <= writes + 1)
        #expect(try await f.store.read(url, w.project)?.cursor == w.cursor)
    }
}


extension WorkspaceSessionTests {
    @Test(arguments: [false, true])
    func hostedActualWorkspaceDoesNotReflowRestoredPageOrRecenterWindow(scoreView: Bool) async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let a = try f.write(ScoreProject(title: "hosted A", duration: 120), name: "A.roughscore")
        let project = ScoreProject(title: "hosted B", duration: 120, events: f.notes())
        let b = try f.write(project, name: "B.roughscore")
        var session = WorkspaceSession()
        session.cursor = 100; session.windowStart = 99; session.windowLength = 2
        session.measuresPerSystem = 2; session.showBothLanes = true; session.followScore = false
        session.scorePage = 8; session.scoreView = scoreView; session.lane = "right"
        try f.store.write(session, b, project)
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: a)?.value == true)
        w.scoreView = scoreView; w.followScore = false; w.scorePage = 2
        let host = NotePointerTests.Host(WorkspaceView(workspace: w), height: 900, width: 1440)
        defer { host.close() }
        let previousIdentity = w.editorIdentity
        #expect(await w.loadProject(at: b)?.value == true)
        host.settle(); host.settle()
        #expect(w.editorIdentity != previousIdentity)
        #expect(w.scorePage == 8)
        #expect(w.cursor == 100 && !w.followScore && w.lane == .right)
        #expect(w.windowStart == 99 && w.windowLength == 2 && w.scoreView == scoreView)
        #expect(w.project == project && !w.dirty && !w.canUndo)
    }

    @Test func quitWhilePlayingFlushesTheNativeClockAndReopenStaysPaused() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let source = f.url("generated.caf")
        try StreamingCacheFixture.write(source, seconds: 4, channels: 2)
        let services = try f.services(native: true), w = Workspace(services: services)
        #expect(await w.loadAudio(at: source)?.value == true)
        let url = f.url("playing.roughscore")
        #expect(w.saveAs(to: url))
        w.seek(2); w.switchSource(.right); w.togglePlayback()
        try await Task.sleep(for: .milliseconds(120))
        #expect(w.playing && w.cursor == 2) // No startup timer/tick: the native transport is ahead of UI.
        let project = w.project
        w.shutdown()
        let session = try #require(await f.store.read(url, project))
        #expect(session.cursor > 2 && session.cursor < 3)
        let reopened = Workspace(services: services); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: url)?.value == true)
        #expect(reopened.source == .right && abs(reopened.cursor - session.cursor) < 0.0001 && !reopened.playing)
        let generation = try #require(reopened.prepared?.generation)
        let player = try #require(f.capture.players[generation]?[.right])
        #expect(!player.isPlaying && abs(player.currentTime - session.cursor) < 0.0001)
        #expect(reopened.project == project && !reopened.dirty && !reopened.canUndo)
    }
}


extension WorkspaceSessionTests {
    @Test func failedDocumentAutosaveKeepsSessionAssociatedWithDurableLegacyV1() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let source = f.url("generated-legacy.caf")
        try StreamingCacheFixture.write(source, seconds: 5, channels: 2)
        let legacy = ScoreProject(title: "legacy", audioPath: source.path, duration: 5, events: f.notes())
        let url = try f.write(legacy, name: "legacy.roughscore")
        let bytes = try Data(contentsOf: url)
        var services = try f.services(native: true)
        services.writeProject = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let w = Workspace(services: services)
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.project.originalAsset != nil && w.dirty) // Normal source identity normalization is pending.
        w.seek(3); w.windowLength = 2; w.switchSource(.right); w.flushSession()
        await w.awaitAutosave()
        #expect(w.dirty && w.saveState == .failed && w.project.events == legacy.events)
        #expect(try Data(contentsOf: url) == bytes)
        w.shutdown()
        let reopened = Workspace(services: services); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: url)?.value == true)
        #expect(reopened.cursor == 3 && reopened.source == .right && reopened.windowLength == 2 && !reopened.playing)
        #expect(reopened.project.events == legacy.events && reopened.dirty && !reopened.canUndo)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func staleStemUUIDFallsBackToOriginalEvenWhenAnotherStemIsAvailable() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let original = AudioAsset(reference: AudioReference(path: "/missing/original"))
        let replacement = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: "/missing/replacement"))
        var project = ScoreProject(title: "replacement", audioPath: original.reference.path, duration: 120)
        project.assets = [original, replacement]
        var state = WorkspaceSession()
        state.asset = "importedGuitarStem"; state.assetID = UUID(); state.cursor = 100; state.channel = "right"
        let bounded = state.bounded(to: project, stemAvailable: true)
        #expect(bounded.asset == "original" && bounded.assetID == original.id && bounded.cursor == 100 && bounded.channel == "right")
        state.assetID = replacement.id
        #expect(state.bounded(to: project, stemAvailable: true).asset == "importedGuitarStem")
        #expect(state.bounded(to: project, stemAvailable: false).asset == "original")
    }

    @Test func danglingSessionSymlinkIsPreservedAndItsTargetIsNeverCreated() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let project = ScoreProject(title: "dangling", duration: 120)
        let url = try f.write(project, name: "dangling.roughscore")
        try f.store.write(WorkspaceSession(), url, project)
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.url("sessions"), includingPropertiesForKeys: nil).first)
        let target = f.url("unknown-missing-target")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        w.seek(100); w.flushSession()
        #expect(w.sessionPersistenceError != nil && !w.dirty && !w.canUndo)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}


extension WorkspaceSessionTests {
    @Test func failedRestoredChannelParksStereoAndUsesItsActualSummaryLayout() async throws {
        let f = try SessionFixture(); defer { f.clean() }
        let source = f.url("generated-channel.caf")
        try StreamingCacheFixture.write(source, seconds: 12, channels: 2)
        let services = try f.services(native: true), w = Workspace(services: services)
        #expect(await w.loadAudio(at: source)?.value == true)
        let asset = try #require(w.project.originalAsset), identity = try #require(asset.identity)
        func summary(_ channel: String, bars: [Double]) -> AnalysisSummary {
            AnalysisSummary(bars: bars, provenance: AnalysisProvenance(assetID: asset.id, identity: identity,
                channel: channel, analyzerVersion: "session-channel-test"))
        }
        let left = summary("left", bars: [0, 4, 8])
        w.project.analyses["left"] = left
        w.project.analyses["right"] = summary("right", bars: Array(stride(from: 0.0, to: 12.0, by: 1.0)))
        w.measuresPerSystem = 1; w.switchSource(.right); w.seek(9)
        #expect(w.scorePage == 2)
        let url = f.url("channel.roughscore")
        #expect(w.saveAs(to: url)); let exact = w.project
        w.shutdown(); f.capture.failRightChannel = true
        let reopened = Workspace(services: services); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: url)?.value == true)
        #expect(reopened.source == .stereo && reopened.lane == .right && reopened.cursor == 9 && !reopened.playing)
        #expect(reopened.scoreSummary == left && reopened.scorePage == 0 && reopened.scoreLayout.pageCount == 1)
        let generation = try #require(reopened.prepared?.generation)
        let player = try #require(f.capture.players[generation]?[.stereo])
        #expect(player.source == .stereo && abs(player.currentTime - 9) < 0.0001 && !player.isPlaying)
        #expect(reopened.project == exact && !reopened.dirty && !reopened.canUndo)
    }
}
