import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor private final class ClockCapture {
    var afterSession: (() -> Void)?
    var onClock: (() -> Void)?
    var remembered: [URL] = []
}
@MainActor private final class ClockObservedPlayer: AudioPlayerTransport {
    let base: any AudioPlayerTransport
    let capture: ClockCapture
    init(_ base: any AudioPlayerTransport, _ capture: ClockCapture) { self.base = base; self.capture = capture }
    var currentTime: TimeInterval {
        get {
            let action = capture.onClock; capture.onClock = nil; action?()
            return base.currentTime
        }
        set { base.currentTime = newValue }
    }
    var rate: Float { get { base.rate } set { base.rate = newValue } }
    var volume: Float { get { base.volume } set { base.volume = newValue } }
    var enableRate: Bool { get { base.enableRate } set { base.enableRate = newValue } }
    var isPlaying: Bool { base.isPlaying }
    var deviceCurrentTime: TimeInterval { base.deviceCurrentTime }
    var sharedClockID: UUID? { base.sharedClockID }
    func clockSnapshot() -> PlaybackClockSnapshot {
        return base.clockSnapshot()
    }
    func play(atTime time: TimeInterval) -> Bool { base.play(atTime: time) }
    func prepareToPlay() -> Bool { base.prepareToPlay() }
    func play() -> Bool { base.play() }
    func pause() { base.pause() }
    func stop() { base.stop() }
}
@MainActor @Suite(.serialized)
struct Issue18IndependentR2ClockProbes {
    @Test(arguments: ["model-aba", "shutdown"])
    func currentSessionClockCallbackCannotInvalidateCapturedAuthorization(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue18-r2-clock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("generated.caf")
        try StreamingCacheFixture.write(audio, seconds: 2, channels: 2)
        let a = root.appendingPathComponent("A.roughscore"), b = root.appendingPathComponent("B.roughscore")
        try JSONEncoder().encode(ScoreProject(title: "A", audioPath: audio.path, duration: 2)).write(to: a)
        try JSONEncoder().encode(ScoreProject(title: "B", duration: 2)).write(to: b)
        let capture = ClockCapture()
        var services = WorkspaceServices.cachedLive(environment: try AudioCacheEnvironment(configuration: .init(root: root.appendingPathComponent("cache"))))
        let factory = services.makePlayer
        services.makePlayer = { ClockObservedPlayer(try factory($0, $1), capture) }
        services.initialProject = { nil }; services.lastProject = { nil }
        services.rememberProject = { capture.remembered.append($0) }
        services.nativeTextUndo = { nil }; services.nativeModalActive = { false }
        services.discardDecision = { .discard }
        services.sessionStore = .init(read: { _, _ in nil }, write: { _, _, _ in
            let callback = capture.afterSession; capture.afterSession = nil; callback?()
        })
        let w = Workspace(services: services, awaitsStartup: true), d = AppDelegate()
        defer { w.shutdown() }
        d.application(NSApplication.shared, open: [a]); d.bind(w)
        #expect(await d.externalProjects.task?.value == true && w.prepared != nil)
        w.flushSession()
        w.addEvent(time: 1.234567891, string: 5)
        let before = w.project
        w.cursor = 1
        // Only request a session live-clock sample. Native transports stay paused.
        w.playing = true
        var callbackRan = false
        capture.afterSession = {
            capture.onClock = {
                callbackRan = true
                if action == "shutdown" { w.shutdown() }
                else { w.project.title = "temporary"; w.project = before }
            }
        }
        d.application(NSApplication.shared, open: [b])
        if let task = d.externalProjects.task { _ = await task.value }
        print("R2 currentSession action=\(action) callback=\(callbackRan) active=\(w.activeProjectURL?.lastPathComponent ?? "nil") busy=\(w.busy) closed=\(w.isClosed)")
        #expect(callbackRan && d.externalProjects.task == nil && w.activeProjectURL == a && w.project == before && !w.busy)
        #expect(capture.remembered == [a])
        w.playing = false
    }
}

