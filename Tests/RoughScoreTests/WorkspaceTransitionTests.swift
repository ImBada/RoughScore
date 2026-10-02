import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

/// Services intentionally ignore cancellation: correctness must hold even after the last decoder check.
private actor TransitionAudio {
    struct Request {
        let continuation: CheckedContinuation<PreparedAudio, any Error>
        let progress: @Sendable (Double) async -> Void
    }
    private var requests: [URL: Request] = [:]
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var analysis: CheckedContinuation<AnalysisSummary, any Error>?
    private var analysisWaiter: CheckedContinuation<Void, Never>?

    func prepare(_ url: URL, progress: @escaping @Sendable (Double) async -> Void) async throws -> PreparedAudio {
        await progress(0)
        return try await withCheckedThrowingContinuation { continuation in
            requests[url] = Request(continuation: continuation, progress: progress)
            startWaiters.removeValue(forKey: url)?.forEach { $0.resume() }
        }
    }
    func started(_ url: URL) async {
        if requests[url] != nil { return }
        await withCheckedContinuation { startWaiters[url, default: []].append($0) }
    }
    func progress(_ value: Double, for url: URL) async {
        if let request = requests[url] { await request.progress(value) }
    }
    func finish(_ url: URL, result: Result<PreparedAudio, any Error>) {
        requests.removeValue(forKey: url)!.continuation.resume(with: result)
    }
    func analyze() async throws -> AnalysisSummary {
        try await withCheckedThrowingContinuation { continuation in
            analysis = continuation; analysisWaiter?.resume(); analysisWaiter = nil
        }
    }
    func analysisStarted() async {
        if analysis != nil { return }
        await withCheckedContinuation { analysisWaiter = $0 }
    }
    func finishAnalysis(_ summary: AnalysisSummary) { analysis?.resume(returning: summary); analysis = nil }
}

