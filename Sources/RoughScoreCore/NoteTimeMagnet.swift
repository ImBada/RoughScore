import Foundation

/// A note's original time and horizontal position in on-screen logical points.
public struct NoteMagnetAnchor: Equatable, Sendable {
    public let id: UUID
    public let time: Double
    public let x: Double

    public init(id: UUID, time: Double, x: Double) {
        self.id = id
        self.time = time
        self.x = x
    }
}

public enum NoteTimeMagnet {
    /// Callers supply visible notes from the same lane, excluding the dragged note.
    /// Coordinates include any page-fit scale so the capture radius stays constant on screen.
    public static func nearest(to x: Double, anchors: [NoteMagnetAnchor], radius: Double = 10) -> NoteMagnetAnchor? {
        guard x.isFinite, radius.isFinite, radius >= 0 else { return nil }
        var nearest: NoteMagnetAnchor?
        var nearestDistance = Double.infinity
        for anchor in anchors where anchor.x.isFinite && anchor.time.isFinite && anchor.time >= 0 {
            let distance = abs(anchor.x - x)
            guard distance <= radius else { continue }
            if distance < nearestDistance || (distance == nearestDistance && precedes(anchor, nearest)) {
                nearest = anchor
                nearestDistance = distance
            }
        }
        return nearest
    }

    private static func precedes(_ anchor: NoteMagnetAnchor, _ current: NoteMagnetAnchor?) -> Bool {
        guard let current else { return true }
        if anchor.time != current.time { return anchor.time < current.time }
        return anchor.id.uuidString < current.id.uuidString
    }
}
