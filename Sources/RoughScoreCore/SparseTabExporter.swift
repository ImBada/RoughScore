import Foundation

public enum ScoreExportError: Error, Equatable, Sendable {
    case invalidSettings, invalidRange, limitExceeded, unsupportedTableVersion, invalidTable, renderingFailed
}

/// Offline annotation exports. No audio, project mutation, inferred rests/rhythm,
/// fingering or editor/transport state participates in this value-only interface.
public enum SparseTabExporter {
    public static let maximumEvents = 10_000
    public static let maximumBytes = 8_388_608
    public static let maximumMemoBytes = 32_768

    public struct Selection: Equatable, Sendable {
        public var range: TimeSpan?
        public var lanes: Set<GuitarLane>
        public init(range: TimeSpan? = nil, lanes: Set<GuitarLane> = Set(GuitarLane.allCases)) {
            self.range = range; self.lanes = lanes
        }
    }

    public struct EventTable: Codable, Equatable, Sendable {
        public let title: String
        public let duration: Double
        public let range: TimeSpan
        public let lanes: [GuitarLane]
        public let tuning: [String]
        public let tuningDefinition: TuningDefinition?
        public let events: [TabEvent]
    }

    /// Lane/time filtering is half-open, stable at ties, and never changes an event.
    static func snapshot(_ project: ScoreProject, selection: Selection) throws -> EventTable {
        _ = try project.validated()
        guard !selection.lanes.isEmpty else { throw ScoreExportError.invalidSettings }
        let range = selection.range ?? TimeSpan(start: 0, end: project.duration)
        guard range.start.isFinite, range.end.isFinite, range.start >= 0,
              range.end >= range.start, range.end <= project.duration else { throw ScoreExportError.invalidRange }
        let events = project.events.enumerated().filter {
            selection.lanes.contains($0.element.lane) && $0.element.time >= range.start && $0.element.time < range.end
        }.sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
        guard events.count <= maximumEvents, project.title.utf8.count <= maximumMemoBytes,
              project.tuning.allSatisfy({ $0.utf8.count <= 1024 }),
              events.allSatisfy({ $0.memo.utf8.count <= maximumMemoBytes }) else { throw ScoreExportError.limitExceeded }
        guard events.reduce(project.title.utf8.count, { $0 + $1.memo.utf8.count }) <= maximumBytes else {
            throw ScoreExportError.limitExceeded
        }
        return EventTable(title: project.title, duration: project.duration, range: range,
                          lanes: GuitarLane.allCases.filter { selection.lanes.contains($0) },
                          tuning: project.tuning, tuningDefinition: project.tuningDefinition, events: events)
    }

    public static func tuningHeader(for project: ScoreProject) throws -> String {
        _ = try project.validated()
        if let definition = project.tuningDefinition {
            let name = definition.name
            let open = definition.openMIDIPitches.map { "\(pitchName($0)) (\($0))" }.joined(separator: ", ")
            let sounding = (1...6).map { project.soundingMIDI(string: $0, fret: 0).map(pitchName) ?? "?" }.joined(separator: ", ")
            return "\(name) tuning, strings 1-6: \(open); capo \(definition.capo); sounding open: \(sounding). Frets are capo-relative."
        }
        if project.tuning == ["E", "B", "G", "D", "A", "E"] {
            return "Standard legacy tuning, strings 1-6: E4, B3, G3, D3, A2, E2; capo 0 (existing legacy resolver)."
        }
        return "Unresolved legacy tuning, strings 1-6: \(try quoted(project.tuning)); numeric pitches/octaves/capo are unknown."
    }

