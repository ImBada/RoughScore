import Foundation

/// Stored v1 semantics: original seconds = asset seconds + explicit user offset.
/// Playback rate never participates in file/sample coordinates.
public struct AssetTimeMapping: Equatable, Sendable {
    public let offset: Double
    public let sampleRate: Double
    public let frameCount: Int64
    public let originalDuration: Double
    public init(asset: AudioAsset, originalDuration: Double) throws {
        _ = try asset.validated()
        guard let identity = asset.identity, originalDuration.isFinite, originalDuration > 0 else { throw ProjectError.invalidData }
        offset = asset.originalTimeOffset; sampleRate = identity.sampleRate
        frameCount = identity.frameCount; self.originalDuration = originalDuration
    }
    public var assetDuration: Double { Double(frameCount) / sampleRate }
    public func originalTime(assetTime: Double) -> Double { assetTime + offset }
    public func assetTime(originalTime: Double) -> Double { originalTime - offset }
    public func originalTime(frame: Int64) -> Double { originalTime(assetTime: Double(frame) / sampleRate) }
    /// May be outside the file. Callers apply the explicit silence/clip policy.
    public func assetFrame(originalTime: Double) -> Int64 {
        Int64(floor(assetTime(originalTime: originalTime) * sampleRate))
    }
    public var validOriginalWindow: TimeSpan {
        let start = min(originalDuration, max(0, offset))
        let end = max(start, min(originalDuration, max(0, originalTime(assetTime: assetDuration))))
        return TimeSpan(start: start, end: end)
    }
    public func mapped(_ summary: AnalysisSummary) -> AnalysisSummary {
        var result = summary
        func times(_ values: [Double]) -> [Double] {
            values.map { originalTime(assetTime: $0) }.filter { $0 >= 0 && $0 <= originalDuration }
        }
        func spans(_ values: [TimeSpan]) -> [TimeSpan] {
            values.compactMap {
                let start = max(0, originalTime(assetTime: $0.start))
                let end = min(originalDuration, originalTime(assetTime: $0.end))
                return start < end ? TimeSpan(start: start, end: end) : nil
            }
        }
        result.beats = times(summary.beats); result.bars = times(summary.bars)
        result.sections = spans(summary.sections); result.otherInstrumentRanges = spans(summary.otherInstrumentRanges)
        return result
    }
}
