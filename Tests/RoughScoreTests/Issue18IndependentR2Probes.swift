import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor private final class R2Capture {
    var remembered: [URL] = []
    var decision: DiscardDecision = .discard
    var prompts = 0
    var modal = false
    var onSession: (() -> Void)?
    var onModal: (() -> Void)?
    var onRemember: (() -> Void)?
}
@MainActor private struct R2Fixture {
    let root: URL
    let capture = R2Capture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("issue18-independent-r2-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func document(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".roughscore")
        try JSONEncoder().encode(ScoreProject(title: name, duration: 20)).write(to: url)
        return url
    }
    func services() -> WorkspaceServices {
        var s = WorkspaceServices.cachedLive(environment: nil)
        s.initialProject = { nil }; s.lastProject = { nil }
        s.rememberProject = { capture.remembered.append($0); capture.onRemember?() }
        s.nativeTextUndo = { nil }
        s.nativeModalActive = {
            let action = capture.onModal; capture.onModal = nil; action?()
            return capture.modal
        }
        s.discardDecision = { capture.prompts += 1; return capture.decision }
        s.chooseSaveDestination = { _ in nil }
        s.sessionStore = .init(read: { _, _ in nil }, write: { _, _, _ in
            let action = capture.onSession; capture.onSession = nil; action?()
        })
        return s
    }
    func cold(_ a: URL) async throws -> (Workspace, AppDelegate) {
        let w = Workspace(services: services(), awaitsStartup: true), d = AppDelegate()
        d.application(NSApplication.shared, open: [a]); d.bind(w)
        #expect(await d.externalProjects.task?.value == true)
        w.flushSession()
        return (w, d)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite(.serialized)
struct Issue18IndependentR2Probes {
    // Exercise both session persistence and the new nativeModalActive predicate
    // callback after currentSession capture, on the actual delegate/intake route.
    @Test(arguments: ["session", "modal-query"], ["model-aba", "shutdown", "termination-cancel", "analysis", "export", "modal"])
    func reservationMustRecheckAllLiveEligibilityAndOwnership(boundary: String, action: String) async throws {
        let f = try R2Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B")
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1.234567891, string: 5)
        w.cursor = 1
        let before = w.project, identity = w.editorIdentity
        var callbackRan = false
        let callback = {
            callbackRan = true
            switch action {
            case "model-aba": w.project.title = "temporary"; w.project = before
            case "shutdown": w.shutdown()
            case "termination-cancel":
                f.capture.decision = .cancel
                #expect(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            case "analysis": w.analyzing = true
            case "export":
                w.beginExport(.tab)
                #expect(w.exportSnapshot?.projectID == identity)
            default: f.capture.modal = true
            }
        }
        if boundary == "session" { f.capture.onSession = callback }
        else { f.capture.onSession = { f.capture.onModal = callback } }
        d.application(NSApplication.shared, open: [b])
        if let task = d.externalProjects.task { _ = await task.value }
        print("R2 reservation boundary=\(boundary) action=\(action) callback=\(callbackRan) active=\(w.activeProjectURL?.lastPathComponent ?? "nil") busy=\(w.busy) closed=\(w.isClosed) export=\(w.exportSnapshot != nil) remembered=\(f.capture.remembered.map(\.lastPathComponent))")
        #expect(callbackRan)
        #expect(w.activeProjectURL == a && w.editorIdentity == identity && w.project == before)
        #expect(f.capture.remembered == [a] && !w.busy)
        if action == "export" { #expect(w.exportSnapshot?.projectID == identity) }
        w.analyzing = false; w.cancelExport()
    }

    @Test func reservationSecondNativeRequestCannotStealTheOriginalSlot() async throws {
        let f = try R2Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B"), c = try f.document("C")
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1, string: 5); w.cursor = 1
        var received = false
        f.capture.onSession = {
            received = true
            #expect(d.externalProjects.receive([c]) == .rejected)
        }
        d.application(NSApplication.shared, open: [b])
        #expect(await d.externalProjects.task?.value == true)
        #expect(received && w.activeProjectURL == b && f.capture.remembered == [a, b])
        #expect(!w.busy && d.externalProjects.lastCompletion == .opened && w.externalOpenError != nil)
    }

    @Test func ownerReplacementInsideReservationCannotMigrateOrReviveRequest() async throws {
        let f = try R2Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B")
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        let other = Workspace(services: f.services(), awaitsStartup: true); defer { other.shutdown() }
        w.addEvent(time: 1, string: 5); w.cursor = 1
        let before = w.project
        var shows = 0
        d.showMainWindow = { shows += 1 }
        f.capture.onSession = { d.bind(other) }
        d.application(NSApplication.shared, open: [b])
        #expect(d.externalProjects.task == nil && w.activeProjectURL == a && w.project == before && !w.busy)
        #expect(other.activeProjectURL == nil && other.busy && shows == 0)
        #expect(f.capture.remembered == [a] && d.externalProjects.receive([b]) == .rejected)
    }

    @Test func saveReceiptRejectsRestoredValueMutationAfterRememberCallback() async throws {
        let f = try R2Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B")
        let (w, d) = try await f.cold(a); defer { w.shutdown() }
        w.addEvent(time: 1.234567891, string: 5)
        let before = w.project, identity = w.editorIdentity
        f.capture.decision = .saveAndContinue
        var changed = false
        f.capture.onRemember = {
            changed = true
            w.project.title = "temporary"; w.project = before
        }
        d.application(NSApplication.shared, open: [b])
        #expect(changed && d.externalProjects.task == nil && w.activeProjectURL == a && w.editorIdentity == identity && w.project == before)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: a)) == before)
        #expect(f.capture.remembered == [a, a] && !w.busy)
    }
}

