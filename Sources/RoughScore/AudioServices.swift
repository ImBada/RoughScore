import AVFoundation
import Foundation
import RoughScoreCore
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

struct PreparedAudio: Sendable {
    let original: URL
    let left: URL
    let right: URL
    let directory: URL
    let duration: Double
    let isMono: Bool
    let leftPeaks: [Float]
    let rightPeaks: [Float]
    func url(for source: ListeningSource) -> URL {
        switch source { case .stereo: original; case .left: left; case .right: right }
    }
}

enum AudioIssue: LocalizedError {
    case unsupported, tooLong, unavailable
    var errorDescription: String? {
        switch self {
        case .unsupported: "비어 있거나 지원하지 않는 오디오입니다. 모노 또는 스테레오 파일을 선택하세요."
        case .tooLong: "초안에서는 1시간 이내의 오디오를 사용할 수 있습니다."
        case .unavailable: "Music Understanding 분석에는 macOS 27과 해당 SDK가 필요합니다. TAB 편집과 재생은 사용할 수 있습니다."
        }
    }
}

enum AudioPreparation {
    /// Decode in bounded chunks and preserve each original channel. This is not source separation.
    static func prepare(_ url: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> PreparedAudio {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            await progress(0)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard (1...2).contains(format.channelCount), file.length > 0,
                  format.commonFormat == .pcmFormatFloat32 else { throw AudioIssue.unsupported }
            let duration = Double(file.length) / format.sampleRate
            guard duration <= 3600 else { throw AudioIssue.tooLong }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let leftURL = directory.appendingPathComponent("left.caf")
                let rightURL = directory.appendingPathComponent("right.caf")
                let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
                let leftFile = try AVAudioFile(forWriting: leftURL, settings: mono.settings)
                let rightFile = try AVAudioFile(forWriting: rightURL, settings: mono.settings)
                let capacity: AVAudioFrameCount = 16_384
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
                let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)!
                // Keep attacks visible when a long song is shown in short score systems.
                let count = max(1, Int(ceil(duration * 100))) // ~10ms per envelope bin
                var leftPeaks = [Float](repeating: 0, count: count)
                var rightPeaks = leftPeaks
                var offset: AVAudioFramePosition = 0
                while offset < file.length {
                    try Task.checkCancellation()
                    try file.read(into: input, frameCount: min(capacity, AVAudioFrameCount(file.length - offset)))
                    guard input.frameLength > 0, let channels = input.floatChannelData,
                          let destination = output.floatChannelData else { throw AudioIssue.unsupported }
                    output.frameLength = input.frameLength
                    let rightIndex = format.channelCount == 1 ? 0 : 1
                    for i in 0..<Int(input.frameLength) {
                        let bin = min(count - 1, Int(Double(offset + Int64(i)) / Double(file.length) * Double(count)))
                        leftPeaks[bin] = max(leftPeaks[bin], abs(channels[0][i]))
                        rightPeaks[bin] = max(rightPeaks[bin], abs(channels[rightIndex][i]))
                        destination[0][i] = channels[0][i]
                    }
                    try leftFile.write(from: output)
                    for i in 0..<Int(input.frameLength) { destination[0][i] = channels[rightIndex][i] }
                    try rightFile.write(from: output)
                    offset += Int64(input.frameLength)
                    await progress(Double(offset) / Double(file.length))
                }
                try Task.checkCancellation()
                return PreparedAudio(original: url, left: leftURL, right: rightURL, directory: directory,
                                     duration: duration, isMono: format.channelCount == 1,
                                     leftPeaks: leftPeaks, rightPeaks: rightPeaks)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func createDemo(project: ScoreProject = .demo) throws -> URL {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-demo-" + UUID().uuidString + ".wav")
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let count = Int(sampleRate * project.duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channels = buffer.floatChannelData!
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: count) }
        for event in project.events {
            try Task.checkCancellation()
            guard let fret = event.fret, let midi = TabMath.midi(string: event.string, fret: fret) else { continue }
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let channel = event.lane == .left ? 0 : 1
            let start = Int(event.time * sampleRate)
            for i in 0..<Int(sampleRate * 1.4) where start + i < count {
                if i % 8192 == 0 { try Task.checkCancellation() }
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.005)
                let tone = sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t)
                channels[channel][start + i] += Float(0.24 * attack * exp(-t * 5) * tone)
            }
        }
        do {
            try Task.checkCancellation()
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

enum AppleMusicAnalysis {
    static func analyze(_ url: URL, duration: Double) async throws -> AnalysisSummary {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27.0, *) {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let session = try await MusicUnderstandingSession(asset: asset)
            let result = try await withTaskCancellationHandler {
                try await session.analyze(for: [.rhythm, .key, .structure, .instrumentActivity])
            } onCancel: {
                Task { await session.cancel() }
            }
            try Task.checkCancellation()
            func times(_ values: [CMTime]) -> [Double] {
                values.map(\.seconds).filter { $0.isFinite && $0 >= 0 && $0 <= duration }
            }
            func spans(_ ranges: [CMTimeRange]) -> [TimeSpan] {
                ranges.compactMap { range in
                    let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
                    guard start.isFinite, end.isFinite, end > 0, start < duration else { return nil }
                    return TimeSpan(start: max(0, start), end: min(duration, end))
                }
            }
            let key = result.key?.ranges.first.map {
                let names = ["aFlat": "A♭", "aSharp": "A♯", "bFlat": "B♭", "cSharp": "C♯", "dFlat": "D♭",
                             "dSharp": "D♯", "eFlat": "E♭", "fSharp": "F♯", "gFlat": "G♭", "gSharp": "G♯"]
                let tonic = names[$0.value.tonic.rawValue] ?? $0.value.tonic.rawValue.uppercased()
                return tonic + ($0.value.mode == .minor ? " minor" : " major")
            }
            return AnalysisSummary(bpm: result.rhythm?.beatsPerMinute.map(Double.init), key: key,
                                   beats: times(result.rhythm?.beats ?? []), bars: times(result.rhythm?.bars ?? []),
                                   sections: spans(result.structure?.sections ?? []),
                                   otherInstrumentRanges: spans(result.instrumentActivity?.ranges[.other] ?? []))
        }
        #endif
        throw AudioIssue.unavailable
    }
}

/// Future model adapters must return actual guitar audio, not the broad `other` activity class.
protocol GuitarStemSeparating: Sendable {
    func separateGuitar(from stereoAudio: URL) async throws -> URL
}
