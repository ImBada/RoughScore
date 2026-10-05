import Foundation
import RoughScoreCore

enum ScoreExportFormat: String, CaseIterable, Identifiable, Sendable {
    case tab, table, pdf, print
    var id: String { rawValue }
    var title: String { switch self { case .tab: "6줄 TAB"; case .table: "이벤트 표 (TSV)"; case .pdf: "PDF"; case .print: "인쇄" } }
    var fileExtension: String { switch self { case .tab: "txt"; case .table: "tsv"; case .pdf, .print: "pdf" } }
}

struct ScoreExportOptions: Equatable, Sendable {
    enum RangeChoice: String, CaseIterable, Identifiable, Sendable {
        case full, selected, custom
        var id: String { rawValue }
        var title: String { switch self { case .full: "곡 전체"; case .selected: "선택 시간 구간"; case .custom: "직접 지정" } }
    }
    enum Lanes: String, CaseIterable, Identifiable, Sendable {
        case both, left, right
        var id: String { rawValue }
        var title: String { switch self { case .both: "Guitar L + R"; case .left: "Guitar L"; case .right: "Guitar R" } }
        var values: Set<GuitarLane> { self == .both ? Set(GuitarLane.allCases) : [self == .left ? .left : .right] }
    }
    var format = ScoreExportFormat.tab
    var rangeChoice = RangeChoice.full
    var lanes = Lanes.both
    var start = "0"
    var end = "0"
    var paper = ScoreRenderPlan.Paper.a4
    var margin = 40.0
    var showRhythm = true
    var showWaveforms = false
    var settings: ScoreRenderPlan.Settings { .init(paper: paper, margin: margin, showRhythm: showRhythm, showWaveforms: showWaveforms) }
    func selection(_ snapshot: ScoreExportSnapshot) throws -> SparseTabExporter.Selection {
        let range: TimeSpan?
        switch rangeChoice {
        case .full: range = nil
        case .selected:
            guard let selected = snapshot.selectedRange else { throw ScoreExportError.invalidRange }
            range = selected
        case .custom:
            guard let first = Double(start.replacingOccurrences(of: ",", with: ".")),
                  let last = Double(end.replacingOccurrences(of: ",", with: ".")),
                  first.isFinite, last.isFinite, first >= 0, last >= first, last <= snapshot.project.duration
            else { throw ScoreExportError.invalidRange }
            range = TimeSpan(start: first, end: last)
        }
        return .init(range: range, lanes: lanes.values)
    }
}

/// Only immutable document/prepared-envelope values participate; no editor observers or players.
struct ScoreExportSnapshot: Identifiable, Sendable {
    let id = UUID()
    let projectID: UUID
    let initialFormat: ScoreExportFormat
    let project: ScoreProject
    let selectedRange: TimeSpan?
    let analysis: SparseTabExporter.AnalysisContext
    let waveform: ScoreRenderPlan.WaveformInput?
    let protectedFiles: [URL]
    let packageRoot: URL?
    func plan(_ options: ScoreExportOptions) throws -> ScoreRenderPlan {
        try ScoreRenderPlan(project: project, selection: options.selection(self), settings: options.settings,
                            analysis: analysis, waveform: waveform)
    }
    func bytes(_ options: ScoreExportOptions) throws -> Data {
        let selection = try options.selection(self)
        switch options.format {
        case .tab: return Data(try SparseTabExporter.tab(project, selection: selection, showRhythm: options.showRhythm, analysis: analysis).utf8)
        case .table: return Data(try SparseTabExporter.eventTable(project, selection: selection).utf8)
        case .pdf, .print: return try ScorePDFExporter.data(for: plan(options))
        }
    }
    func validateDestination(_ url: URL, format: ScoreExportFormat) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == format.fileExtension else { throw ScoreExportError.invalidSettings }
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        for file in protectedFiles {
            if destination.path == file.resolvingSymlinksInPath().standardizedFileURL.path { throw CocoaError(.fileWriteFileExists) }
            if let a = try? FileManager.default.attributesOfItem(atPath: destination.path),
               let b = try? FileManager.default.attributesOfItem(atPath: file.path),
               let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber,
               let aNode = a[.systemFileNumber] as? NSNumber, let bNode = b[.systemFileNumber] as? NSNumber,
               aDevice == bDevice, aNode == bNode { throw CocoaError(.fileWriteFileExists) }
        }
        if let packageRoot { try PortableProjectPackage.validateDestination(url, outside: packageRoot) }
    }
}
