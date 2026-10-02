import Foundation

/// Continuous original-song seconds. The right edge is exclusive, without reserving an arbitrary millisecond.
public enum TimeBounds {
    public static func clamp(_ time: Double, duration: Double) -> Double? {
        guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(0, time), duration.nextDown)
    }
}