    private static func pitchName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }

    /// JSON scalars in TSV cells: literal tabs/newlines/quotes/backslashes round-trip.
    /// Metadata uses the same encoding, and every event retains its original UUID.
    public static func eventTable(_ project: ScoreProject, selection: Selection = Selection()) throws -> String {
        let table = try snapshot(project, selection: selection)
        let metadata = EventTable(title: table.title, duration: table.duration, range: table.range,
                                  lanes: table.lanes, tuning: table.tuning, tuningDefinition: table.tuningDefinition, events: [])
        var lines = ["#roughscore-event-table\t1", "#meta\t\(try quoted(metadata))", "id\ttime\tlane\tstring\tfret\tlength\ttentative\tmemo"]
        for e in table.events {
            lines.append([try quoted(e.id), String(e.time), try quoted(e.lane), String(e.string),
                          e.fret.map(String.init) ?? "null", try quoted(e.length), e.tentative ? "true" : "false", try quoted(e.memo)].joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard text.utf8.count <= maximumBytes else { throw ScoreExportError.limitExceeded }
        return text
    }

    public static func parseEventTable(_ data: Data) throws -> EventTable {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { throw ScoreExportError.invalidTable }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 3 else { throw ScoreExportError.invalidTable }
        guard lines[0] == "#roughscore-event-table\t1" else { throw ScoreExportError.unsupportedTableVersion }
        guard lines[1].hasPrefix("#meta\t"), lines[2] == "id\ttime\tlane\tstring\tfret\tlength\ttentative\tmemo" else { throw ScoreExportError.invalidTable }
        let decoder = JSONDecoder()
        let meta = try decoder.decode(EventTable.self, from: Data(lines[1].dropFirst(6).utf8))
        guard meta.events.isEmpty, lines.count - 3 <= maximumEvents else { throw ScoreExportError.invalidTable }
        var events = [TabEvent]()
        for line in lines.dropFirst(3) {
            let cells = line.components(separatedBy: "\t")
            guard cells.count == 8 else { throw ScoreExportError.invalidTable }
            func cell<T: Decodable>(_ type: T.Type, _ index: Int) throws -> T {
                try decoder.decode(type, from: Data(cells[index].utf8))
            }
            events.append(TabEvent(id: try cell(UUID.self, 0), time: try cell(Double.self, 1), lane: try cell(GuitarLane.self, 2),
                string: try cell(Int.self, 3), fret: try cell(Int?.self, 4), length: try cell(NoteLength?.self, 5),
                tentative: try cell(Bool.self, 6), memo: try cell(String.self, 7)))
        }
        var project = ScoreProject(title: meta.title, duration: meta.duration, events: events)
        project.tuning = meta.tuning; project.tuningDefinition = meta.tuningDefinition
        let checked = try snapshot(project, selection: Selection(range: meta.range, lanes: Set(meta.lanes)))
        guard !meta.lanes.isEmpty, Set(meta.lanes).count == meta.lanes.count,
              checked.events.count == events.count else { throw ScoreExportError.invalidTable }
        return EventTable(title: meta.title, duration: meta.duration, range: meta.range, lanes: meta.lanes,
                          tuning: meta.tuning, tuningDefinition: meta.tuningDefinition, events: events)
    }

    /// Every note receives its own column, including simultaneous/same-string notes.
    /// Dashes are untranscribed space, never an inferred rest or rhythmic duration.
    public static func tab(_ project: ScoreProject, selection: Selection = Selection(), columnsPerSystem: Int = 6,
                           showRhythm: Bool = true) throws -> String {
        guard (1...16).contains(columnsPerSystem) else { throw ScoreExportError.invalidSettings }
        let table = try snapshot(project, selection: selection)
        var lines = ["RoughScore sparse TAB", try quoted(table.title), try tuningHeader(for: project),
                     "Original seconds [\(table.range.start), \(table.range.end)); ?=unknown fret; ~=tentative; -=untranscribed, not rest.",
                     "Each #N is a separate annotation column; equal time labels do not merge notes."]
        if table.events.isEmpty { lines.append("No annotations in this selection (untranscribed).") }
        for first in stride(from: 0, to: table.events.count, by: columnsPerSystem) {
            let indices = Array(first..<min(table.events.count, first + columnsPerSystem))
            let anchors = indices.map { "\(table.events[$0].time)s #\($0 + 1)" }
            let width = max(12, (anchors.map(\.count).max() ?? 0) + 2)
            func cell(_ value: String) -> String { value + String(repeating: " ", count: max(0, width - value.count)) }
            lines.append("")
            lines.append("time |" + anchors.map(cell).joined(separator: "|"))
            for lane in table.lanes {
                for string in 1...6 {
                    let cells = indices.map { i -> String in
                        let e = table.events[i]
                        return cell(e.lane == lane && e.string == string ? "\(e.tentative ? "~" : "")\(e.fret.map(String.init) ?? "?")[\(i + 1)]" : "---")
                    }
                    lines.append("\(lane == .left ? "L" : "R") s\(string) |" + cells.joined(separator: "|"))
                }
            }
            for i in indices {
                let e = table.events[i]
                let rhythm = showRhythm ? " length=\(e.length?.rawValue ?? "null")" : ""
                lines.append("#\(i + 1) id=\(e.id.uuidString) time=\(e.time) lane=\(e.lane.rawValue) string=\(e.string) fret=\(e.fret.map(String.init) ?? "null")\(rhythm) tentative=\(e.tentative)\(barAnchor(e, project: project)) memo=\(try quoted(e.memo))")
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard text.utf8.count <= maximumBytes else { throw ScoreExportError.limitExceeded }
        return text
    }

    static func barAnchor(_ event: TabEvent, project: ScoreProject) -> String {
        let bars = Array(Set((project.analyses[event.lane.rawValue] ?? project.analyses["stereo"])?.bars ?? [])).sorted()
        guard let index = bars.lastIndex(where: { $0 <= event.time }) else { return "" }
        return " analysis-bar=\(index + 1)@\(bars[index])s"
    }

    static func quoted<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
