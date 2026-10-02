import Foundation

/// A peak array uniformly divides the audio duration into time bins.
/// Range queries preserve the strongest peak in every intersecting bin. They remain
/// approximate at the envelope's existing resolution, including partial edge bins.
public enum WaveformEnvelope {
    public static func peak(_ peaks: [Float], duration: Double, from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty, duration.isFinite, duration > 0,
              start.isFinite, end.isFinite, start < end else { return 0 }
        let lower = max(0, start)
        let upper = min(duration, end)
        guard lower < upper else { return 0 }

        let count = Double(peaks.count)
        let first = min(peaks.count - 1, Int(floor(lower / duration * count)))
        let afterLast = min(peaks.count, max(first + 1, Int(ceil(upper / duration * count))))
        var result: Float = 0
        for index in first..<afterLast where peaks[index].isFinite {
            result = max(result, abs(peaks[index]))
        }
        return result
    }
}
