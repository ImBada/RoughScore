import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor private final class R1Capture {
    var remembered: [URL] = []
    var decision: DiscardDecision = .discard
    var onDecision: (() -> Void)?
    var onSession: (() -> Void)?
    var prompts = 0
    var demos = 0
}

@MainActor private struct R1Fixture {
    let root: URL
    let capture = R1Capture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("issue18-independent-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func document(_ name: String, project: ScoreProject) throws -> URL {
        let url = root.appendingPathComponent(name)
        try JSONEncoder().encode(project).write(to: url)
        return url
    }
    func services() -> WorkspaceServices {
        var s = WorkspaceServices.cachedLive(environment: nil)
        s.initialProject = { nil }; s.lastProject = { nil }
        s.rememberProject = { capture.remembered.append($0) }
        s.createDemo = { _ in await MainActor.run { capture.demos += 1 }; throw AudioIssue.unavailable }
        s.nativeModalActive = { false }; s.nativeTextUndo = { nil }
        s.chooseSaveDestination = { _ in nil }
        s.discardDecision = { capture.prompts += 1; capture.onDecision?(); return capture.decision }
        s.sessionStore = .init(read: { _, _ in nil }, write: { _, _, _ in
            let action = capture.onSession; capture.onSession = nil; action?()
        })
        return s
    }
    func cold(_ url: URL) async throws -> (Workspace, AppDelegate) {
        let w = Workspace(services: services(), awaitsStartup: true), d = AppDelegate()
        d.application(NSApplication.shared, open: [url]); d.bind(w)
        #expect(await d.externalProjects.task?.value == true)
        w.flushSession()
        return (w, d)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite(.serialized)
struct Issue18IndependentR1Probes {
    @Test func exactLinkedModelAndCollectedModelSurviveNativeActivation() async throws {
        let f = try R1Fixture(); defer { f.clean() }
        let note = TabEvent(time: 1.234567891, lane: .right, string: 2, fret: 13)
        var project = ScoreProject(title: "R1 독립 café", duration: 20, events: [note])
        project.events[0].memo = "memo\nUnicode 한글"
        let linked = try f.document("R1.ROUGHScore", project: project)
        let (w, d) = try await f.cold(linked); defer { w.shutdown() }
        #expect(w.project == project && !w.dirty && !w.playing)
        let package = f.root.appendingPathComponent("R1.roughscorepkg")
        let snapshot = try PortableProjectPackage.collect(project, to: package)
        d.application(NSApplication.shared, open: [package])
        #expect(await d.externalProjects.task?.value == true)
        #expect(w.project == snapshot.project && w.project.events[0].id == note.id)
        #expect(w.project.events[0].time == note.time && w.project.events[0].lane == .right)
        #expect(w.currentPackageURL == package && !w.playing)
    }

    @Test func invalidColdContentDoesNotResumeAutomaticStartup() async throws {
        let f = try R1Fixture(); defer { f.clean() }
        let bad = f.root.appendingPathComponent("bad.roughscore")
        try Data("not a project".utf8).write(to: bad)
        let d = AppDelegate(), w = Workspace(services: f.services(), awaitsStartup: true); defer { w.shutdown() }
        let before = w.project, identity = w.editorIdentity
        d.application(NSApplication.shared, open: [bad]); d.bind(w)
        #expect(await d.externalProjects.task?.value == false)
        #expect(w.project == before && w.editorIdentity == identity && w.activeProjectURL == nil)
        #expect(!w.busy && w.start() == nil && f.capture.demos == 0 && f.capture.remembered.isEmpty)
    }

    @Test(arguments: [false, true])
    func promptMutationEvenWhenRestoredRejectsAuthorization(restored: Bool) async throws {
        let f = try R1Fixture(); defer { f.clean() }
        let a = try f.document("A.roughscore", project: ScoreProject(title: "A", duration: 20))
        let b = try f.document("B.roughscore", project: ScoreProject(title: "B", duration: 20))
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1, string: 5); let before = w.project
        f.capture.onDecision = { w.project.title = "changed during prompt"; if restored { w.project = before } }
        d.application(NSApplication.shared, open: [b])
        #expect(d.externalProjects.task == nil && w.activeProjectURL == a && w.dirty)
        #expect(f.capture.remembered == [a] && f.capture.prompts == 1)
    }

    // Load reservation has a synchronous session persistence callback after the
    // new external authorization guard. Exercise that exact gap without changing product code.
    @Test(arguments: ["model", "shutdown", "termination-cancel"])
    func reservationSessionReentryMustNotConsumeStaleAuthorization(action: String) async throws {
        let f = try R1Fixture(); defer { f.clean() }
        let a = try f.document("A.roughscore", project: ScoreProject(title: "A", duration: 20))
        let b = try f.document("B.roughscore", project: ScoreProject(title: "B", duration: 20))
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1, string: 5); w.cursor = 1
        f.capture.onSession = {
            switch action {
            case "model": w.updateSelected { $0.memo = "new edit after Discard authorization" }
            case "shutdown": w.shutdown()
            default:
                f.capture.decision = .cancel
                #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            }
        }
        d.application(NSApplication.shared, open: [b])
        if let task = d.externalProjects.task { _ = await task.value }
        print("R1 reservation action=\(action) active=\(w.activeProjectURL?.lastPathComponent ?? "nil") title=\(w.project.title) busy=\(w.busy) closed=\(w.isClosed) remembered=\(f.capture.remembered.map(\.lastPathComponent))")
        #expect(w.activeProjectURL == a)
        #expect(f.capture.remembered == [a])
        #expect(!w.busy)
        if action == "model" { #expect(w.project.events.first?.memo == "new edit after Discard authorization" && w.dirty) }
    }

    @Test func ordinarySaveSessionABAMutationInvalidatesReceipt() async throws {
        let f = try R1Fixture(); defer { f.clean() }
        let a = try f.document("A.roughscore", project: ScoreProject(title: "A", duration: 20))
        let b = try f.document("B.roughscore", project: ScoreProject(title: "B", duration: 20))
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1, string: 5); w.cursor = 1
        let before = w.project
        f.capture.decision = .saveAndContinue
        f.capture.onSession = { w.project.title = "temporary session mutation"; w.project = before }
        d.application(NSApplication.shared, open: [b])
        #expect(d.externalProjects.task == nil && w.activeProjectURL == a && w.project == before && w.dirty)
        #expect(f.capture.remembered == [a])
    }
}
