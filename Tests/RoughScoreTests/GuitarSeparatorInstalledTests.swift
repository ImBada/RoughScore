import AVFoundation
import Foundation
@testable import RoughScore
import Testing

/// Opt-in: needs the installed model. `ROUGHSCORE_SEPARATOR_E2E=/path/mix.wav swift test --filter GuitarSeparatorInstalled`
/// writes `<mix>.guitar.caf` for comparison with the PyTorch reference (scripts/separation/compare.py).
struct GuitarSeparatorInstalledTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROUGHSCORE_SEPARATOR_E2E"] != nil && GuitarSeparator.isInstalled))
    func separatesInstalledModelEndToEnd() async throws {
        let mix = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROUGHSCORE_SEPARATOR_E2E"]!)
        let key = "e2e-" + UUID().uuidString
        let start = Date()
        let stem = try await GuitarSeparator.separate(original: mix, originalSHA256: key) { _ in }
        let seconds = Date().timeIntervalSince(start)
        defer { try? FileManager.default.removeItem(at: stem) }
        let input = try AVAudioFile(forReading: mix), output = try AVAudioFile(forReading: stem)
        #expect(output.length == input.length)
        #expect(output.processingFormat.sampleRate == input.processingFormat.sampleRate)
        #expect(output.processingFormat.channelCount == 2)
        let copy = mix.deletingPathExtension().appendingPathExtension("guitar.caf")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: stem, to: copy)
        print("separated \(Double(input.length) / input.processingFormat.sampleRate)s in \(seconds)s -> \(copy.path)")
    }
}
