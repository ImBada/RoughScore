import Foundation

/// Only completed, validated algorithm outputs are stored. Project attribution and human review
/// state remain in ScoreProject/the editor; neither is reconstructed from this evictable storage.
public enum CachedAnalysisOutputs {
    public static func summary(store: OwnedArtifactCache, key: OwnedArtifactCache.Key, duration: Double,
                               produce: @escaping @Sendable () async throws -> AnalysisSummary) async throws -> AnalysisSummary {
        let lease = try await store.acquire(key) { stage in
            var output = try await produce()
            try Task.checkCancellation()
            output.provenance = nil
            try validate(output, duration: duration)
            try stage.write("result.json", data: JSONEncoder().encode(output))
            return Data("analysis-summary-v1".utf8)
        }
        guard lease.payload == Data("analysis-summary-v1".utf8) else { throw ProjectError.invalidData }
        let result = try JSONDecoder().decode(AnalysisSummary.self, from: lease.data("result.json", maximum: 16 * 1_048_576))
        try validate(result, duration: duration)
        guard result.provenance == nil else { throw ProjectError.invalidData }
        return result
    }
    private static func validate(_ value: AnalysisSummary, duration: Double) throws {
        _ = try ScoreProject(duration: duration, analyses: ["stereo": value]).validated()
    }

    public static func pitches(store: OwnedArtifactCache, key: OwnedArtifactCache.Key,
                               range: Range<Double>, settings: MonophonicTranscriber.Settings,
                               produce: @escaping @Sendable () async throws -> MonophonicTranscriber.Result) async throws -> MonophonicTranscriber.Result {
        let lease = try await store.acquire(key) { stage in
            let output = try await produce()
            try Task.checkCancellation()
            try validate(output, range: range, settings: settings)
            try stage.write("result.json", data: JSONEncoder().encode(PitchRecord(output)))
            return Data("pitch-measurements-v1".utf8)
        }
        guard lease.payload == Data("pitch-measurements-v1".utf8) else { throw ProjectError.invalidData }
        let result = try JSONDecoder().decode(PitchRecord.self, from: lease.data("result.json", maximum: 16 * 1_048_576)).result
        try validate(result, range: range, settings: settings)
        return result
    }
    private static func validate(_ value: MonophonicTranscriber.Result, range: Range<Double>, settings: MonophonicTranscriber.Settings) throws {
        guard value.version == MonophonicTranscriber.version, value.settings == settings,
              value.analyzedOriginalRange == range, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.lowerBound <= range.upperBound, range.upperBound - range.lowerBound <= 60 + range.upperBound.ulp else { throw ProjectError.invalidData }
        for p in value.proposals {
            guard p.onset.isFinite, p.audioEnd.isFinite, p.onset >= range.lowerBound, p.audioEnd <= range.upperBound,
                  p.onset <= p.audioEnd, p.periodicity.isFinite, (0...1).contains(p.periodicity),
                  p.frequencyHz.map({ $0.isFinite && $0 > 0 }) ?? true,
                  p.midi.map(\.isFinite) ?? true, p.centsFromNearestSemitone.map(\.isFinite) ?? true else { throw ProjectError.invalidData }
        }
    }
    private struct PitchRecord: Codable {
        var proposals: [ProposalRecord]
        var start: Double; var end: Double
        var minimumRMS: Double; var attackRatio: Double; var version: String
        init(_ result: MonophonicTranscriber.Result) {
            proposals = result.proposals.map(ProposalRecord.init); start = result.analyzedOriginalRange.lowerBound
            end = result.analyzedOriginalRange.upperBound; minimumRMS = result.settings.minimumRMS
            attackRatio = result.settings.attackRatio; version = result.version
        }
        var result: MonophonicTranscriber.Result {
            get throws {
                guard start.isFinite, end.isFinite, start <= end else { throw ProjectError.invalidData }
                return .init(proposals: proposals.map(\.proposal), analyzedOriginalRange: start..<end,
                    settings: .init(minimumRMS: minimumRMS, attackRatio: attackRatio), version: version)
            }
        }
    }
    private struct ProposalRecord: Codable {
        var onset: Double; var onsetIsRegionBoundary: Bool; var audioEnd: Double; var reachesRegionEnd: Bool
        var frequencyHz: Double?; var midi: Double?; var centsFromNearestSemitone: Double?
        var periodicity: Double; var qualified: Bool; var unknownReason: MonophonicTranscriber.UnknownReason?
        init(_ p: MonophonicTranscriber.Proposal) {
            onset = p.onset; onsetIsRegionBoundary = p.onsetIsRegionBoundary; audioEnd = p.audioEnd
            reachesRegionEnd = p.reachesRegionEnd; frequencyHz = p.frequencyHz; midi = p.midi
            centsFromNearestSemitone = p.centsFromNearestSemitone; periodicity = p.periodicity
            qualified = p.qualified; unknownReason = p.unknownReason
        }
        var proposal: MonophonicTranscriber.Proposal {
            .init(onset: onset, onsetIsRegionBoundary: onsetIsRegionBoundary, audioEnd: audioEnd,
                  reachesRegionEnd: reachesRegionEnd, frequencyHz: frequencyHz, midi: midi,
                  centsFromNearestSemitone: centsFromNearestSemitone, periodicity: periodicity,
                  qualified: qualified, unknownReason: unknownReason)
        }
    }
}
