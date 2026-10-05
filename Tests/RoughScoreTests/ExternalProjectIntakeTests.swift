import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

private actor IntakeReadGate {
    private var requests: [URL: CheckedContinuation<ScoreProject, any Error>] = [:]
    private var waiters: [URL: CheckedContinuation<Void, Never>] = [:]
    func read(_ url: URL) async throws -> ScoreProject {
        try await withCheckedThrowingContinuation { requests[url] = $0; waiters.removeValue(forKey: url)?.resume() }
    }
    func started(_ url: URL) async {
        if requests[url] != nil { return }
        await withCheckedContinuation { waiters[url] = $0 }
    }
    func finish(_ url: URL, _ project: ScoreProject) { requests.removeValue(forKey: url)!.resume(returning: project) }
}

@MainActor private final class IntakeCapture {
    var prompts = 0
    var demos = 0
    var remembered: [URL] = []
    var decision: DiscardDecision = .discard
    var onDecision: (() -> Void)?
    var onSave: (() -> Void)?
    var onRemember: (() -> Void)?
    var saveDestination: URL?
    var failSave = false
    var modal = false
    var nativeUndo: NativeTextUndoTarget?
}

@MainActor private struct IntakeFixture {
    let root: URL
    let capture = IntakeCapture()
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RoughScore-intake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func document(_ name: String, project: ScoreProject? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try JSONEncoder().encode(project ?? ScoreProject(title: name, duration: 20)).write(to: url)
        return url
    }
    func services() throws -> WorkspaceServices {
        var s = WorkspaceServices.cachedLive(environment: try AudioCacheEnvironment(configuration: .init(root: root.appendingPathComponent("cache"))))
        s.initialProject = { nil }; s.lastProject = { nil }
        s.rememberProject = { capture.remembered.append($0); capture.onRemember?() }
        s.sessionStore = .files(at: root.appendingPathComponent("sessions"))
        s.createDemo = { _ in await MainActor.run { capture.demos += 1 }; throw AudioIssue.unavailable }
        s.discardDecision = { capture.prompts += 1; capture.onDecision?(); return capture.decision }
        s.nativeModalActive = { capture.modal }
        s.nativeTextUndo = { capture.nativeUndo }
        s.chooseSaveDestination = { _ in capture.onSave?(); return capture.saveDestination }
        s.writeProject = { data, url in
            if capture.failSave { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        return s
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func cold(_ url: URL, services: WorkspaceServices? = nil) async throws -> (Workspace, AppDelegate) {
        let d = AppDelegate(), w = Workspace(services: try services ?? self.services(), awaitsStartup: true)
        d.application(NSApplication.shared, open: [url])
        #expect(d.externalProjects.hasPendingRequest)
        d.bind(w)
        #expect(await d.externalProjects.task?.value == true)
        return (w, d)
    }
}

@MainActor @Suite(.serialized)
struct ExternalProjectIntakeTests {
    @Test func nativeCallbackQueuesFirstWinsAndStartsLifecycleOnce() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("첫 번째 A.ROUGHScore"), b = try f.document("B.roughscore")
        var s = try f.services()
        s.initialProject = { b }; s.lastProject = { b }
        let d = AppDelegate(), w = Workspace(services: s, awaitsStartup: true); defer { w.shutdown() }
        d.application(NSApplication.shared, open: [a])
        #expect(d.externalProjects.hasPendingRequest && d.externalProjects.lastCompletion == nil)
        #expect(d.externalProjects.receive([a]) == .rejected)
        #expect(d.externalProjects.receive([b]) == .rejected)
        var shows = 0
        d.bind(w, showMainWindow: { shows += 1 })
        let task = try #require(d.externalProjects.task)
        #expect(w.busy && d.externalProjects.lastCompletion == nil)
        d.bind(w)
        #expect(await task.value)
        #expect(w.activeProjectURL == a && f.capture.remembered == [a])
        #expect(w.start() == nil && d.externalProjects.lastCompletion == .opened)
        #expect(w.externalOpenError != nil && f.capture.prompts == 0)
        d.application(NSApplication.shared, open: [URL(string: "https://example.invalid/A.roughscore")!])
        #expect(shows == 1 && w.activeProjectURL == a)
    }

    @Test(arguments: ["empty", "multi", "unsupported", "scheme", "remote-file", "missing", "directory-file", "file-package"])
    func structuralRejectionsNeverPromptCancelStartupOrMutate(kind: String) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let good = try f.document("good.roughscore")
        let wrong = try f.document("file.roughscorepkg")
        let directory = f.root.appendingPathComponent("directory.roughscore")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let d = AppDelegate(), w = Workspace(services: try f.services(), awaitsStartup: true); defer { w.shutdown() }
        let original = w.project, identity = w.editorIdentity
        let urls: [URL]
        switch kind {
        case "empty": urls = []
        case "multi": urls = [good, good]
        case "unsupported": urls = [try f.document("audio.caf")]
        case "scheme": urls = [URL(string: "https://example.invalid/good.roughscore")!]
        case "remote-file": urls = [URL(string: "file://remote.invalid/good.roughscore")!]
        case "missing": urls = [f.root.appendingPathComponent("missing.roughscore")]
        case "directory-file": urls = [directory]
        default: urls = [wrong]
        }
        d.application(NSApplication.shared, open: urls)
        #expect(!d.externalProjects.hasPendingRequest && d.externalProjects.lastRejection != nil)
        #expect(w.busy && w.project == original && w.editorIdentity == identity)
        #expect(f.capture.prompts == 0 && f.capture.remembered.isEmpty)
        d.application(NSApplication.shared, open: [good]); d.bind(w)
        #expect(await d.externalProjects.task?.value == true)
        #expect(w.activeProjectURL == good)
    }

    @Test func automaticStartupLateAIsInvalidatedAndCannotReleaseExplicitBOrFallback() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("startup-A.roughscore"), b = try f.document("explicit-B.roughscore")
        let gate = IntakeReadGate()
        var s = try f.services(); s.initialProject = { a }; s.readProject = { try await gate.read($0) }
        let w = Workspace(services: s, awaitsStartup: true), d = AppDelegate(); defer { w.shutdown() }
        let automatic = try #require(w.start()); await gate.started(a)
        d.bind(w); d.application(NSApplication.shared, open: [b])
        let explicit = try #require(d.externalProjects.task); await gate.started(b)
        await gate.finish(a, ScoreProject(title: "stale A", duration: 20))
        #expect(!(await automatic.value))
        #expect(w.busy && w.activeProjectURL == nil && f.capture.remembered.isEmpty)
        await gate.finish(b, ScoreProject(title: "explicit B", duration: 20))
        #expect(await explicit.value)
        #expect(w.project.title == "explicit B" && f.capture.remembered == [b] && w.start() == nil)
        #expect(f.capture.demos == 0)
    }

