import AVFoundation
import Foundation
import RoughScoreCore

extension AudioPreparation {
    /// Derived audition files are streamed in 4096-frame chunks. User media is never modified.
    /// Outside the explicit valid window, every channel is silent through the original EOF.
    static func alignedStem(_ raw: PreparedAudio, asset: AudioAsset, duration: Double) async throws -> PreparedAudio {
        let mapping = try AssetTimeMapping(asset: asset, originalDuration: duration)
        let task = Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: raw.original, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length == mapping.frameCount, file.processingFormat.sampleRate == mapping.sampleRate,
                  Int(file.processingFormat.channelCount) == asset.identity?.channelCount else { throw AudioIssue.sourceChanged }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let stereoURL = directory.appendingPathComponent("stereo.caf")
                let leftURL = directory.appendingPathComponent("left.caf"), rightURL = directory.appendingPathComponent("right.caf")
                let stereo = AVAudioFormat(standardFormatWithSampleRate: mapping.sampleRate, channels: 2)!
                let mono = AVAudioFormat(standardFormatWithSampleRate: mapping.sampleRate, channels: 1)!
                let outputs = try [AVAudioFile(forWriting: stereoURL, settings: stereo.settings),
                                   AVAudioFile(forWriting: leftURL, settings: mono.settings),
                                   AVAudioFile(forWriting: rightURL, settings: mono.settings)]
                let capacity: AVAudioFrameCount = 4096
                let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
                let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity)!
                let channel = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)!
                let total = Int64(ceil(duration * mapping.sampleRate))
                let bins = max(1, Int(ceil(duration * 100)))
                var left = [Float](repeating: 0, count: bins), right = left
                var position: Int64 = 0
                // Round the explicit offset once onto this asset's sample grid, then keep integer frames.
                let first = mapping.assetFrame(originalTime: 0)
                while position < total {
                    try Task.checkCancellation()
                    let count = Int(min(Int64(capacity), total - position))
                    buffer.frameLength = AVAudioFrameCount(count); channel.frameLength = buffer.frameLength
                    for c in 0..<2 { buffer.floatChannelData![c].update(repeating: 0, count: count) }
                    let lower = max(0, first + position), upper = min(file.length, first + position + Int64(count))
                    if lower < upper {
                        file.framePosition = lower
                        try file.read(into: input, frameCount: AVAudioFrameCount(upper - lower))
                        let destination = Int(lower - (first + position))
                        for i in 0..<Int(input.frameLength) {
                            buffer.floatChannelData![0][destination + i] = input.floatChannelData![0][i]
                            buffer.floatChannelData![1][destination + i] = input.floatChannelData![raw.isMono ? 0 : 1][i]
                        }
                    }
                    try outputs[0].write(from: buffer)
                    for c in 0..<2 {
                        channel.floatChannelData![0].update(from: buffer.floatChannelData![c], count: count)
                        try outputs[c + 1].write(from: channel)
                    }
                    for i in 0..<count {
                        let bin = min(bins - 1, Int(Double(position + Int64(i)) / Double(total) * Double(bins)))
                        left[bin] = max(left[bin], abs(buffer.floatChannelData![0][i]))
                        right[bin] = max(right[bin], abs(buffer.floatChannelData![1][i]))
                    }
                    position += Int64(count)
                }
                outputs.forEach { $0.close() }
                try Task.checkCancellation()
                guard try contentFingerprint(raw.original) == asset.identity?.sha256 else { throw AudioIssue.sourceChanged }
                return PreparedAudio(original: raw.original, left: leftURL, right: rightURL, directory: directory,
                    duration: duration, isMono: raw.isMono, leftPeaks: left, rightPeaks: right, identity: raw.identity,
                    stereoURL: stereoURL, mapping: mapping)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
