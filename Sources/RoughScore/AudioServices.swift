import AVFoundation
import Foundation
import CryptoKit
import RoughScoreCore
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

/// The application's actual player boundary; failures and live clocks are injectable in Workspace tests.
@MainActor
protocol AudioPlayerTransport: AnyObject {
    var currentTime: TimeInterval { get set }
    var rate: Float { get set }
    var volume: Float { get set }
    var enableRate: Bool { get set }
    var isPlaying: Bool { get }
    var deviceCurrentTime: TimeInterval { get }
    var sharedClockID: UUID? { get }
    func clockSnapshot() -> PlaybackClockSnapshot
    func play(atTime time: TimeInterval) -> Bool
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

struct PlaybackClockSnapshot {
    let position: Double
    let deviceTime: Double
}

extension AudioPlayerTransport {
    var sharedClockID: UUID? { nil }
    func clockSnapshot() -> PlaybackClockSnapshot {
        let before = deviceCurrentTime
        let position = currentTime
        return PlaybackClockSnapshot(position: position, deviceTime: (before + deviceCurrentTime) / 2)
    }
}
extension AVAudioPlayer: AudioPlayerTransport {}

struct PreparedAudio: Sendable {
    var original: URL
    let left: URL
    let right: URL
    let directory: URL
    let duration: Double
    let isMono: Bool
    let leftPeaks: [Float]
    let rightPeaks: [Float]
    var identity: AudioContentIdentity? = nil
    var stereoURL: URL? = nil
    var mapping: AssetTimeMapping? = nil
    var resource: PreparedAudioResource = .borrowed
    let generation = UUID()
    func url(for source: ListeningSource) -> URL {
        switch source { case .stereo: stereoURL ?? original; case .left: left; case .right: right }
    }
}

struct DetectedPitch: Equatable, Sendable {
    let frequencyHz: Double
    let midi: Double
    var nearestMIDI: Int? {
        guard frequencyHz.isFinite, frequencyHz > 0, midi.isFinite, (0...127).contains(midi) else { return nil }
        return Int(midi.rounded())
    }
}

enum AudioIssue: LocalizedError {
    case unsupported, tooLong, unavailable, sourceChanged, playbackFailed
    var errorDescription: String? {
        switch self {
        case .unsupported: "비어 있거나 지원하지 않는 오디오입니다. 모노 또는 스테레오 파일을 선택하세요."
        case .tooLong: "초안에서는 1시간 이내의 오디오를 사용할 수 있습니다."
        case .playbackFailed: "오디오 재생을 준비하지 못했습니다. 이전 청취 채널을 유지합니다."
        case .sourceChanged: "오디오 준비 중 원본 내용이 바뀌었습니다. 다시 연결해 주세요."
        case .unavailable: "Music Understanding 분석에는 macOS 27과 해당 SDK가 필요합니다. TAB 편집과 재생은 사용할 수 있습니다."
        }
    }
}

enum AudioPreparation {
    /// Small, bounded selected-lane crop. The result is advisory and contains no fingering.
    static func detectPitch(_ url: URL, at time: Double) async throws -> DetectedPitch? {
        let task = Task.detached(priority: .userInitiated) { () throws -> DetectedPitch? in
            try Task.checkCancellation()
            guard time.isFinite, time >= 0 else { throw AudioIssue.unsupported }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.channelCount == 1, (8_000...192_000).contains(format.sampleRate),
                  time < Double(file.length) / format.sampleRate else { throw AudioIssue.unsupported }
            file.framePosition = Int64(time * format.sampleRate)
            let count = AVAudioFrameCount(min(file.length - file.framePosition, Int64(format.sampleRate * 0.35)))
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
            try file.read(into: buffer, frameCount: count)
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let result = try MonophonicTranscriber().analyze(samples: samples, sampleRate: format.sampleRate,
                timeOrigin: time, isCancelled: { Task.isCancelled })
            try Task.checkCancellation()
            guard let proposal = result.proposals.first, proposal.qualified,
                  let hz = proposal.frequencyHz, let midi = proposal.midi else { return nil }
            return DetectedPitch(frequencyHz: hz, midi: midi)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// One prepared channel's samples for `start..<end` (at most 60 s), read in blocks with
    /// cancellation checks. `origin` is the original time of the first sample.
    static func readRegion(_ url: URL, from start: Double, to end: Double) throws -> (samples: [Float], sampleRate: Double, origin: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        let first = Int64(floor(start * sampleRate)), last = min(file.length, Int64(ceil(end * sampleRate)))
        guard first < last, last - first <= Int64(60 * sampleRate) else { throw AudioIssue.unsupported }
        file.framePosition = first
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples: [Float] = []; samples.reserveCapacity(Int(last - first))
        while file.framePosition < last {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, last - file.framePosition)))
            guard buffer.frameLength > 0 else { throw AudioIssue.unsupported }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return (samples, sampleRate, Double(first) / sampleRate)
    }

    /// Decode in bounded chunks and preserve each original channel. This is not source separation.
    static func prepare(_ url: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> PreparedAudio {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            await progress(0)
            let fingerprint = try contentFingerprint(url)
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
                // Flush final PCM frames before a transport can open the channel files.
                leftFile.close(); rightFile.close()
                try Task.checkCancellation()
                guard try contentFingerprint(url) == fingerprint else { throw AudioIssue.unsupported }
                let scratch = try OwnedAudioScratch(parent: FileManager.default.temporaryDirectory)
                let ownedLeft = try scratch.copy(from: leftURL, named: "left.caf")
                let ownedRight = try scratch.copy(from: rightURL, named: "right.caf")
                try FileManager.default.removeItem(at: directory)
                return PreparedAudio(original: url, left: ownedLeft, right: ownedRight, directory: scratch.directoryURL,
                                     duration: duration, isMono: format.channelCount == 1,
                                     leftPeaks: leftPeaks, rightPeaks: rightPeaks,
                                     identity: AudioContentIdentity(sha256: fingerprint, channelCount: Int(format.channelCount),
                                         sampleRate: format.sampleRate, frameCount: file.length), resource: .scratch(scratch))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Hash in bounded chunks and cooperate with cancellation; never read user fixture paths implicitly.
    static func contentFingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Async callers propagate cancellation to the bounded reader instead of leaving detached hashing running.
    static func fingerprint(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        let task = Task.detached { try contentFingerprint(url) }
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
            guard let fret = event.fret, let midi = project.soundingMIDI(string: event.string, fret: fret) else { continue }
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
