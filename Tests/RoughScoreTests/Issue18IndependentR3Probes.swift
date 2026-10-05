import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

private actor R3ReadGate {
    var continuation: CheckedContinuation<ScoreProject, any Error>?
    var waiter: CheckedContinuation<Void, Never>?
    func read() async throws -> ScoreProject {
        try await withCheckedThrowingContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ succeeds: Bool) {
        if succeeds { continuation!.resume(returning: ScoreProject(title: "B", duration: 20)) }
        else { continuation!.resume(throwing: CocoaError(.fileReadCorruptFile)) }
        continuation = nil
    }
}
@MainActor private final class R3Capture {
    var remembered: [URL] = []
    var decision: DiscardDecision = .discard
    var onDecision: (() -> Void)?
    var onSave: (() -> Void)?
}
@MainActor private struct R3Fixture {
    let root: URL
    let capture = R3Capture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("issue18-r3-owned-" + UUID().uuidString)
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
        s.rememberProject = { capture.remembered.append($0) }
        s.sessionStore = .init(read: { _, _ in nil }, write: { _, _, _ in })
        s.nativeTextUndo = { nil }; s.nativeModalActive = { false }
        s.discardDecision = { capture.onDecision?(); return capture.decision }
        s.chooseSaveDestination = { _ in capture.onSave?(); return nil }
        s.createDemo = { _ in throw AudioIssue.unavailable }
        return s
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
@MainActor @Suite(.serialized)
struct Issue18IndependentR3Probes {
    @Test(arguments: [false, true])
    func earlierRejectionClearsAtColdAdmissionButNewDuplicateSurvivesBind(content: Bool) async throws {
        let f = try R3Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B")
        let d = AppDelegate()
        if content {
            let w = Workspace(services: f.services(), awaitsStartup: true)
            d.application(NSApplication.shared, open: [a]); d.bind(w)
            #expect(await d.externalProjects.task?.value == true)
            w.shutdown()
            // Use a new native intake owner for the prebinding structural rejection below.
        }
        let intake = ExternalProjectIntake()
        #expect(intake.receive([a, b]) == .rejected && intake.lastRejection != nil)
        #expect(intake.receive([a]) == .queued && intake.lastRejection == nil)
        #expect(intake.receive([b]) == .rejected)
        let rejection = try #require(intake.lastRejection)
        let w = Workspace(services: f.services(), awaitsStartup: true); defer { w.shutdown() }
        intake.bind(w)
        #expect(w.externalOpenError == rejection)
        #expect(await intake.task?.value == true)
        #expect(w.externalOpenError == rejection && intake.lastRejection == rejection && w.activeProjectURL == a)
    }

    @Test(arguments: [false, true], [false, true])
    func laterDuplicateFeedbackOwnsBannerAfterEarlierLoadCompletes(warm: Bool, succeeds: Bool) async throws {
        let f = try R3Fixture(); defer { f.clean() }
        let a = try f.document("A"), b = try f.document("B"), c = try f.document("C")
        let gate = R3ReadGate(); var s = f.services()
        s.readProject = { url in
            if url == b { return try await gate.read() }
            return try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url))
        }
        let d = AppDelegate(), w = Workspace(services: s, awaitsStartup: true); defer { w.shutdown() }
        if warm {
            d.application(NSApplication.shared, open: [a]); d.bind(w)
            #expect(await d.externalProjects.task?.value == true)
            d.application(NSApplication.shared, open: [b])
        } else {
            d.application(NSApplication.shared, open: [b])
            #expect(d.externalProjects.receive([c]) == .rejected)
            d.bind(w)
        }
        let task = try #require(d.externalProjects.task)
        await gate.started()
        #expect(d.externalProjects.receive([c]) == .rejected)
        let rejection = try #require(d.externalProjects.lastRejection)
        #expect(w.externalOpenError == rejection)
        await gate.finish(succeeds)
        #expect(await task.value == succeeds)
        print("R3 feedback warm=\(warm) succeeds=\(succeeds) rejection=\(rejection) banner=\(w.externalOpenError ?? "nil")")
        #expect(w.externalOpenError == rejection)
        #expect(d.externalProjects.lastRejection == rejection)
        #expect(w.activeProjectURL == (succeeds ? b : warm ? a : nil))
        #expect(f.capture.remembered == (succeeds ? warm ? [a, b] : [b] : warm ? [a] : []))
    }

    @Test(arguments: [false, true])
    func rejectedReentrantRequestKeepsFeedbackThroughCurrentPromptCancellation(save: Bool) async throws {
        let f = try R3Fixture(); defer { f.clean() }
        let b = try f.document("B"), c = try f.document("C")
        let w = Workspace(services: f.services()), d = AppDelegate(); defer { w.shutdown() }
        w.addEvent(time: 1.234567891, string: 5)
        let before = w.project
        f.capture.decision = save ? .saveAndContinue : .cancel
        let callback = { #expect(d.externalProjects.receive([c]) == .rejected) }
        if save { f.capture.onSave = callback } else { f.capture.onDecision = callback }
        d.application(NSApplication.shared, open: [b]); d.bind(w)
        #expect(d.externalProjects.task == nil && d.externalProjects.lastCompletion == .notOpened)
        #expect(w.project == before && w.dirty && w.canUndo && w.activeProjectURL == nil)
        #expect(w.externalOpenError != nil && w.externalOpenError == d.externalProjects.lastRejection)
    }
}
