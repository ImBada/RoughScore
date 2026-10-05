import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

struct AudioTests {
    @Test func realAudioFixtureWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["ROUGH_SCORE_AUDIO_FIXTURE"] else { return }
        let prepared = try await AudioPreparation.prepare(URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let original = try AVAudioPlayer(contentsOf: prepared.original)
        let left = try AVAudioPlayer(contentsOf: prepared.left)
        let right = try AVAudioPlayer(contentsOf: prepared.right)
        #expect(abs(original.duration - prepared.duration) < 0.05)
        #expect(abs(left.duration - prepared.duration) < 0.001)
        #expect(abs(right.duration - prepared.duration) < 0.001)
        #expect(prepared.duration / Double(prepared.leftPeaks.count) <= 0.01001)
        #expect(prepared.leftPeaks.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(prepared.rightPeaks.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect((prepared.leftPeaks.max() ?? 0) > 0.01)
        #expect((prepared.rightPeaks.max() ?? 0) > 0.01)
        let layout = ScoreLayout(duration: prepared.duration)
        #expect(layout.systems.last?.end == prepared.duration)
        print("Real audio: \(prepared.duration)s, \(prepared.leftPeaks.count) bins/channel, \(layout.pageCount) pages before analysis, mono=\(prepared.isMono)")
    }

