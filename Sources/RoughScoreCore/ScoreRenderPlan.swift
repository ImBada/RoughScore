import Foundation

/// Static document plan. Each source event occurs once in `events`, and every
/// event index is placed in exactly one six-string system; dense notes never merge.
public struct ScoreRenderPlan: Sendable {
    public enum Paper: String, CaseIterable, Sendable { case a4, letter
        public var width: Double { self == .a4 ? 595.276 : 612 }
        public var height: Double { self == .a4 ? 841.89 : 792 }
    }
    public struct Settings: Equatable, Sendable {
        public var paper: Paper
        public var margin: Double
        public var minimumColumnWidth: Double
        public var fontSize: Double
        public var showRhythm: Bool
        public var showWaveforms: Bool
        public init(paper: Paper = .a4, margin: Double = 40, minimumColumnWidth: Double = 64,
                    fontSize: Double = 9, showRhythm: Bool = true, showWaveforms: Bool = false) {
            self.paper = paper; self.margin = margin; self.minimumColumnWidth = minimumColumnWidth
            self.fontSize = fontSize; self.showRhythm = showRhythm
            self.showWaveforms = showWaveforms
        }
    }
    public struct System: Sendable {
        public let top: Double
        public let height: Double
        public let lane: GuitarLane
        public let eventIndices: [Int]
    }
    public struct Text: Sendable {
        public let top: Double
        public let lines: [String]
        public let fontSize: Double
        public let height: Double
    }
    public struct WaveformInput: Sendable {
        public let duration: Double
        public let left: [Float]
        public let right: [Float]
        public let label: String
        public init(duration: Double, left: [Float], right: [Float], label: String) {
            self.duration = duration; self.left = left; self.right = right; self.label = label
        }
    }
    public struct Waveform: Sendable {
        public let top: Double
        public let height: Double
        public let lane: GuitarLane
        public let label: String
        public let peaks: [Float]
    }
    public enum Element: Sendable { case system(System), text(Text), waveform(Waveform) }
    public struct Page: Sendable {
        public let number: Int
        public let elements: [Element]
    }
    public let settings: Settings
    public let titleLines: [String]
    public let tuningLines: [String]
    public let analysisLines: [String]
    public let range: TimeSpan
    public let lanes: [GuitarLane]
    public let events: [TabEvent]
    public let pages: [Page]
    public let contentTop: Double
    public let contentBottom: Double
    public var noteIDs: [UUID] { events.map(\.id) }
    public var placedEventIndices: [Int] {
        pages.flatMap { $0.elements.flatMap { if case .system(let s) = $0 { return s.eventIndices }; return [] } }
    }

