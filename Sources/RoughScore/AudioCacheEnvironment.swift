import AVFoundation
import Foundation
import RoughScoreCore

/// One app-process store deduplicates work across live Workspaces. Tests/tools inject a dedicated root.
/// The only default write location is ~/Library/Caches/org.roughscore/prepared-v1, capped at 4 GiB
/// except while active playback/undo/analysis leases pin entries. No preference is read or changed.
struct AudioCacheEnvironment: Sendable {
    let preparation: CachedAudioPreparation
    init(configuration: OwnedArtifactCache.Configuration, instrumentation: PreparationInstrumentation? = nil) throws {
        preparation = CachedAudioPreparation(store: try OwnedArtifactCache(configuration: configuration), instrumentation: instrumentation)
    }
    static let shared: Result<AudioCacheEnvironment, Error> = Result {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
        let parent = caches.appendingPathComponent("org.roughscore", isDirectory: true)
        guard parent.pathComponents == parent.resolvingSymlinksInPath().pathComponents else { throw AudioIssue.unsupported }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return try AudioCacheEnvironment(configuration: .init(root: parent.appendingPathComponent("prepared-v1")))
    }

    /// Descriptor semantics remain the default for injected producers. AVURLAsset-backed Apple
    /// analysis requires a regular CAF pathname, fenced by the same retained reader and lease.
    enum SummaryInputMode: Sendable { case descriptor, canonicalFile }

    func summary(_ audio: CachedAudioPreparation.Result, channel: ListeningSource, modelVersion: String,
                 relevantSettings: [String: String] = [:], inputMode: SummaryInputMode = .descriptor,
                 produce: @escaping @Sendable (URL, Double) async throws -> AnalysisSummary) async throws -> AnalysisSummary {
        let name = channel == .stereo ? audio.metadata.stereo : channel == .left ? audio.metadata.left : audio.metadata.right
        let reader = try audio.lease.reader(name)
        defer { withExtendedLifetime(reader) {} }
        var settings = relevantSettings
        settings["runtime"] = ProcessInfo.processInfo.operatingSystemVersionString
        settings["features"] = "rhythm,key,structure,instrumentActivity-v1"
        settings["preparedKey"] = try audio.lease.key.digest
        settings["channel"] = channel.rawValue; settings["duration"] = String(audio.metadata.duration)
        let key = OwnedArtifactCache.Key(contentSHA256: audio.metadata.identity.sha256, kind: "music-analysis", algorithm: modelVersion, settings: settings)
        let result = try await CachedAnalysisOutputs.summary(store: preparation.store, key: key, duration: audio.metadata.duration) {
            // The detached shared producer owns this reader even if its consumer cancels or closes.
            defer { withExtendedLifetime(reader) {} }
            try reader.validate()
            let url = try inputMode == .canonicalFile ? reader.canonicalURL() : reader.url
            let output = try await produce(url, audio.metadata.duration)
            try reader.validate()
            return output
        }
        try reader.validate()
        return result
    }

    func pitches(_ audio: CachedAudioPreparation.Result, channel: ListeningSource, from start: Double, to end: Double,
                 settings: MonophonicTranscriber.Settings = .init()) async throws -> MonophonicTranscriber.Result {
        guard channel != .stereo, start.isFinite, end.isFinite, start >= 0, start < end,
              end <= audio.metadata.duration, end - start <= 60 else { throw AudioIssue.unsupported }
        let sampleRate = audio.metadata.identity.sampleRate
        let first = Int64(floor(start * sampleRate)), last = min(audio.metadata.outputFrames, Int64(ceil(end * sampleRate)))
        guard first < last, last - first <= Int64(sampleRate * 60) else { throw AudioIssue.unsupported }
        let origin = Double(first) / sampleRate
        let range = origin..<(origin + Double(last - first) / sampleRate)
        let key = OwnedArtifactCache.Key(contentSHA256: audio.metadata.identity.sha256, kind: "pitch-measurements",
            algorithm: MonophonicTranscriber.version, settings: ["preparedKey": try audio.lease.key.digest, "channel": channel.rawValue,
                "firstFrame": String(first), "lastFrame": String(last), "minimumRMS": String(settings.minimumRMS), "attackRatio": String(settings.attackRatio)])
        let reader = try audio.lease.reader(channel == .left ? audio.metadata.left : audio.metadata.right)
        let result = try await CachedAnalysisOutputs.pitches(store: preparation.store, key: key, range: range, settings: settings) {
            let file = try AVAudioFile(forReading: reader.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            file.framePosition = first
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            var samples: [Float] = []; samples.reserveCapacity(Int(last - first))
            while file.framePosition < last {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, last - file.framePosition)))
                guard buffer.frameLength > 0 else { throw AudioIssue.unsupported }
                samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            let output = try MonophonicTranscriber(settings: settings).analyze(samples: samples, sampleRate: sampleRate,
                timeOrigin: Double(first) / sampleRate, isCancelled: { Task.isCancelled })
            try reader.validate()
            return output
        }
        try reader.validate()
        return result
    }
}
