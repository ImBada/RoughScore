import Foundation

/// Continuous original-song seconds. The right edge is exclusive, without reserving an arbitrary millisecond.
public enum TimeBounds {
    public static func clamp(_ time: Double, duration: Double) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(0, time), duration.nextDown)
    }
    public static func span(start: Double, end: Double) -> Double? {
        guard start.isFinite, start >= 0, end.isFinite, end > start else { return nil }
        return end - start
    }

    private static func within(_ time: Double, start: Double, end: Double) -> Double? {
        guard span(start: start, end: end) != nil, let bounded = clamp(time, duration: end) else { return nil }
        return max(start, bounded)
    }

    /// Shared by the actual score view. Vertical/no-op gestures preserve the exact original time.
    public static func scoreDragTime(_ time: Double, system: ScoreSystem, translation: Double, width: Double) -> Double? {
        guard time.isFinite, translation.isFinite, width.isFinite, width > 0 else { return nil }
        let projected = translation == 0 ? time : system.time(at: system.fraction(at: time) + translation / width)
        return within(projected, start: system.start, end: system.end)
    }

    /// Shared by the actual timeline view, using the real window length even below one millisecond.
    public static func timelineDragTime(_ time: Double, start: Double, end: Double, translation: Double, width: Double) -> Double? {
        guard time.isFinite, let span = span(start: start, end: end),
              translation.isFinite, width.isFinite, width > 0 else { return nil }
        let projected = translation == 0 ? time : time + translation / width * span
        return within(projected, start: start, end: end)
    }
}