private struct TransitionFixture {
    let root: URL
    let fake = TransitionAudio()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-transition-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func audio(_ name: String, duration: Double = 20) throws -> URL {
        let url = root.appendingPathComponent(name + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let count = AVAudioFrameCount(duration * 8_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: Int(count))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    func prepared(_ url: URL, duration: Double = 20) throws -> PreparedAudio {
        let directory = root.appendingPathComponent("prepared-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let left = directory.appendingPathComponent("left.caf"), right = directory.appendingPathComponent("right.caf")
        try FileManager.default.copyItem(at: url, to: left)
        try FileManager.default.copyItem(at: url, to: right)
        return PreparedAudio(original: url, left: left, right: right, directory: directory, duration: duration,
                             isMono: true, leftPeaks: [0.1], rightPeaks: [0.1])
    }
    @MainActor func services(last: URL? = nil, demo: URL? = nil) -> WorkspaceServices {
        var services = WorkspaceServices.live
        services.prepare = { try await fake.prepare($0, progress: $1) }
        services.createDemo = { _ in try #require(demo) }
        services.analyze = { _, _ in try await fake.analyze() }
        services.lastProject = { last }
        services.rememberProject = { _ in } // Tests never read/write the user's defaults or audio.
        return services
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct WorkspaceTransitionTests {
    @Test func startupLocksBeforeTaskAndRejectsEveryEditorMutation() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let demo = try f.audio("startup", duration: 24)
        let workspace = Workspace(services: f.services(demo: demo), awaitsStartup: true)
        defer { workspace.shutdown() }
        let original = workspace.project
        workspace.addEvent(time: 10, string: 1)
        #expect(workspace.project == original) // Also covers the SwiftUI frame before .task runs.
        let task = try #require(workspace.start())
        #expect(workspace.busy)
        #expect(workspace.start() == nil)
        await f.fake.started(demo)
        attemptEdits(workspace)
        #expect(workspace.project == original)
        #expect(!workspace.canUndo)
        #expect(!workspace.canRedo)
        let audio = try f.prepared(demo, duration: 24)
        await f.fake.finish(demo, result: .success(audio))
        #expect(await task.value)
        #expect(workspace.canEdit)
        #expect(workspace.project.events.map(\.time) == original.events.map(\.time))
        #expect(workspace.isDemo)
        #expect(!workspace.dirty)
    }

    @Test func relinkReservesSynchronouslyAndFailureRetainsDirtyUndoSelectionAndSource() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("bad-relink")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(title: "unsaved", duration: 20)
        workspace.addEvent(time: 2, string: 5); workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        workspace.source = .right
        let original = workspace.project, selected = workspace.selectedID
        let task = try #require(workspace.loadAudio(at: url, relink: true))
        #expect(workspace.busy) // No Task yield required to reserve the operation.
        #expect(workspace.loadAudio(at: url, relink: true) == nil)
        #expect(workspace.loadProject(at: url) == nil)
        await f.fake.started(url)
        attemptEdits(workspace)
        #expect(workspace.project == original)
        #expect(workspace.selectedID == selected)
        await f.fake.finish(url, result: .failure(AudioIssue.unsupported))
        #expect(!(await task.value))
        #expect(workspace.project == original)
        #expect(workspace.source == .right)
        #expect(workspace.selectedID == selected)
        #expect(workspace.dirty && workspace.canUndo && !workspace.canRedo)
        workspace.undoEdit()
        #expect(workspace.project.events.isEmpty) // Retained 12-fret creation remains a single undo.
    }

    @Test func cancelledAAfterBCommitCannotReplaceOrCleanBOrPublishProgress() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let a = try f.audio("A"), b = try f.audio("B")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let original = workspace.project
        let taskA = try #require(workspace.loadAudio(at: a))
        await f.fake.started(a)
        await f.fake.progress(0.6, for: a)
        #expect(workspace.loadProgress == 0.6)
        await f.fake.progress(0.2, for: a)
        await f.fake.progress(.nan, for: a)
        #expect(workspace.loadProgress == 0.6)
        workspace.cancelLoading()
        #expect(workspace.project == original)
        #expect(workspace.canEdit)
        let taskB = try #require(workspace.loadAudio(at: b))
        await f.fake.started(b)
        let audioB = try f.prepared(b)
        await f.fake.finish(b, result: .success(audioB))
        #expect(await taskB.value)
        let committed = workspace.project, status = workspace.status
        let audioA = try f.prepared(a)
        await f.fake.progress(0.9, for: a)
        await f.fake.finish(a, result: .success(audioA))
        #expect(!(await taskA.value))
        #expect(workspace.project == committed)
        #expect(workspace.prepared?.directory == audioB.directory)
        #expect(workspace.status == status && workspace.loadProgress == 1)
        #expect(!FileManager.default.fileExists(atPath: audioA.directory.path))
        #expect(FileManager.default.fileExists(atPath: audioB.directory.path))
        #expect(FileManager.default.fileExists(atPath: a.path)) // Original fixture was not cleaned.
    }

    @Test func lateACannotReleaseTheBusySlotOfPendingB() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let a = try f.audio("A"), b = try f.audio("B")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let taskA = try #require(workspace.loadAudio(at: a))
        await f.fake.started(a); workspace.cancelLoading()
        let taskB = try #require(workspace.loadAudio(at: b))
        await f.fake.started(b)
        let audioA = try f.prepared(a)
        await f.fake.finish(a, result: .success(audioA))
        #expect(!(await taskA.value))
        #expect(workspace.busy && !workspace.canEdit)
        #expect(!FileManager.default.fileExists(atPath: audioA.directory.path))
        let audioB = try f.prepared(b)
        await f.fake.finish(b, result: .success(audioB))
        #expect(await taskB.value)
        #expect(workspace.project.title == "B")
    }

    @Test func callerTaskCancellationAtFinalDecodeBoundaryCleansStagedResult() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("cancel")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let original = workspace.project
        let task = try #require(workspace.loadAudio(at: url))
        await f.fake.started(url)
        await f.fake.progress(1, for: url) // All decoding finished, but main-actor commit has not run.
        task.cancel()
        let audio = try f.prepared(url)
        await f.fake.finish(url, result: .success(audio))
        #expect(!(await task.value))
        #expect(workspace.project == original && workspace.prepared == nil)
        #expect(workspace.canEdit)
        #expect(!FileManager.default.fileExists(atPath: audio.directory.path))
    }

    @Test func shutdownRejectsLateLoadAndFurtherCommands() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("shutdown")
        let workspace = Workspace(services: f.services())
        let original = workspace.project
        let task = try #require(workspace.loadAudio(at: url))
        await f.fake.started(url); workspace.shutdown()
        let status = workspace.status
        await f.fake.progress(0.75, for: url)
        let audio = try f.prepared(url)
        await f.fake.finish(url, result: .success(audio))
        #expect(!(await task.value))
        attemptEdits(workspace)
        #expect(workspace.project == original && workspace.prepared == nil)
        #expect(!workspace.busy && !workspace.canEdit && workspace.status == status)
        #expect(workspace.loadAudio(at: url) == nil && workspace.start() == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.directory.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func startupRestoreUsesSameBarrierAndTracksSaveLocation() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("restored")
        let projectURL = f.root.appendingPathComponent("saved.roughscore")
        let saved = ScoreProject(title: "restore", audioPath: url.path, duration: 20,
                                 events: [TabEvent(time: 1.213, lane: .right, string: 2, fret: nil)])
        try JSONEncoder().encode(saved).write(to: projectURL)
        let workspace = Workspace(services: f.services(last: projectURL), awaitsStartup: true)
        defer { workspace.shutdown() }
        let task = try #require(workspace.start())
        await f.fake.started(url)
        workspace.inputDigit(7, at: 100)
        let audio = try f.prepared(url)
        await f.fake.finish(url, result: .success(audio))
        #expect(await task.value)
        #expect(workspace.project == saved && workspace.hasSaveLocation && !workspace.dirty)
        #expect(workspace.selectedID == nil && !workspace.canUndo)
    }