    public init(project: ScoreProject, selection: SparseTabExporter.Selection = .init(), settings: Settings = .init(),
                analysis: SparseTabExporter.AnalysisContext? = nil, waveform: WaveformInput? = nil) throws {
        guard settings.margin.isFinite, (24...90).contains(settings.margin),
              settings.minimumColumnWidth.isFinite, (48...160).contains(settings.minimumColumnWidth),
              settings.fontSize.isFinite, (7...14).contains(settings.fontSize) else { throw ScoreExportError.invalidSettings }
        let snapshot = try SparseTabExporter.snapshot(project, selection: selection)
        let width = settings.paper.width - settings.margin * 2
        let title = try ScorePDFExporter.wrappedLines(ScorePDFExporter.visible(snapshot.title), width: width, size: 16)
        let tuning = try ScorePDFExporter.wrappedLines(try SparseTabExporter.tuningHeader(for: project), width: width, size: 8)
        let context = analysis ?? SparseTabExporter.AnalysisContext(project: project)
        let analysisLines = try ScorePDFExporter.wrappedLines(context.caption, width: width, size: 8)
        guard title.count <= 4, tuning.count <= 6 else { throw ScoreExportError.limitExceeded }
        let top = settings.margin + Double(title.count) * 20 + Double(tuning.count + analysisLines.count) * 11 + 37
        let bottom = settings.paper.height - settings.margin - 23
        guard bottom - top >= 250 else { throw ScoreExportError.invalidSettings }
        let count = max(1, min(8, Int((width - 34) / settings.minimumColumnWidth)))
        let lineHeight = settings.fontSize * 1.45
        var pages = [Page](), elements = [Element](), y = top
        func finishPage() throws {
            guard pages.count < 512 else { throw ScoreExportError.limitExceeded }
            pages.append(Page(number: pages.count + 1, elements: elements)); elements = []; y = top
        }
        func appendText(_ lines: [String], size: Double) throws {
            let step = size * 1.45
            var start = 0
            while start < lines.count {
                try Task.checkCancellation()
                let capacity = Int((bottom - y) / step)
                if capacity < 1 { try finishPage(); continue }
                let end = min(lines.count, start + capacity)
                let slice = Array(lines[start..<end])
                elements.append(.text(Text(top: y, lines: slice, fontSize: size, height: Double(slice.count) * step)))
                y += Double(slice.count) * step; start = end
            }
        }
        if settings.showWaveforms {
            guard let waveform, waveform.duration.isFinite, waveform.duration > 0,
                  abs(waveform.duration - project.duration) < 0.05, waveform.label.utf8.count <= 256,
                  !waveform.left.isEmpty, !waveform.right.isEmpty,
                  waveform.left.count <= 8_640_000, waveform.right.count <= 8_640_000,
                  waveform.left.allSatisfy({ $0.isFinite }), waveform.right.allSatisfy({ $0.isFinite })
            else { throw ScoreExportError.invalidSettings }
            let bins = max(1, min(600, Int(width)))
            for lane in snapshot.lanes {
                if y + 78 > bottom { try finishPage() }
                let input = lane == .left ? waveform.left : waveform.right
                let span = snapshot.range.end - snapshot.range.start
                let peaks: [Float] = (0..<bins).map { index in
                    let start = snapshot.range.start + span * Double(index) / Double(bins)
                    let end = snapshot.range.start + span * Double(index + 1) / Double(bins)
                    return min(1, WaveformEnvelope.peak(input, duration: waveform.duration, from: start, to: end))
                }
                elements.append(.waveform(Waveform(top: y, height: 72, lane: lane, label: waveform.label, peaks: peaks)))
                y += 78
            }
        }
        if snapshot.events.isEmpty {
            try appendText(["No annotations in the selected range. Empty space is untranscribed, not a rest."], size: settings.fontSize)
        }
        // Chronological chunks, with separate six-string systems for each lane.
        // Every index belongs to one lane and is emitted once, even at identical times.
        for first in stride(from: 0, to: snapshot.events.count, by: count) {
            try Task.checkCancellation()
            let indices = Array(first..<min(snapshot.events.count, first + count))
            for lane in snapshot.lanes {
                let notes = indices.filter { snapshot.events[$0].lane == lane }
                if notes.isEmpty { continue }
                let systemHeight = 127.0
                // Keep the score with at least the first detail line on this page.
                if y + systemHeight + lineHeight > bottom { try finishPage() }
                elements.append(.system(System(top: y, height: systemHeight, lane: lane, eventIndices: notes)))
                y += systemHeight
                for index in notes {
                    let e = snapshot.events[index]
                    let rhythm = settings.showRhythm ? " length:\(e.length?.rawValue ?? "unspecified")" : ""
                    let header = "#\(index + 1) \(e.id.uuidString) | \(e.time)s \(e.lane.rawValue) s\(e.string) fret:\(e.fret.map(String.init) ?? "?")\(rhythm) tentative:\(e.tentative)\(SparseTabExporter.barAnchor(e, project: project, analysis: context))"
                    try appendText(ScorePDFExporter.wrappedLines(header, width: width, size: settings.fontSize), size: settings.fontSize)
                    if !e.memo.isEmpty {
                        try appendText(ScorePDFExporter.wrappedLines("memo: " + ScorePDFExporter.visible(e.memo), width: width, size: settings.fontSize), size: settings.fontSize)
                    }
                    y += 4
                    if y > bottom { try finishPage() }
                }
                y += 9
            }
        }
        if !elements.isEmpty || pages.isEmpty { try finishPage() }
        self.settings = settings; self.titleLines = title; self.tuningLines = tuning
        self.analysisLines = analysisLines
        self.range = snapshot.range; self.lanes = snapshot.lanes; self.events = snapshot.events
        self.pages = pages; self.contentTop = top; self.contentBottom = bottom
        guard placedEventIndices.sorted() == Array(events.indices) else { throw ScoreExportError.renderingFailed }
    }
}
