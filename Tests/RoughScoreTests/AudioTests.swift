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
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