    @Test func relinkBeyondExistingNotesRejectsAndCleansOnlyStagedAudio() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let oldURL = try f.audio("old"), shortURL = try f.audio("short", duration: 1)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let initial = try #require(workspace.loadAudio(at: oldURL))
        await f.fake.started(oldURL)
        let oldAudio = try f.prepared(oldURL)
        await f.fake.finish(oldURL, result: .success(oldAudio)); #expect(await initial.value)
        workspace.addEvent(time: 2, string: 5); workspace.inputDigit(7, at: 100)
        workspace.switchSource(.left)
        let original = workspace.project, selected = workspace.selectedID
        let task = try #require(workspace.loadAudio(at: shortURL, relink: true))
        await f.fake.started(shortURL)
        let shortAudio = try f.prepared(shortURL, duration: 1)
        await f.fake.finish(shortURL, result: .success(shortAudio))
        #expect(!(await task.value))
        #expect(workspace.project == original && workspace.selectedID == selected && workspace.dirty)
        #expect(workspace.hasSaveLocation == false && workspace.source == .left && workspace.canUndo)
        #expect(workspace.prepared?.directory == oldAudio.directory)
        #expect(FileManager.default.fileExists(atPath: oldAudio.directory.path))
        #expect(!FileManager.default.fileExists(atPath: shortAudio.directory.path))
    }

    @Test func unexpectedProjectRevisionCannotBeOverwrittenByLoad() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("revision")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let task = try #require(workspace.loadAudio(at: url))
        await f.fake.started(url)
        workspace.project.title = "changed by another owner" // Even bypasses normal command guards.
        let changed = workspace.project
        let audio = try f.prepared(url)
        await f.fake.finish(url, result: .success(audio))
        #expect(!(await task.value))
        #expect(workspace.project == changed && workspace.canEdit)
        #expect(!FileManager.default.fileExists(atPath: audio.directory.path))
    }

    @Test func missingAudioActivationResetsOldDragAndKeepsOfflineEditing() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let note = workspace.project.events[0]
        workspace.beginPositionDrag(note); workspace.previewPositionDrag(time: 7, string: 1)
        let projectURL = f.root.appendingPathComponent("offline.roughscore")
        let offline = ScoreProject(title: "offline", duration: 20)
        try JSONEncoder().encode(offline).write(to: projectURL)
        let task = try #require(workspace.loadProject(at: projectURL))
        #expect(workspace.busy)
        #expect(await task.value)
        #expect(workspace.positionDrag == nil && workspace.positionMagnetTargetID == nil)
        #expect(workspace.project == offline && workspace.prepared == nil && workspace.hasSaveLocation)
        workspace.inputDigit(7, at: 100)
        #expect(workspace.selected?.fret == 7)
    }

    @Test func ordinaryEditsDuringAnalysisSurviveButCancelledResultCannotReachNewProject() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let a = try f.audio("analysis-A"), b = try f.audio("analysis-B")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let taskA = try #require(workspace.loadAudio(at: a))
        await f.fake.started(a)
        await f.fake.finish(a, result: .success(try f.prepared(a))); #expect(await taskA.value)
        let analysisTask = try #require(workspace.analyze()); await f.fake.analysisStarted()
        workspace.addEvent(time: 2, string: 6); workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        #expect(workspace.selected?.fret == 12 && workspace.analyzing)
        workspace.cancelAnalysis()
        // Dirty relink retains authored TAB and allows a new audio identity after cancellation.
        let taskB = try #require(workspace.loadAudio(at: b, relink: true))
        await f.fake.started(b)
        await f.fake.finish(b, result: .success(try f.prepared(b))); #expect(await taskB.value)
        let projectB = workspace.project
        await f.fake.finishAnalysis(AnalysisSummary(bpm: 99, beats: [1]))
        // The old analysis Task's cancellation check/identity guard must run before observing state.
        await analysisTask.value
        #expect(workspace.project == projectB && workspace.project.analyses.isEmpty)
        #expect(workspace.selected == nil && workspace.project.events.first?.fret == 12)
    }

    @Test func successfulRelinkPreservesSparseMetadataAndUnsavedWork() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("relink")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let events = [TabEvent(time: 1.213, lane: .left, string: 6, memo: "unknown"),
                      TabEvent(time: 3.083, lane: .right, string: 1, fret: 12, length: .eighth, tentative: true)]
        workspace.project = ScoreProject(title: "unsaved", duration: 20, events: events)
        workspace.dirty = true
        let task = try #require(workspace.loadAudio(at: url, relink: true))
        await f.fake.started(url)
        attemptEdits(workspace)
        await f.fake.finish(url, result: .success(try f.prepared(url)))
        #expect(await task.value)
        #expect(workspace.project.events == events && workspace.dirty && !workspace.hasSaveLocation)
        #expect(try workspace.project.validated() == workspace.project)
    }

    @Test func failedDemoReplacementKeepsPreviousDemoAndCleansNewOwnedFile() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let old = try f.audio("old-demo", duration: 24), new = try f.audio("new-demo")
        var services = f.services(demo: old)
        services.createDemo = { $0.duration > 24 ? new : old }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        let first = try #require(workspace.start())
        await f.fake.started(old)
        let oldAudio = try f.prepared(old, duration: 24)
        await f.fake.finish(old, result: .success(oldAudio)); #expect(await first.value)
        let original = workspace.project
        let second = try #require(workspace.loadDemo(long: true))
        await f.fake.started(new)
        #expect(FileManager.default.fileExists(atPath: old.path))
        await f.fake.finish(new, result: .failure(AudioIssue.unsupported))
        #expect(!(await second.value))
        #expect(workspace.project == original && workspace.prepared?.directory == oldAudio.directory)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: oldAudio.directory.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func analysisCompletingAfterManualInputPreservesInputAndAllowsOneStepUndo() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("analyzing")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let load = try #require(workspace.loadAudio(at: url))
        await f.fake.started(url)
        await f.fake.finish(url, result: .success(try f.prepared(url))); #expect(await load.value)
        let analysis = try #require(workspace.analyze())
        await f.fake.analysisStarted()
        workspace.addEvent(time: 1.213, string: 6)
        workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        let summary = AnalysisSummary(bpm: 120, beats: [0, 1, 2])
        await f.fake.finishAnalysis(summary); await analysis.value
        #expect(workspace.project.analyses["stereo"] == summary)
        #expect(workspace.selected?.time == 1.213 && workspace.selected?.fret == 12)
        workspace.undoEdit()
        #expect(workspace.project.events.isEmpty && workspace.project.analyses["stereo"] == summary)
    }

    @Test func editsAndRedoAfterCancellationSurviveALateResult() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("cancel-then-edit")
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.addEvent(time: 1.213, string: 6); workspace.inputDigit(7, at: 100)
        workspace.undoEdit()
        #expect(workspace.canRedo)
        let load = try #require(workspace.loadAudio(at: url, relink: true))
        await f.fake.started(url)
        workspace.redoEdit()
        #expect(workspace.project.events.isEmpty && workspace.canRedo)
        workspace.cancelLoading()
        workspace.redoEdit()
        let edited = workspace.project
        let audio = try f.prepared(url)
        await f.fake.finish(url, result: .success(audio))
        #expect(!(await load.value))
        #expect(workspace.project == edited && workspace.canUndo && workspace.dirty)
        #expect(workspace.project.events.first?.fret == 7 && workspace.prepared == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.directory.path))
    }

    @Test func lateProjectReadAndDemoCreationCannotPublishAfterCancellationOrShutdown() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let read = Deferred<ScoreProject>(), demo = Deferred<URL>()
        var services = f.services()
        services.readProject = { _ in try await read.value() }
        services.createDemo = { _ in try await demo.value() }
        let workspace = Workspace(services: services)
        let original = workspace.project
        let load = try #require(workspace.loadProject(at: f.root.appendingPathComponent("pending.roughscore")))
        await read.started(); workspace.cancelLoading()
        await read.finish(ScoreProject(title: "late offline project", duration: 20))
        #expect(!(await load.value))
        #expect(workspace.project == original && !workspace.hasSaveLocation)
        let start = try #require(workspace.start())
        await demo.started(); workspace.shutdown()
        let ownedDemo = try f.audio("late-created-demo", duration: 24)
        await demo.finish(ownedDemo)
        #expect(!(await start.value))
        #expect(workspace.project == original && workspace.prepared == nil && !workspace.canEdit)
        #expect(!FileManager.default.fileExists(atPath: ownedDemo.path))
    }

    @Test func shutdownAlsoRejectsLateAnalysisWithoutResurrectingState() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("analysis-shutdown")
        let workspace = Workspace(services: f.services())
        let load = try #require(workspace.loadAudio(at: url))
        await f.fake.started(url)
        await f.fake.finish(url, result: .success(try f.prepared(url))); #expect(await load.value)
        let analysis = try #require(workspace.analyze()); await f.fake.analysisStarted()
        let original = workspace.project
        workspace.shutdown()
        let status = workspace.status
        await f.fake.finishAnalysis(AnalysisSummary(bpm: 99, beats: [1])); await analysis.value
        #expect(workspace.project == original && workspace.prepared == nil && !workspace.analyzing)
        #expect(workspace.status == status && !workspace.canEdit)
    }

    @Test func actualDecoderReportsMonotonicFrameProgressAndCooperatesWithChunkCancellation() async throws {
        let f = try TransitionFixture(); defer { f.clean() }
        let url = try f.audio("actual", duration: 40)
        let capture = ProgressCapture()
        let audio = try await AudioPreparation.prepare(url) { await capture.record($0) }
        defer { try? FileManager.default.removeItem(at: audio.directory) }
        let values = await capture.values
        #expect(values.first == 0 && values.last == 1 && values.count > 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        let cancelled = ProgressCapture()
        do {
            _ = try await AudioPreparation.prepare(url) { value in
                await cancelled.record(value)
                if value > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            Issue.record("Chunk cancellation unexpectedly succeeded")
        } catch is CancellationError { }
        let cancelledValues = await cancelled.values
        #expect(cancelledValues.count == 2 && cancelledValues.last! < 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func attemptEdits(_ workspace: Workspace) {
        workspace.addEvent(time: 10, string: 1)
        workspace.inputDigit(7, at: 100)
        workspace.updateSelected { $0.memo = "must not apply" }
        workspace.deleteSelected()
        workspace.moveSelectedString(by: -1)
        workspace.nudgeSelectedTime(by: 0.05)
        workspace.markUnknown(); workspace.toggleTentative()
        workspace.undoEdit(); workspace.redoEdit()
        workspace.switchSource(.left)
        workspace.beginPositionDrag(workspace.project.events.first ?? TabEvent(time: 1, lane: .left, string: 6))
        workspace.previewPositionDrag(time: 3, string: 4)
        workspace.commitPositionDrag()
    }
}

private actor ProgressCapture {
    private(set) var values: [Double] = []
    func record(_ value: Double) { values.append(value) }
}

private actor Deferred<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}
