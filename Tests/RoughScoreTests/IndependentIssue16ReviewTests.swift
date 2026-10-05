import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor private final class ReviewCapture {
    var players: [UUID: [ListeningSource: AudioEnginePlayer]] = [:]
    var failOriginalRight = false
    var failSession = false
    var documents = 0
}
@MainActor private struct ReviewFixture {
    let root: URL
    let capture = ReviewCapture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("issue16-independent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    var store: WorkspaceSessionStore { .files(at: url("sessions")) }
    func clean() { capture.players.removeAll(); try? FileManager.default.removeItem(at: root) }
    func write(_ project: ScoreProject, _ name: String) throws -> URL {
        let file = url(name); try JSONEncoder().encode(project).write(to: file); return file
    }
    func services() throws -> WorkspaceServices {
        var s = WorkspaceServices.cachedLive(environment: try AudioCacheEnvironment(configuration: .init(root: url("cache"))))
        s.initialProject = { nil }; s.lastProject = { nil }; s.rememberProject = { _ in }
        s.chooseSaveDestination = { _ in nil }; s.nativeTextUndo = { nil }
        s.sessionStore = store
        let capture = capture, make = s.makePlayer, write = store.write
        s.makePlayer = { audio, source in
            if capture.failOriginalRight && audio.original.lastPathComponent == "original.caf" && source == .right {
                throw AudioIssue.playbackFailed
            }
            let p = try #require(make(audio, source) as? AudioEnginePlayer)
            p.graph.engine.mainMixerNode.outputVolume = 0
            capture.players[audio.generation, default: [:]][source] = p
            return p
        }
        s.sessionStore.write = { session, url, project in
            if capture.failSession { throw CocoaError(.fileWriteNoPermission) }
            try write(session, url, project)
        }
        s.writeProject = { data, url in capture.documents += 1; try data.write(to: url, options: .atomic) }
        return s
    }
    var notes: [TabEvent] {
        [TabEvent(time: 0.987654321, lane: .right, string: 2, memo: "unknown"),
         TabEvent(time: 1.111111111, lane: .left, string: 4, fret: 7, length: nil, tentative: true)]
    }
}
private actor ReviewGate {
    var continuation: CheckedContinuation<WorkspaceSession?, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func read() async -> WorkspaceSession? {
        await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ session: WorkspaceSession) { continuation?.resume(returning: session); continuation = nil }
}
@MainActor @Suite(.serialized)
struct IndependentIssue16ReviewTests {
    @Test func generatedNativeStemRestores100SecondsAndOnlySelectedGain() async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        try StreamingCacheFixture.write(f.url("original.caf"), seconds: 120, channels: 2)
        try StreamingCacheFixture.write(f.url("stem.caf"), seconds: 120, channels: 2)
        let services = try f.services(), w = Workspace(services: services)
        #expect(await w.loadAudio(at: f.url("original.caf"))?.value == true)
        #expect(await w.attachStem(at: f.url("stem.caf"))?.value == true)
        w.project.events = f.notes
        #expect(w.saveAs(to: f.url("song.roughscore")))
        #expect(w.switchAsset(.importedGuitarStem))
        w.switchSource(.right); w.lane = .right; w.seek(100)
        w.windowLength = 2; w.windowStart = 99; w.rate = 0.5
        w.showLengths = true; w.followScore = false; w.measuresPerSystem = 1; w.scorePage = 5
        let exact = w.project, bytes = try Data(contentsOf: f.url("song.roughscore"))
        w.shutdown()
        let r = Workspace(services: services); defer { r.shutdown() }
        #expect(await r.loadProject(at: f.url("song.roughscore"))?.value == true)
        #expect(r.assetRole == .importedGuitarStem && r.source == .right && r.lane == .right)
        #expect(r.cursor == 100 && r.windowLength == 2 && r.windowStart == 99 && r.rate == 0.5 && r.scorePage == 5)
        #expect(r.project == exact && !r.dirty && !r.canUndo && !r.canRedo && !r.playing)
        #expect(try Data(contentsOf: f.url("song.roughscore")) == bytes)
        let generation = try #require(r.prepared?.generation), p = try #require(f.capture.players[generation]?[.right])
        #expect(p.currentTime == 100 && !p.isPlaying)
        #expect(p.graph.nativeGains[.right] == 1 && p.graph.nativeGains[.left] == 0 && p.graph.nativeGains[.stereo] == 0)
        r.togglePlayback(); try await Task.sleep(for: .milliseconds(100)); r.tick()
        #expect(r.playing && r.cursor >= 100 && r.cursor < 101)
        r.togglePlayback()
        #expect(!r.dirty && !r.canUndo && r.project.events == exact.events)
    }
    @Test func availableStemRightMustNotDependOnInactiveOriginalRight() async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        try StreamingCacheFixture.write(f.url("original.caf"), seconds: 12, channels: 2)
        try StreamingCacheFixture.write(f.url("stem.caf"), seconds: 12, channels: 2)
        let services = try f.services(), w = Workspace(services: services)
        #expect(await w.loadAudio(at: f.url("original.caf"))?.value == true)
        #expect(await w.attachStem(at: f.url("stem.caf"))?.value == true)
        #expect(w.saveAs(to: f.url("song.roughscore")))
        #expect(w.switchAsset(.importedGuitarStem)); w.switchSource(.right); w.seek(8)
        w.shutdown(); f.capture.failOriginalRight = true
        let r = Workspace(services: services); defer { r.shutdown() }
        #expect(await r.loadProject(at: f.url("song.roughscore"))?.value == true)
        let generation = try #require(r.prepared?.generation)
        let readyRight = try #require(f.capture.players[generation]?[.right])
        #expect(readyRight.prepareToPlay()) // Requested Stem/right is available and native.
        print("ISSUE16 inactive-original failure: restored asset=\(r.assetRole) channel=\(r.source) cursor=\(r.cursor) stemRightPrepared=\(readyRight.prepareToPlay())")
        #expect(r.assetRole == .importedGuitarStem && r.cursor == 8 && !r.playing && !r.dirty)
        #expect(r.source == .right)
        #expect(readyRight.graph.nativeGains[.right] == 1 && readyRight.graph.nativeGains[.stereo] == 0)
    }
    @Test func ABSaveAsCopyAndAdvisoryFailureKeepDocumentHistory() async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        let project = ScoreProject(title: "A", duration: 120, events: f.notes)
        let a = try f.write(project, "A.roughscore"), b = try f.write(ScoreProject(title: "B", duration: 30), "B.roughscore")
        let s = try f.services(), w = Workspace(services: s); defer { w.shutdown() }
        #expect(await w.loadProject(at: a)?.value == true)
        w.seek(101); w.lane = .right; w.windowLength = 2
        #expect(w.saveCopy(to: f.url("copy.roughscore")))
        #expect(w.activeProjectURL == a && !w.dirty && !w.canUndo)
        #expect(w.saveAs(to: f.url("new.roughscore")))
        #expect(w.activeProjectURL == f.url("new.roughscore"))
        w.seek(40); w.addEvent(time: 3, string: 2); await w.awaitAutosave()
        #expect(!w.dirty && w.canUndo)
        f.capture.failSession = true; w.seek(41); w.flushSession()
        #expect(w.sessionPersistenceError != nil && !w.dirty && w.canUndo)
        w.undoEdit(); await w.awaitAutosave(); #expect(!w.dirty && w.project.events == project.events && w.canRedo)
        f.capture.failSession = false; w.flushSession()
        #expect(await w.loadProject(at: b)?.value == true)
        #expect(w.cursor == 0 && w.lane == .left && w.windowLength == 12)
        w.seek(15); #expect(await w.loadProject(at: a)?.value == true)
        #expect(w.cursor == 101 && w.lane == .right && w.project == project)
        #expect(await w.loadProject(at: f.url("new.roughscore"))?.value == true)
        #expect(w.cursor == 41 && !w.canUndo && w.project.events == project.events)
        #expect(await w.loadProject(at: f.url("copy.roughscore"))?.value == true)
        #expect(w.cursor == 101 && w.windowLength == 2 && w.project == project)
    }
    @Test func missingStemShortAudioClampsWithoutEditingNotes() async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        try StreamingCacheFixture.write(f.url("original.caf"), seconds: 4, channels: 2)
        var project = ScoreProject(title: "shorter", audioPath: f.url("original.caf").path, duration: 120, events: f.notes)
        let original = AudioAsset(reference: .init(path: f.url("original.caf").path))
        let stem = AudioAsset(role: .importedGuitarStem, reference: .init(path: f.url("missing.caf").path))
        project.assets = [original, stem]
        let url = try f.write(project, "short.roughscore")
        var session = WorkspaceSession(); session.asset = "importedGuitarStem"; session.assetID = stem.id
        session.channel = "right"; session.cursor = 100; session.windowLength = 2; session.windowStart = 99
        session.looping = true; session.loopStart = 99; session.loopEnd = 110; session.scorePage = Int.max
        try f.store.write(session, url, project)
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: url)?.value == true)
        #expect(w.project.duration == 4 && w.cursor == 4.nextDown && w.windowLength == 2 && w.windowStart == 2)
        #expect(w.assetRole == .original && w.source == .right && !w.looping && !w.playing)
        #expect(w.project.events == project.events && w.scorePage < w.scoreLayout.pageCount)
    }
    @Test func failedAndLateLoadsPreserveCurrentView() async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        let a = try f.write(ScoreProject(title: "A", duration: 120, events: f.notes), "A.roughscore")
        let b = try f.write(ScoreProject(title: "B", duration: 30), "B.roughscore")
        var s = try f.services(); let gate = ReviewGate(), read = s.sessionStore.read
        s.sessionStore.read = { url, project in if url == a { return await gate.read() }; return try await read(url, project) }
        let w = Workspace(services: s); defer { w.shutdown() }
        let late = try #require(w.loadProject(at: a)); await gate.started(); w.cancelLoading()
        #expect(await w.loadProject(at: b)?.value == true)
        w.seek(17); w.windowLength = 3; w.lane = .right
        var stale = WorkspaceSession(); stale.cursor = 100; stale.channel = "left"
        await gate.finish(stale); #expect(await late.value == false)
        let exact = w.project, id = w.editorIdentity
        #expect(await w.loadProject(at: f.url("absent.roughscore"))?.value == false)
        #expect(w.activeProjectURL == b && w.project == exact && w.editorIdentity == id)
        #expect(w.cursor == 17 && w.windowLength == 3 && w.lane == .right && !w.busy && !w.playing && !w.dirty && !w.canUndo)
    }
    @Test(arguments: [false, true]) func hostedRestorationThenUserReflowWorks(score: Bool) async throws {
        let f = try ReviewFixture(); defer { f.clean() }
        let a = try f.write(ScoreProject(title: "A", duration: 120), "A.roughscore")
        let project = ScoreProject(title: "B", duration: 120, events: f.notes)
        let b = try f.write(project, "B.roughscore")
        var session = WorkspaceSession(); session.cursor = 87; session.windowLength = 3; session.windowStart = 85
        session.scoreView = score; session.followScore = false; session.measuresPerSystem = 1; session.scorePage = 6
        try f.store.write(session, b, project)
        let w = Workspace(services: try f.services()); defer { w.shutdown() }
        #expect(await w.loadProject(at: a)?.value == true); w.scoreView = score
        let host = NotePointerTests.Host(WorkspaceView(workspace: w), height: 900, width: 1440); defer { host.close() }
        #expect(await w.loadProject(at: b)?.value == true); host.settle(); host.settle()
        #expect(w.cursor == 87 && w.windowLength == 3 && w.windowStart == 85 && w.scorePage == 6)
        if score {
            let previous = w.scoreLayout, anchor = try #require(previous.rows(on: 6).first?.start)
            w.measuresPerSystem = 4; host.settle(); host.settle()
            #expect(w.scorePage == w.scoreLayout.page(at: anchor))
        } else {
            w.windowLength = 2; host.settle(); host.settle()
            #expect(w.windowStart <= w.cursor && w.windowStart + w.windowLength >= w.cursor)
        }
        #expect(w.project == project && !w.dirty && !w.canUndo)
    }
}