    @Test func stereoChannelsRemainIndependent() async throws {
        let url = try fixture(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreparation.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(!prepared.isMono)
        #expect(abs(prepared.duration - 1) < 0.001)
        let l = try read(prepared.left), r = try read(prepared.right)
        #expect(abs(l[100] - 0.2) < 0.0001)
        #expect(abs(r[100] + 0.7) < 0.0001)
        #expect(prepared.leftPeaks.max() == 0.2)
        #expect(prepared.rightPeaks.max() == 0.7)
    }

    @Test func monoInputIsClearlyDuplicated() async throws {
        let url = try fixture(channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreparation.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        #expect(prepared.isMono)
        #expect(try read(prepared.left) == read(prepared.right))
    }

    @Test func demoAudioMatchesAnnotatedSides() async throws {
        let url = try AudioPreparation.createDemo()
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreparation.prepare(url)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let left = try read(prepared.left), right = try read(prepared.right)
        let region = Int(2.02 * 44100)..<Int(2.2 * 44100)
        #expect(left[region].map { abs($0) }.max()! > 0.1)
        #expect(right[region].allSatisfy { $0 == 0 })
        #expect(abs(prepared.duration - ScoreProject.demo.duration) < 0.001)
    }

    /// Headless transport/decoded-frame evidence, not an acoustic gap-free or GUI claim.
    @Test @MainActor func realWorkspaceSwitchesUseLiveOriginalSecondsAtAllRates() async throws {
        // This is the healthy, in-flight switch contract, not an EOF cursor test.
        // Other hosted native suites may hold MainActor longer than a four-second clip.
        let url = try impulseFixture(duration: 120)
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = RealPlayerCapture()
        var services = WorkspaceServices.isolatedCache()
        let factory = services.makePlayer
        services.makePlayer = { audio, source in
            let url = audio.url(for: source)
            let native = try #require(factory(audio, source) as? AudioEnginePlayer)
            native.graph.engine.mainMixerNode.outputVolume = 0
            let player = ObservedAVPlayer(native)
            capture.players[url] = player
            capture.constructions += 1
            return player
        }
        services.lastProject = { nil }; services.rememberProject = { _ in }
        let workspace = Workspace(services: services)
        defer { workspace.shutdown() }
        let load = try #require(workspace.loadAudio(at: url))
        #expect(await load.value)
        let prepared = try #require(workspace.prepared)
        let originalLeft = try readChannel(url, channel: 0), originalRight = try readChannel(url, channel: 1)
        let decodedLeft = try read(prepared.left), decodedRight = try read(prepared.right)
        #expect(decodedLeft.count == originalLeft.count)
        #expect(zip(decodedLeft, originalLeft).allSatisfy { $0 == $1 })
        #expect(decodedRight.count == originalRight.count)
        #expect(zip(decodedRight, originalRight).allSatisfy { $0 == $1 })
        #expect(originalLeft[49833] == 0.8 && originalRight[49833] == 0)
        #expect(originalRight[51777] == -0.6 && originalLeft[51777] == 0)
        let project = workspace.project
        var maximumRewind = 0.0
        var maximumPlayerSeekRewind = 0.0
        var maximumSeekReadbackError = 0.0
        var maximumCutoverDifference = 0.0
        var correctiveSeeks = 0
        var healthyGainSwitches = 0
        for rate: Float in [0.5, 0.75, 1] {
            workspace.rate = rate
            workspace.seek(0.5)
            workspace.togglePlayback()
            #expect(workspace.playing)
            for source in [ListeningSource.left, .right, .stereo, .right, .left, .stereo] {
                let old = try #require(capture.players[prepared.url(for: workspace.source)])
                let published = workspace.cursor
                // No UI timer: wait for the scheduled native group to advance beyond the published cursor.
                for _ in 0..<50 {
                    if old.native.deviceCurrentTime >= (old.scheduledEpoch ?? 0) && old.currentTime - published >= 0.04 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let liveBefore = old.currentTime
                #expect(liveBefore < workspace.project.duration)
                #expect(liveBefore - published >= 0.03)
                #expect(old.rate == rate && old.isPlaying)
                let cutover = ActiveClockPair()
                old.beforeVolumeChange = {
                    guard let destination = capture.players[prepared.url(for: source)] else { return }
                    let started = ProcessInfo.processInfo.systemUptime
                    cutover.oldDeviceBefore = old.native.deviceCurrentTime
                    cutover.oldTime = old.native.currentTime
                    cutover.oldDeviceAfter = old.native.deviceCurrentTime
                    cutover.newDeviceBefore = destination.native.deviceCurrentTime
                    cutover.destinationTime = destination.native.currentTime
                    cutover.newDeviceAfter = destination.native.deviceCurrentTime
                    cutover.readElapsed = ProcessInfo.processInfo.systemUptime - started
                }
                let seeksBefore = capture.players[prepared.url(for: source)]?.seekCount
                let readsBefore = capture.players[prepared.url(for: source)]?.readTimes.count ?? 0
                let oldReadsBefore = old.readSamples.count
                let switchStarted = ProcessInfo.processInfo.systemUptime
                workspace.switchSource(source)
                old.beforeVolumeChange = nil
                let destination = try #require(capture.players[prepared.url(for: source)])
                let destinationTime = destination.currentTime
                let switchElapsed = ProcessInfo.processInfo.systemUptime - switchStarted
                maximumPlayerSeekRewind = max(maximumPlayerSeekRewind, liveBefore - destinationTime)
                let rewind = liveBefore - workspace.cursor
                maximumRewind = max(maximumRewind, rewind)
                #expect(rewind < 2 / 44100.0) // allow decoded-frame quantization, not a 30ms tick
                #expect(workspace.source == source && workspace.playing && destination.isPlaying && old.isPlaying && old.volume == 0)
                // Allow backend seek quantization below a UI tick and real time spent inside AV calls.
                #expect(destination.rate == rate && destinationTime >= liveBefore - 0.015)
                #expect(destinationTime <= workspace.cursor + switchElapsed * Double(rate) + 0.015)
                // Aligned channels change gains only. If native rate-renderer phase drifts, the
                // corrective seek must use this OLD live sample, never the published cursor.
                let seek = try #require(destination.lastSeek)
                let readback = try #require(destination.seekReadback)
                let sampledOld = try #require(old.lastLiveRead)
                maximumSeekReadbackError = max(maximumSeekReadbackError, abs(readback - seek))
                print("Pre-guard old=\(old.readSamples[oldReadsBefore]) new=\(destination.readSamples[readsBefore]) oldDevice=\(String(describing: old.lastDeviceRead)) newDevice=\(String(describing: destination.lastDeviceRead)) corrective=\(destination.seekCount != seeksBefore)")
                let oldSample = old.readSamples[oldReadsBefore]
                let newSample = destination.readSamples[readsBefore]
                let projectedMinimum = oldSample.position + max(0, newSample.before - oldSample.after) * Double(rate)
                let projectedMaximum = oldSample.position + max(0, newSample.after - oldSample.before) * Double(rate)
                if newSample.position >= projectedMinimum - 0.015 && newSample.position <= projectedMaximum + 0.015 {
                    healthyGainSwitches += 1
                    #expect(destination.seekCount == seeksBefore)
                }
                if destination.seekCount != seeksBefore {
                    correctiveSeeks += 1
                    #expect(seek == sampledOld)
                }
                #expect(workspace.cursor == sampledOld)
                #expect(abs(readback - seek) <= 1 / 44100.0)
                let oldAtCutover = try #require(cutover.oldTime)
                let newAtCutover = try #require(cutover.destinationTime)
                maximumCutoverDifference = max(maximumCutoverDifference, abs(newAtCutover - oldAtCutover))
                print("Active clock rate=\(rate) source=\(source) seek=\(seek) readback=\(readback) oldAtCutover=\(oldAtCutover) newAtCutover=\(newAtCutover) postResume=\(destinationTime) elapsed=\(switchElapsed) pairReadElapsed=\(cutover.readElapsed) oldDeviceBracket=\(cutover.oldDeviceBefore)..\(cutover.oldDeviceAfter) newDeviceBracket=\(cutover.newDeviceBefore)..\(cutover.newDeviceAfter)")
                #expect(abs(newAtCutover - oldAtCutover) <= 0.015 + cutover.readElapsed * Double(rate))
                #expect(workspace.project == project && !workspace.looping)
            }
            workspace.togglePlayback()
            #expect(!workspace.playing)
        }
        // Actual queued native currentTime can project behind the requested seek. Immediate source
        // changes and pause must retain the pending anchor, including short-loop re-anchors.
        for rate: Float in [0.5, 0.75, 1] {
            workspace.rate = rate
            workspace.seek(0.5); workspace.togglePlayback()
            workspace.seek(2); workspace.tick()
            #expect(workspace.cursor >= 2 && workspace.playing)
            let old = try #require(capture.players[prepared.url(for: workspace.source)])
            print("Pending native rate=\(rate) requested=2 raw=\(old.native.currentTime) device=\(old.native.deviceCurrentTime)")
            workspace.switchSource(.left)
            #expect(workspace.cursor >= 2 && workspace.playing)
            workspace.switchSource(.right)
            #expect(workspace.cursor >= 2 && workspace.playing)
            workspace.seek(1.25); workspace.tick()
            #expect(workspace.cursor >= 1.25 && workspace.playing)
            let changedRate: Float = rate == 1 ? 0.5 : rate == 0.5 ? 0.75 : 1
            workspace.rate = changedRate; workspace.tick()
            #expect(workspace.cursor >= 1.25 && workspace.rate == changedRate && workspace.playing)
            workspace.seek(2.5); workspace.togglePlayback()
            #expect(abs(workspace.cursor - 2.5) < 1 / 44100.0 && !workspace.playing)
            workspace.rate = rate
            workspace.switchSource(.stereo)
            #expect(abs(workspace.cursor - 2.5) < 1 / 44100.0 && !workspace.playing)
            workspace.setLoop(from: 2.5, to: 2.55); workspace.togglePlayback()
            workspace.switchSource(.left); workspace.tick()
            #expect(workspace.looping && workspace.loopStart == 2.5 && workspace.loopEnd == 2.55)
            #expect(workspace.cursor >= 2.5 && workspace.cursor < 2.55 && workspace.playing)
            let loopPlayer = try #require(capture.players[prepared.url(for: workspace.source)])
            for _ in 0..<60 {
                if loopPlayer.native.deviceCurrentTime >= (loopPlayer.scheduledEpoch ?? 0) && loopPlayer.native.currentTime >= workspace.loopEnd { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            workspace.tick() // real native loop boundary re-anchors the production timer path
            #expect(workspace.cursor >= 2.5 && workspace.cursor < 2.55 && workspace.playing)
            workspace.switchSource(.stereo)
            #expect(workspace.cursor >= 2.5 && workspace.cursor < 2.55 && workspace.looping)
            workspace.togglePlayback(); workspace.looping = false
        }
        #expect(capture.constructions == 3 && healthyGainSwitches > 0 && workspace.project == project)
        print("Real Workspace transport: 18 switches at 0.5/0.75/1x, maximum cursor rewind=\(maximumRewind)s, backend seek rewind=\(maximumPlayerSeekRewind)s, shared-start seek readback error=\(maximumSeekReadbackError)s, active cutover difference=\(maximumCutoverDifference)s, corrective seeks=\(correctiveSeeks), healthy gain-only switches=\(healthyGainSwitches), 3 cached source ports / one native rate renderer, asymmetric decoded frames aligned")
    }

    private func impulseFixture(duration: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-impulses-" + UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames = 44100 * duration
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: frames) }
        buffer.floatChannelData![0][49833] = 0.8
        buffer.floatChannelData![1][51777] = -0.6
        buffer.floatChannelData![0][92003] = -0.4
        buffer.floatChannelData![1][119073] = 0.3
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func readChannel(_ url: URL, channel: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func fixture(channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        buffer.floatChannelData![0].initialize(repeating: 0.2, count: 8000)
        if channels == 2 { buffer.floatChannelData![1].initialize(repeating: -0.7, count: 8000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func read(_ url: URL) throws -> [Float] {
        try readChannel(url, channel: 0)
    }
}

@MainActor
private final class RealPlayerCapture {
    var players: [URL: ObservedAVPlayer] = [:]
    var constructions = 0
}

/// Records the application's actual boundary and delegates every operation to a real AVAudioPlayer.
@MainActor
private final class ObservedAVPlayer: AudioPlayerTransport {
    let native: AudioEnginePlayer
    var lastSeek: Double?
    var seekCount = 0
    var seekReadback: Double?
    var lastLiveRead: Double?
    var readTimes: [Double] = []
    var readSamples: [NativeClockSample] = []
    var lastDeviceRead: Double?
    var scheduledEpoch: Double?
    init(_ native: AudioEnginePlayer) { self.native = native }
    var sharedClockID: UUID? { native.sharedClockID }
    var currentTime: Double {
        get {
            let before = native.deviceCurrentTime
            let time = native.currentTime
            let after = native.deviceCurrentTime
            lastLiveRead = time; readTimes.append(time)
            readSamples.append(NativeClockSample(position: time, before: before, after: after))
            return time
        }
        set { seekCount += 1; lastSeek = newValue; native.currentTime = newValue; seekReadback = native.currentTime }
    }
    var rate: Float { get { native.rate } set { native.rate = newValue } }
    var beforeVolumeChange: (() -> Void)?
    var volume: Float { get { native.volume } set { beforeVolumeChange?(); native.volume = newValue } }
    var enableRate: Bool { get { native.enableRate } set { native.enableRate = newValue } }
    var isPlaying: Bool { native.isPlaying }
    func prepareToPlay() -> Bool { native.prepareToPlay() }
    func play() -> Bool { native.play() }
    var deviceCurrentTime: Double { let time = native.deviceCurrentTime; lastDeviceRead = time; return time }
    func play(atTime time: TimeInterval) -> Bool {
        let before = native.deviceCurrentTime
        let result = native.play(atTime: time)
        let after = native.deviceCurrentTime
        if result { scheduledEpoch = time }
        print("Native scheduled start rate=\(native.rate) epoch=\(time) before=\(before) after=\(after) lead=\(time - before)")
        #expect(before < time && after < time)
        return result
    }
    func pause() { native.pause() }
    func stop() { native.stop() }
}

@MainActor
private final class ActiveClockPair {
    var oldTime: Double?
    var destinationTime: Double?
    var readElapsed = 0.0
    var oldDeviceBefore = 0.0, oldDeviceAfter = 0.0
    var newDeviceBefore = 0.0, newDeviceAfter = 0.0
}

private struct NativeClockSample: CustomStringConvertible {
    let position: Double
    let before: Double
    let after: Double
    var description: String { "position=\(position),device=\(before)..\(after)" }
}