    @Test func cancelledExplicitDoesNotResumeStartupAndLateACannotReportSuccessOverB() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore"), b = try f.document("B.roughscore")
        let gate = IntakeReadGate(); var s = try f.services(); s.readProject = { try await gate.read($0) }
        let d = AppDelegate(), w = Workspace(services: s, awaitsStartup: true); defer { w.shutdown() }
        d.application(NSApplication.shared, open: [a]); d.bind(w)
        let taskA = try #require(d.externalProjects.task); await gate.started(a)
        w.cancelLoading()
        #expect(w.start() == nil && !w.busy && d.externalProjects.lastCompletion == .notOpened)
        d.application(NSApplication.shared, open: [b])
        let taskB = try #require(d.externalProjects.task); await gate.started(b)
        await gate.finish(b, ScoreProject(title: "B", duration: 20)); #expect(await taskB.value)
        let identity = w.editorIdentity, status = w.status
        await gate.finish(a, ScoreProject(title: "late A", duration: 20)); #expect(!(await taskA.value))
        #expect(w.project.title == "B" && w.editorIdentity == identity && w.status == status)
        #expect(d.externalProjects.lastCompletion == .opened && f.capture.remembered == [b])
        #expect(f.capture.demos == 0)
    }

    @Test(arguments: ["cancel", "save-cancel", "save-failure", "discard-invalid", "discard-invalid-schema", "discard-invalid-package"])
    func dirtyFailureAndCancelRetainDestinationHistoryAndBaseline(policy: String) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore", project: ScoreProject(title: "A", duration: 20, events: [TabEvent(time: 2, lane: .left, string: 5)]))
        let b = try f.document("B.roughscore")
        let invalid = f.root.appendingPathComponent("invalid.roughscore"); try Data("not JSON".utf8).write(to: invalid)
        var unsupported = ScoreProject(duration: 20); unsupported.version = 99
        let schema = try f.document("schema.roughscore", project: unsupported)
        let badPackage = f.root.appendingPathComponent("invalid.roughscorepkg"); try FileManager.default.createDirectory(at: badPackage, withIntermediateDirectories: false)
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.select(w.project.events[0]); w.updateSelected { $0.memo = "unsaved" }
        let before = w.project, identity = w.editorIdentity, selected = w.selectedID
        let disk = try Data(contentsOf: a)
        f.capture.decision = policy == "cancel" ? .cancel : policy.hasPrefix("save") ? .saveAndContinue : .discard
        f.capture.failSave = policy == "save-failure"
        // A loaded project has a save location; remove it only for the save-panel cancel case.
        if policy == "save-cancel" {
            let new = Workspace(services: try f.services()); defer { new.shutdown() }
            new.project = before; new.dirty = true
            let intake = ExternalProjectIntake()
            // Queue to bind without automatic startup, but use a normal dirty owner.
            #expect(intake.receive([b]) == .queued); intake.bind(new)
            #expect(intake.lastCompletion == .notOpened && !new.busy && new.project == before && new.dirty)
            #expect(new.activeProjectURL == nil)
        } else {
            let target = policy == "discard-invalid" ? invalid : policy == "discard-invalid-schema" ? schema : policy == "discard-invalid-package" ? badPackage : b
            d.application(NSApplication.shared, open: [target])
            if let task = d.externalProjects.task { #expect(!(await task.value)) }
            #expect(w.project == before && w.editorIdentity == identity && w.activeProjectURL == a)
            #expect(w.selectedID == selected && w.dirty && w.canUndo && !w.canRedo)
            #expect(try Data(contentsOf: a) == disk)
            w.undoEdit(); #expect(w.selected?.memo == "" && !w.dirty)
        }
    }

    @Test(arguments: ["second-request", "mutation", "mutation-restored", "shutdown", "termination"])
    func modalReentryCannotBorrowDiscardAuthorization(action: String) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore"), b = try f.document("B.roughscore"), c = try f.document("C.roughscore")
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 2, string: 5)
        let before = w.project
        f.capture.onDecision = {
            switch action {
            case "second-request": d.application(NSApplication.shared, open: [c])
            case "mutation": w.project.title = "reentrant changed"
            case "mutation-restored": w.project.title = "temporary"; w.project = before
            case "shutdown": w.shutdown()
            default:
                f.capture.onDecision = nil; f.capture.decision = .cancel
                #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            }
        }
        d.application(NSApplication.shared, open: [b])
        if action == "second-request" {
            #expect(await d.externalProjects.task?.value == true)
            #expect(w.activeProjectURL == b && f.capture.remembered == [a, b] && w.externalOpenError != nil)
        } else {
            #expect(d.externalProjects.task == nil && w.activeProjectURL == a && w.dirty)
            #expect(f.capture.remembered == [a])
        }
        #expect(f.capture.prompts == (action == "termination" ? 2 : 1))
    }

    @Test(arguments: [false, true])
    func saveSuccessAllowsExactStorageRebaseButRejectsRememberCallbackMutation(mutate: Bool) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let b = try f.document("B.roughscore"), destination = f.root.appendingPathComponent("saved.roughscore")
        let w = Workspace(services: try f.services()), intake = ExternalProjectIntake(); defer { w.shutdown() }
        w.project = ScoreProject(title: "unsaved", duration: 20); w.addEvent(time: 2, string: 3)
        let before = w.project
        f.capture.decision = .saveAndContinue; f.capture.saveDestination = destination
        if mutate { f.capture.onRemember = { w.project.title = "changed after save" } }
        #expect(intake.receive([b]) == .queued); intake.bind(w)
        if mutate {
            #expect(intake.task == nil && w.activeProjectURL == destination && w.project.title == "changed after save")
        } else {
            #expect(await intake.task?.value == true && w.activeProjectURL == b)
        }
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: destination)) == before)
    }

    @Test func savePanelReentryRejectsSecondRequestAndKeepsCancelledWork() throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let b = try f.document("B.roughscore"), c = try f.document("C.roughscore")
        let w = Workspace(services: try f.services()), intake = ExternalProjectIntake(); defer { w.shutdown() }
        w.addEvent(time: 2, string: 5); let before = w.project
        f.capture.decision = .saveAndContinue
        f.capture.onSave = { #expect(intake.receive([c]) == .rejected) }
        #expect(intake.receive([b]) == .queued); intake.bind(w)
        #expect(w.project == before && w.dirty && w.canUndo && w.activeProjectURL == nil && intake.task == nil)
    }

    @Test(arguments: ["analysis", "export-sheet", "native-modal", "save-panel", "normal-load"])
    func busyWorkRejectsWithoutPreemption(kind: String) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore"), b = try f.document("B.roughscore")
        let gate = IntakeReadGate(); var s = try f.services()
        s.readProject = { url in url == b ? try await gate.read(url) : try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) }
        let (w, d) = try await f.cold(a, services: s); defer { w.shutdown() }
        let before = w.project, identity = w.editorIdentity
        switch kind {
        case "analysis": w.analyzing = true
        case "export-sheet": w.beginExport(.tab)
        case "native-modal": f.capture.modal = true
        case "save-panel":
            // An unsaved owner runs its actual save reservation, while intake has no request yet.
            let new = Workspace(services: try f.services()); defer { new.shutdown() }
            let intake = ExternalProjectIntake()
            f.capture.onSave = { #expect(intake.receive([b]) == .rejected) }
            intake.bind(new) // Lifecycle starts; cancel automatic before testing the save modal.
            new.cancelLoading(); new.save()
            #expect(intake.lastRejection != nil && !new.busy)
            return
        default:
            let task = try #require(w.loadProject(at: b)); await gate.started(b)
            d.application(NSApplication.shared, open: [a])
            #expect(d.externalProjects.task == nil && w.busy && w.project == before)
            await gate.finish(b, ScoreProject(title: "normal B", duration: 20)); #expect(await task.value)
            return
        }
        d.application(NSApplication.shared, open: [b])
        #expect(d.externalProjects.task == nil && w.project == before && w.editorIdentity == identity)
        #expect(f.capture.remembered == [a] && f.capture.prompts == 0 && w.externalOpenError != nil)
        w.analyzing = false; w.cancelExport()
    }

    @Test(arguments: ["cancel", "failure", "success"])
    func dragPreviewIsPreservedUntilAuthorizationAndNeverCommitted(result: String) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let note = TabEvent(time: 2, lane: .left, string: 5)
        let a = try f.document("A.roughscore", project: ScoreProject(duration: 20, events: [note])), b = try f.document("B.roughscore")
        let bad = f.root.appendingPathComponent("bad.roughscore"); try Data("invalid".utf8).write(to: bad)
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.select(note); w.updateSelected { $0.memo = "dirty" }
        let before = w.project
        w.beginPositionDrag(w.selected!); w.previewPositionDrag(time: 9, string: 3, snap: false)
        let preview = w.positionDrag
        f.capture.decision = result == "cancel" ? .cancel : .discard
        d.application(NSApplication.shared, open: [result == "failure" ? bad : b])
        if let task = d.externalProjects.task { #expect(await task.value == (result == "success")) }
        if result == "cancel" { #expect(w.positionDrag == preview && w.project == before) }
        else { #expect(w.positionDrag == nil) }
        if result == "failure" { #expect(w.project == before && w.selectedID == note.id && w.canUndo) }
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: a)).events[0].time == 2)
    }

    @Test func collectedOfflineAndUnicodeUppercaseLinkedUseValidatedReaders() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let project = ScoreProject(title: "오프라인", audioPath: f.root.appendingPathComponent("missing.caf").path, duration: 20)
        let linked = try f.document("공백 café.ROUGHScore", project: project)
        let (w, d) = try await f.cold(linked); defer { w.shutdown() }
        #expect(w.project == project && w.prepared == nil && !w.playing && !w.isDemo)
        let package = f.root.appendingPathComponent("수집.ROUGHScorePKG")
        _ = try PortableProjectPackage.collect(ScoreProject(title: "package", duration: 20), to: package)
        d.application(NSApplication.shared, open: [package])
        #expect(await d.externalProjects.task?.value == true)
        #expect(w.currentPackageURL == package && w.project.title == "package")
    }

    @Test func successfulNativeLoadPausesPlayersRestoresBoundedSessionAndRejectsSameUUIDActions() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let audio = f.root.appendingPathComponent("generated.caf"); try StreamingCacheFixture.write(audio, seconds: 2, channels: 2)
        let note = TabEvent(time: 1, lane: .left, string: 5, fret: 3)
        let a = try f.document("A.roughscore", project: ScoreProject(title: "A", duration: 2, events: [note]))
        let project = ScoreProject(title: "B", audioPath: audio.path, duration: 2, events: [note])
        let b = try f.document("B.roughscore", project: project)
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        let host = NotePointerTests.Host(WorkspaceView(workspace: w), height: 900, width: 1440); defer { host.close() }
        let stale = try #require(NoteAccessibility.actions(note.id, workspace: w).first?.1)
        let identity = w.editorIdentity
        var session = WorkspaceSession(); session.cursor = 100; session.windowStart = 100; session.rate = 9
        try WorkspaceSessionStore.files(at: f.root.appendingPathComponent("sessions")).write(session, b, project)
        d.application(NSApplication.shared, open: [b]); #expect(await d.externalProjects.task?.value == true)
        host.settle()
        #expect(w.editorIdentity != identity && w.prepared != nil && !w.playing)
        #expect(w.cursor <= 2 && w.windowStart <= 2 && w.rate == 1)
        #expect(w.selectedID == nil && !w.canUndo && !w.canRedo && !w.inspectorVisible && !stale())
        #expect(f.capture.remembered == [a, b])
    }

    @Test func shutdownClearsQueuedAndLateRequestsAndReplacementCannotDrain() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore")
        let queued = ExternalProjectIntake(); #expect(queued.receive([a]) == .queued); queued.shutdown()
        let w = Workspace(services: try f.services(), awaitsStartup: true); defer { w.shutdown() }
        queued.bind(w); #expect(!queued.hasPendingRequest && queued.receive([a]) == .rejected && w.busy)
        let gate = IntakeReadGate(); var s = try f.services(); s.readProject = { try await gate.read($0) }
        let d = AppDelegate(), live = Workspace(services: s, awaitsStartup: true)
        var shown = 0
        d.application(NSApplication.shared, open: [a]); d.bind(live, showMainWindow: { shown += 1 })
        let task = try #require(d.externalProjects.task); await gate.started(a)
        d.externalProjects.beginTermination()
        d.application(NSApplication.shared, open: [a])
        #expect(shown == 0)
        d.externalProjects.cancelTermination()
        live.shutdown(); await gate.finish(a, ScoreProject(title: "late", duration: 20))
        #expect(!(await task.value) && d.externalProjects.receive([a]) == .rejected && f.capture.remembered.isEmpty)
        d.application(NSApplication.shared, open: [a]); #expect(shown == 0)
        let replacement = Workspace(services: try f.services(), awaitsStartup: true); defer { replacement.shutdown() }
        d.bind(replacement); #expect(replacement.busy && replacement.activeProjectURL == nil)
    }

    @Test func exportRenderAndDestinationReentryRejectNativeRequestsWithoutCancellingExport() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore"), b = try f.document("B.roughscore")
        let d = AppDelegate(); var s = try f.services()
        let output = f.root.appendingPathComponent("tab.txt")
        var destinationCalls = 0
        s.exportServices.chooseDestination = { _, _ in
            destinationCalls += 1; d.application(NSApplication.shared, open: [b]); return output
        }
        let w = Workspace(services: s, awaitsStartup: true); defer { w.shutdown() }
        d.application(NSApplication.shared, open: [a]); d.bind(w); #expect(await d.externalProjects.task?.value == true)
        let original = w.project
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        let duringRender = Task { @MainActor in
            #expect(w.exportBusy)
            d.application(NSApplication.shared, open: [b])
            #expect(d.externalProjects.task == nil && w.exportBusy && w.exportSnapshot?.id == snapshot.id)
        }
        #expect(await w.completeExport(snapshot, options: .init()))
        await duringRender.value
        #expect(destinationCalls == 1 && FileManager.default.fileExists(atPath: output.path))
        #expect(w.project == original && w.activeProjectURL == a && !w.exportBusy && f.capture.remembered == [a])
    }

    @Test(arguments: [false, true], [false, true])
    func nativeMemoCaretMarkedTextAndUndoSurviveCancelledOrFailedOpen(failure: Bool, marked: Bool) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let note = TabEvent(time: 2, lane: .left, string: 5)
        let a = try f.document("A.roughscore", project: ScoreProject(duration: 20, events: [note]))
        let target = f.root.appendingPathComponent("bad.roughscore"); try Data("invalid".utf8).write(to: target)
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.select(note)
        let host = NotePointerTests.Host(NoteInspector(workspace: w), height: 900, width: 290); defer { host.close() }
        let editor = try #require(host.descendants().compactMap { $0 as? MemoTextView }.first)
        #expect(host.window.makeFirstResponder(editor))
        editor.history.groupsByEvent = false
        f.capture.nativeUndo = NativeTextUndoTarget(editor.history, editor: editor)
        editor.history.beginUndoGrouping(); editor.insertText("native memo", replacementRange: NSRange(location: 0, length: 0)); editor.history.endUndoGrouping()
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        if marked {
            editor.history.beginUndoGrouping()
            editor.setMarkedText("조합", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 2))
            editor.history.endUndoGrouping()
        }
        host.settle()
        let before = w.project, range = editor.selectedRange(), text = editor.string, identity = w.editorIdentity
        var focuses = 0; w.requestKeyboardFocus = { focuses += 1 }
        f.capture.decision = failure ? .discard : .cancel
        d.application(NSApplication.shared, open: [target])
        if let task = d.externalProjects.task { #expect(!(await task.value)) }
        host.settle()
        #expect(w.project == before && w.editorIdentity == identity && w.activeProjectURL == a && w.dirty)
        #expect(editor.string == text && editor.selectedRange() == range && editor.hasMarkedText() == marked)
        #expect(editor.history.canUndo && host.window.firstResponder === editor && focuses == 0)
        if !marked { w.performUndo(); #expect(editor.string == "" && w.selected?.memo == "") }
    }

    @Test func saveAndContinueRebasesDemoAudioThroughTheOrdinaryWriterBeforeOpening() async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let audio = f.root.appendingPathComponent("generated-demo.caf")
        try StreamingCacheFixture.write(audio, seconds: 6, channels: 2)
        let generatedBytes = try Data(contentsOf: audio)
        let incoming = try f.document("B.roughscore"), destination = f.root.appendingPathComponent("saved-demo.roughscore")
        var s = try f.services(); s.createDemo = { _ in audio }
        let w = Workspace(services: s); defer { w.shutdown() }
        #expect(await w.loadDemo()?.value == true && w.isDemo)
        w.addEvent(time: 1, string: 5)
        let events = w.project.events
        f.capture.decision = .saveAndContinue; f.capture.saveDestination = destination
        let intake = ExternalProjectIntake(); #expect(intake.receive([incoming]) == .queued); intake.bind(w)
        #expect(await intake.task?.value == true && w.activeProjectURL == incoming)
        let saved = try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: destination))
        let savedAudio = URL(fileURLWithPath: try #require(saved.audioPath))
        #expect(saved.events == events && savedAudio != audio && saved.originalAsset?.reference.path == savedAudio.path)
        #expect(try Data(contentsOf: savedAudio) == generatedBytes)
    }

    @Test(arguments: [false, true])
    func coordinatorShutdownOrOwnerReplacementCancelsInFlightWithoutLateCommit(replace: Bool) async throws {
        let f = try IntakeFixture(); defer { f.clean() }
        let a = try f.document("A.roughscore")
        let gate = IntakeReadGate(); var s = try f.services(); s.readProject = { try await gate.read($0) }
        let w = Workspace(services: s, awaitsStartup: true), intake = ExternalProjectIntake(); defer { w.shutdown() }
        #expect(intake.receive([a]) == .queued); intake.bind(w)
        let task = try #require(intake.task); await gate.started(a)
        let other = Workspace(services: try f.services(), awaitsStartup: true); defer { other.shutdown() }
        if replace { intake.bind(other) } else { intake.shutdown() }
        await gate.finish(a, ScoreProject(title: "late A", duration: 20))
        #expect(!(await task.value) && w.activeProjectURL == nil && !w.busy)
        #expect(other.activeProjectURL == nil && other.busy && f.capture.remembered.isEmpty)
        #expect(intake.receive([a]) == .rejected)
    }
}
