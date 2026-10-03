import Foundation

/// A playable position and advisory costs. Frets (including open fret zero) are capo-relative.
public struct FingeringCandidate: Equatable, Sendable {
    public let string: Int
    public let fret: Int
    public let preferredFretDistance: Int?
    public let neighborFretDistance: Int
    public let neighborStringDistance: Int
}

/// The editing location; the project supplies the notes. No event is changed or created.
public struct FingeringContext: Equatable, Sendable {
    public let lane: GuitarLane
    public let time: Double
    public let excludingEventID: UUID?

    public init(lane: GuitarLane, time: Double, excludingEventID: UUID? = nil) {
        self.lane = lane; self.time = time; self.excludingEventID = excludingEventID
    }
}

public enum FingeringResolution: Equatable, Sendable {
    /// Empty means the tuning is resolved but this pitch has no playable position.
    case resolved([FingeringCandidate])
    case invalidPitch, invalidTuning, unresolvedTuning, invalidPreference, invalidContext

    public var candidates: [FingeringCandidate] {
        if case let .resolved(candidates) = self { return candidates }
        return []
    }
}

/// Pure reverse pitch lookup. Ranking is advisory, not chord solving or automatic TAB rewriting.
public enum FingeringResolver {
    public static func resolve(midi: Int, project: ScoreProject, preferredFret: Int? = nil,
                               context: FingeringContext? = nil) -> FingeringResolution {
        guard (0...127).contains(midi) else { return .invalidPitch }
        let tuning: TuningDefinition
        if let numeric = project.tuningDefinition {
            guard (try? numeric.validated()) != nil else { return .invalidTuning }
            tuning = numeric
        } else {
            guard project.tuning == ["E", "B", "G", "D", "A", "E"] else { return .unresolvedTuning }
            tuning = TuningDefinition()
        }
        guard preferredFret.map({ (0...24).contains($0) }) ?? true else { return .invalidPreference }

        var neighbors: [TabEvent] = []
        if let context {
            guard project.duration.isFinite, project.duration > 0, project.duration <= 86_400,
                  context.time.isFinite, context.time >= 0, context.time < project.duration
            else { return .invalidContext }
            // Excluded and opposite-lane events cannot affect either validation or ranking.
            let relevant = project.events.filter {
                $0.lane == context.lane && $0.id != context.excludingEventID
            }
            guard Set(relevant.map(\.id)).count == relevant.count,
                  relevant.allSatisfy({
                      $0.time.isFinite && $0.time >= 0 && $0.time < project.duration &&
                      (1...6).contains($0.string) && ($0.fret.map({ (0...24).contains($0) }) ?? true)
                  }) else { return .invalidContext }
            let known = relevant.filter { $0.fret != nil }
            let previousTime = known.lazy.filter { $0.time < context.time }.map(\.time).max()
            let nextTime = known.lazy.filter { $0.time > context.time }.map(\.time).min()
            // Include every known note at each closest strict timestamp, never coincident notes.
            neighbors = known.filter { $0.time == previousTime || $0.time == nextTime }
        }

        var candidates: [FingeringCandidate] = []
        for string in 1...6 {
            // Validated open MIDI/capo and MIDI bounds make this arithmetic safe even for hostile inputs.
            let fret = midi - tuning.openMIDIPitches[string - 1] - tuning.capo
            guard (0...24).contains(fret), project.soundingMIDI(string: string, fret: fret) == midi
            else { continue }
            var fretDistance = 0
            var stringDistance = 0
            for neighbor in neighbors {
                if let neighborFret = neighbor.fret {
                    fretDistance = saturatingAdd(fretDistance, abs(fret - neighborFret))
                    stringDistance = saturatingAdd(stringDistance, abs(string - neighbor.string))
                }
            }
            candidates.append(FingeringCandidate(
                string: string, fret: fret, preferredFretDistance: preferredFret.map { abs(fret - $0) },
                neighborFretDistance: fretDistance, neighborStringDistance: stringDistance))
        }
        candidates.sort {
            if $0.preferredFretDistance != $1.preferredFretDistance {
                return ($0.preferredFretDistance ?? 0) < ($1.preferredFretDistance ?? 0)
            }
            if $0.neighborFretDistance != $1.neighborFretDistance {
                return $0.neighborFretDistance < $1.neighborFretDistance
            }
            if $0.neighborStringDistance != $1.neighborStringDistance {
                return $0.neighborStringDistance < $1.neighborStringDistance
            }
            if $0.fret != $1.fret { return $0.fret < $1.fret }
            return $0.string < $1.string
        }
        return .resolved(candidates)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
