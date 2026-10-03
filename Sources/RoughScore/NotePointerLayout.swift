import AppKit
import RoughScoreCore

/// Display-only groups. Event identity, onset, lane and string are never rewritten.
struct NotePointerTarget: Identifiable {
    let events: [TabEvent]
    let center: CGPoint
    let width: Double
    let height: Double
    var id: UUID { events[0].id }
    var frame: CGRect { CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height) }

    func representative(selectedID: UUID?) -> TabEvent {
        events.first { $0.id == selectedID } ?? events[0]
    }

    func next(selectedID: UUID?) -> TabEvent {
        guard let index = events.firstIndex(where: { $0.id == selectedID }) else { return events[0] }
        return events[(index + 1) % events.count]
    }
}

struct NotePointerLayout {
    let targets: [NotePointerTarget]

    init(events: [TabEvent], compact: Bool, displayScale: Double, bounds: ClosedRange<Double>,
         position: (TabEvent) -> CGPoint) {
        let scale = max(0.1, displayScale)
        let chipWidth = (compact ? 24.0 : 30.0) / scale
        let clusterWidth = (compact ? 48.0 : 54.0) / scale
        let gap = 4.0 / scale
        let height = compact ? 14.0 : 26.0
        func target(_ notes: [TabEvent]) -> NotePointerTarget {
            let width = min(bounds.upperBound - bounds.lowerBound, notes.count == 1 ? chipWidth : clusterWidth)
            let point = position(notes[0])
            let x = min(bounds.upperBound - width / 2, max(bounds.lowerBound + width / 2, point.x))
            return NotePointerTarget(events: notes, center: CGPoint(x: x, y: point.y), width: width, height: height)
        }
        var result: [NotePointerTarget] = []
        for lane in GuitarLane.allCases {
            for string in 1...6 {
                let notes = events.filter { $0.lane == lane && $0.string == string }.sorted {
                    $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time
                }
                // Start with ordinary chip footprints. Add a count only after an
                // actual overlap; then merge any neighbor covered by the wider chip.
                // Boundary clamping and page-fit screen footprints participate too.
                var fitted: [NotePointerTarget] = []
                for note in notes {
                    var current = target([note])
                    while let previous = fitted.last, previous.frame.maxX + gap > current.frame.minX {
                        fitted.removeLast(); current = target(previous.events + current.events)
                    }
                    fitted.append(current)
                }
                result.append(contentsOf: fitted)
            }
        }
        targets = result
    }

    func hit(at point: CGPoint) -> NotePointerTarget? { targets.first { $0.frame.contains(point) } }
}
