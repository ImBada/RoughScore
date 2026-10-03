import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
private final class EngineCapture {
    var players: [URL: AudioEnginePlayer] = [:]
}

@MainActor
struct EngineTransportTests {
    @Test func sharedSourceFailuresKeepTheOldNativeGraphAudibleAndUsable() async throws {
        for mode in [EngineFailureMode.construction, .preparation, .resume] {
            let url = try engineFixture(); defer { try? FileManager.default.removeItem(at: url) }
            let control = EngineFailureControl()
            var services = quietEngineServices()
            let factory = services.makePlayer
            services.makePlayer = { url in
                if url == control.failedURL && control.mode == .construction { throw AudioIssue.playbackFailed }
                let native = try #require(factory(url) as? AudioEnginePlayer)
                control.graph = native.graph
                return FailingEnginePort(native: native, control: control, target: url)
            }
            let w = Workspace(services: services); defer { w.shutdown() }
            let load = try #require(w.loadAudio(at: url)); #expect(await load.value)
            control.failedURL = try #require(w.prepared).left; control.mode = mode
            w.seek(0.5); w.togglePlayback()
            try await Task.sleep(for: .milliseconds(80))
            let project = w.project, state = w.saveState
            w.switchSource(.left)
            #expect(w.source == .stereo && w.playing && w.error != nil)
            #expect(control.graph?.isPlaying == true && control.graph?.nativeGains[.stereo] == 1)
            #expect(w.project == project && w.saveState == state)
            w.togglePlayback(); #expect(!w.playing && w.cursor >= 0.5)
            w.togglePlayback(); #expect(w.playing)
        }
    }

    @Test func twoWorkspacesKeepSeparateGraphsAndShutdownStopsOnlyItsOwner() async throws {
        let url = try engineFixture(); defer { try? FileManager.default.removeItem(at: url) }
        let captureA = EngineCapture(), captureB = EngineCapture()
        let a = Workspace(services: quietEngineServices(capture: captureA))
        let b = Workspace(services: quietEngineServices(capture: captureB))
        defer { a.shutdown(); b.shutdown() }
        #expect(await a.loadAudio(at: url)?.value == true)
        #expect(await b.loadAudio(at: url)?.value == true)
        let graphA = try #require(captureA.players[url]).graph
        let graphB = try #require(captureB.players[url]).graph
        #expect(graphA !== graphB && graphA.id != graphB.id)
        a.seek(0.5); b.seek(1); a.togglePlayback(); b.togglePlayback()
        try await Task.sleep(for: .milliseconds(80))
        a.shutdown()
        #expect(!a.playing && b.playing && !graphA.engine.isRunning && graphB.engine.isRunning)
        let before = b.cursor
        b.switchSource(.left); b.tick()
        #expect(b.playing && b.cursor > before && b.prepared != nil)
    }

    private func quietEngineServices(capture: EngineCapture? = nil) -> WorkspaceServices {
        var services = WorkspaceServices.live
        let factory = services.makePlayer
        services.makePlayer = { url in
            let native = try #require(factory(url) as? AudioEnginePlayer)
            native.graph.engine.mainMixerNode.outputVolume = 0
            capture?.players[url] = native
            return native
        }
        services.lastProject = { nil }; services.rememberProject = { _ in }
        return services
    }

    private func engineFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-engine-state-" + UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 264600)!
        buffer.frameLength = 264600
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 264600) }
        buffer.floatChannelData![0][49833] = 0.8; buffer.floatChannelData![1][51777] = -0.6
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer); file.close()
        return url
    }

    @Test func productionFactoryUsesOneNativeRateRendererAndStreamingClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-engine-" + UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 264600)!
        buffer.frameLength = 264600
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 264600) }
        buffer.floatChannelData![0][49833] = 0.8
        buffer.floatChannelData![1][51777] = -0.6
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer); file.close()
        let capture = EngineCapture()
        var services = WorkspaceServices.live
        let factory = services.makePlayer
        services.makePlayer = { url in
            let player = try #require(factory(url) as? AudioEnginePlayer)
            player.graph.engine.mainMixerNode.outputVolume = 0
            capture.players[url] = player
            return player
        }
        services.lastProject = { nil }; services.rememberProject = { _ in }
        let w = Workspace(services: services); defer { w.shutdown() }
        let load = try #require(w.loadAudio(at: url)); #expect(await load.value)
        let audio = try #require(w.prepared)
        for rate: Float in [0.5, 0.75, 1] {
            w.rate = rate; w.switchSource(.stereo); w.seek(0.5); w.togglePlayback()
            #expect(w.playing)
            try await Task.sleep(for: .milliseconds(150))
            let old = try #require(capture.players[audio.url(for: w.source)])
            let before = old.currentTime
            #expect(before > 0.5)
            for source in [ListeningSource.left, .right, .stereo, .right, .left, .stereo] {
                let previous = old.graph.position
                w.switchSource(source)
                let destination = try #require(capture.players[audio.url(for: source)])
                #expect(destination.graph === old.graph && destination.sharedClockID == old.sharedClockID)
                #expect(w.playing && w.cursor >= previous)
                let snapshot = try #require(destination.graph.inputClockSnapshot())
                let frames = snapshot.playerFrames.values
                #expect(frames.count == 3 && frames.max()! - frames.min()! <= 1)
                for (lane, gain) in destination.graph.nativeGains { #expect(gain == (lane == source ? 1 : 0)) }
                print("Shared engine rate=\(rate) source=\(source) position=\(destination.currentTime) nativeStereo=\(String(describing: destination.graph.nodePosition(.stereo))) nativeLeft=\(String(describing: destination.graph.nodePosition(.left))) nativeRight=\(String(describing: destination.graph.nodePosition(.right)))")
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(old.currentTime > before)
            w.seek(2); w.tick(); w.switchSource(.left)
            #expect(w.cursor >= 2 && w.playing)
            w.togglePlayback()
            #expect(w.cursor >= 2 && !w.playing)
        }
        #expect(capture.players.count == 3)
    }
}

private enum EngineFailureMode { case construction, preparation, resume }
@MainActor private final class EngineFailureControl {
    var failedURL: URL?
    var mode: EngineFailureMode?
    var graph: AudioEngineGraph?
}
@MainActor private final class FailingEnginePort: AudioPlayerTransport {
    let native: AudioEnginePlayer
    let control: EngineFailureControl
    let target: URL
    init(native: AudioEnginePlayer, control: EngineFailureControl, target: URL) {
        self.native = native; self.control = control; self.target = target
    }
    private var fails: Bool { target == control.failedURL }
    var sharedClockID: UUID? { native.sharedClockID }
    var currentTime: Double { get { native.currentTime } set { native.currentTime = newValue } }
    var rate: Float { get { native.rate } set { native.rate = newValue } }
    var volume: Float { get { native.volume } set { native.volume = newValue } }
    var enableRate: Bool { get { native.enableRate } set { native.enableRate = newValue } }
    var isPlaying: Bool { fails && control.mode == .resume ? false : native.isPlaying }
    var deviceCurrentTime: Double { native.deviceCurrentTime }
    func prepareToPlay() -> Bool { fails && control.mode == .preparation ? false : native.prepareToPlay() }
    func play() -> Bool { fails && control.mode == .resume ? false : native.play() }
    func play(atTime time: TimeInterval) -> Bool { fails && control.mode == .resume ? false : native.play(atTime: time) }
    func pause() { native.pause() }
    func stop() { native.stop() }
}
