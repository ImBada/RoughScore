import Foundation

/// Pure atomic edits: clone the validated project value, validate every proposed
/// change, then return it. The Workspace owner supplies one history transaction.
/// No command mutates metadata, audio source, tuning, analyses or undo history.
public enum TabEditCommand: Sendable {
    case move(selection: TabSelection, timeDelta: Double, stringDelta: Int = 0, targetLane: GuitarLane? = nil)
    case delete(selection: TabSelection)
    case paste(fragment: TabFragment, at: Double, targetLane: GuitarLane? = nil)
    case setLength(selection: TabSelection, length: NoteLength?)
    case setTentative(selection: TabSelection, value: Bool)

    public struct Result: Sendable {
        public let project: ScoreProject
        public let changed: Bool
        /// IDs actually modified, deleted or inserted; empty for a no-op.
        public let affectedIDs: Set<UUID>
        /// Paste returns the fresh IDs and mapped primary note for UI selection.
        public let pastedSelection: TabSelection?
    }

    /// UUID factory injection supports deterministic tests. Any collision with an
    /// existing/new ID rejects the entire paste; no existing note is overwritten.
    public func apply(to project: ScoreProject, makeID: () -> UUID = { UUID() }) throws -> Result {
        _ = try project.validated()
        var candidate = project
        var affected = Set<UUID>()
        var pastedSelection: TabSelection?
        switch self {
        case let .move(selection, delta, stringDelta, targetLane):
            guard delta.isFinite else { throw TabEditError.invalidOffset }
            let selected = try selection.resolved(in: project)
            let shiftedTimes = selected.map { delta == 0 ? $0.time : $0.time + delta }
            try Self.validateTimes(shiftedTimes, in: project)
            try Self.preserveDistinctTimes(original: selected.map(\.time), shifted: shiftedTimes)
            var replacements = [UUID: TabEvent]()
            for (index, event) in selected.enumerated() {
                let (string, overflow) = event.string.addingReportingOverflow(stringDelta)
                guard !overflow, (1...6).contains(string) else { throw TabEditError.outOfBounds }
                var changed = event
                changed.time = shiftedTimes[index]; changed.string = string
                if let targetLane { changed.lane = targetLane }
                replacements[event.id] = changed
                if changed != event { affected.insert(event.id) }
            }
            candidate.events = project.events.map { replacements[$0.id] ?? $0 }
        case let .delete(selection):
            _ = try selection.resolved(in: project)
            affected = selection.ids
            candidate.events = project.events.filter { !selection.ids.contains($0.id) }
        case let .paste(fragment, cursor, targetLane):
            try fragment.validate()
            guard cursor.isFinite, cursor >= 0, cursor < project.duration else { throw TabEditError.outOfBounds }
            let times = fragment.events.map { cursor + $0.relativeTime }
            try Self.validateTimes(times, in: project)
            try Self.preserveDistinctTimes(original: fragment.events.map(\.relativeTime), shifted: times)
            var usedIDs = Set(project.events.map(\.id))
            var inserted = [TabEvent]()
            for (index, entry) in fragment.events.enumerated() {
                let id = makeID()
                guard usedIDs.insert(id).inserted else { throw TabEditError.generatedIDCollision }
                inserted.append(TabEvent(id: id, time: times[index], lane: targetLane ?? entry.lane,
                    string: entry.string, fret: entry.fret, length: entry.length,
                    tentative: entry.tentative, memo: entry.memo))
            }
            candidate.events.append(contentsOf: inserted)
            affected = Set(inserted.map(\.id))
            if !inserted.isEmpty {
                let primary = fragment.primaryIndex.map { inserted[$0].id }
                pastedSelection = try TabSelection(ids: affected, primaryID: primary)
            }
        case let .setLength(selection, length):
            _ = try selection.resolved(in: project)
            candidate.events = project.events.map { event in
                guard selection.ids.contains(event.id), event.length != length else { return event }
                var changed = event; changed.length = length; affected.insert(event.id)
                return changed
            }
        case let .setTentative(selection, value):
            _ = try selection.resolved(in: project)
            candidate.events = project.events.map { event in
                guard selection.ids.contains(event.id), event.tentative != value else { return event }
                var changed = event; changed.tentative = value; affected.insert(event.id)
                return changed
            }
        }
        _ = try candidate.validated()
        let changed = candidate != project
        // Returning the original also retains bit patterns on no-op edits.
        return Result(project: changed ? candidate : project, changed: changed,
                      affectedIDs: changed ? affected : [], pastedSelection: pastedSelection)
    }

    private static func validateTimes(_ times: [Double], in project: ScoreProject) throws {
        guard times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < project.duration }) else {
            throw TabEditError.outOfBounds
        }
    }

    /// Large offsets must not silently collapse two distinct instants into a new
    /// chord through floating-point precision loss. Existing coincident notes are
    /// valid and remain individually identified. Ordinary IEEE addition/subtraction
    /// is used; no quantization, epsilon clamp or invented interval is applied.
    private static func preserveDistinctTimes(original: [Double], shifted: [Double]) throws {
        let ordered = zip(original, shifted).sorted { $0.0 < $1.0 }
        for pair in zip(ordered, ordered.dropFirst()) {
            if pair.0.0 < pair.1.0, pair.0.1 >= pair.1.1 { throw TabEditError.unrepresentableTiming }
        }
    }
}
