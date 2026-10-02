import Foundation

public enum TabEditError: Error, Equatable, Sendable {
    case invalidSelection
    case staleSelection(UUID)
    case invalidRange
    case invalidCopyOrigin
    case unsupportedFragmentVersion(Int)
    case invalidFragment
    case clipboardTooLarge
    case invalidOffset
    case outOfBounds
    case unrepresentableTiming
    case generatedIDCollision
}

/// An immutable snapshot of exact event IDs, not a live range predicate.
/// Missing IDs reject the entire operation; they are never silently dropped.
public struct TabSelection: Equatable, Sendable {
    public let ids: Set<UUID>
    public let primaryID: UUID?
    /// A range copy anchors at the original range start, preserving leading silence.
    /// An explicit multi-selection instead anchors at its earliest current event.
    public let rangeOrigin: Double?

    public init(ids: Set<UUID> = [], primaryID: UUID? = nil) throws {
        if let primaryID, !ids.contains(primaryID) { throw TabEditError.invalidSelection }
        self.ids = ids
        self.primaryID = primaryID ?? ids.min { $0.uuidString < $1.uuidString }
        self.rangeOrigin = nil
    }

    private init(ids: Set<UUID>, primaryID: UUID?, rangeOrigin: Double) throws {
        if let primaryID, !ids.contains(primaryID) { throw TabEditError.invalidSelection }
        self.ids = ids
        self.primaryID = primaryID ?? ids.min { $0.uuidString < $1.uuidString }
        self.rangeOrigin = rangeOrigin
    }

    /// Original seconds, start inclusive/end exclusive, one explicitly chosen lane.
    /// Empty ranges are valid; the range may end exactly at project.duration.
    public static func range(in project: ScoreProject, lane: GuitarLane,
                             from start: Double, to end: Double,
                             primaryID: UUID? = nil) throws -> Self {
        _ = try project.validated()
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end <= project.duration else {
            throw TabEditError.invalidRange
        }
        let ids = Set(project.events.filter { $0.lane == lane && $0.time >= start && $0.time < end }.map(\.id))
        return try Self(ids: ids, primaryID: primaryID, rangeOrigin: start)
    }

    /// Exact UUID lookup, preserving project storage order even for coincident notes.
    /// Unrelated events inserted later are not implicitly selected.
    public func resolved(in project: ScoreProject) throws -> [TabEvent] {
        _ = try project.validated()
        let available = Set(project.events.map(\.id))
        if let missing = ids.subtracting(available).min(by: { $0.uuidString < $1.uuidString }) {
            throw TabEditError.staleSelection(missing)
        }
        return project.events.filter { ids.contains($0.id) }
    }
}
