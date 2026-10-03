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
        let url = try impulseFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = RealPlayerCapture()
        var services = WorkspaceServices.live
        services.makePlayer = { url in
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0 // exercise the actual clock without emitting test audio
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
        for rate: Float in [0.5, 0.75, 1] {
            workspace.rate = rate
            workspace.seek(0.5)
            workspace.togglePlayback()
            #expect(workspace.playing)
            for source in [ListeningSource.left, .right, .stereo, .right, .left, .stereo] {
                let old = try #require(capture.players[prepared.url(for: workspace.source)])
                let published = workspace.cursor
                try await Task.sleep(for: .milliseconds(180)) // no UI timer: old clock deliberately advances
                let liveBefore = old.currentTime
                #expect(liveBefore - published >= 0.03)
                #expect(old.rate == rate && old.isPlaying)
                let switchStarted = ProcessInfo.processInfo.systemUptime
                workspace.switchSource(source)
                let destination = try #require(capture.players[prepared.url(for: source)])
                let destinationTime = destination.currentTime
                let switchElapsed = ProcessInfo.processInfo.systemUptime - switchStarted
                maximumPlayerSeekRewind = max(maximumPlayerSeekRewind, liveBefore - destinationTime)
                let rewind = liveBefore - workspace.cursor
                maximumRewind = max(maximumRewind, rewind)
                #expect(rewind < 2 / 44100.0) // allow decoded-frame quantization, not a 30ms tick
                #expect(workspace.source == source && workspace.playing && destination.isPlaying && !old.isPlaying)
                // Allow backend seek quantization below a UI tick and real time spent inside AV calls.
                #expect(destination.rate == rate && destinationTime >= liveBefore - 0.015)
                #expect(destinationTime <= workspace.cursor + switchElapsed * Double(rate) + 0.015)
                #expect(workspace.project == project && !workspace.looping)
            }
            workspace.togglePlayback()
            #expect(!workspace.playing)
        }
        #expect(capture.constructions == 3)
        print("Real Workspace transport: 18 switches at 0.5/0.75/1x, maximum cursor rewind=\(maximumRewind)s, backend seek rewind=\(maximumPlayerSeekRewind)s, 3 cached AVAudioPlayers, asymmetric decoded frames aligned")
    }

    private func impulseFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-impulses-" + UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames = 176400
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
    var players: [URL: AVAudioPlayer] = [:]
    var constructions = 0
}
