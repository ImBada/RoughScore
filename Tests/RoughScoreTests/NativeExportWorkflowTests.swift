import AppKit
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@MainActor private final class ExportCapture {
    var documents = 0
    var sessions = 0
    var outputs: [Data] = []
    var cancel = false
    var fail = false
    var destination: URL?
    var onChoose: (@MainActor @Sendable () -> Void)?
    var savedDuringModal = false
}

@MainActor @Suite(.serialized)
struct NativeExportWorkflowTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RoughScore-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func services(_ capture: ExportCapture) -> WorkspaceServices {
        var s = WorkspaceServices.isolatedCache()
        s.initialProject = { nil }; s.lastProject = { nil }; s.rememberProject = { _ in }
        s.sessionStore.write = { _, _, _ in capture.sessions += 1 }
        s.writeProject = { data, url in capture.documents += 1; try data.write(to: url, options: .atomic) }
        s.exportServices.chooseDestination = { _, _ in capture.onChoose?(); return capture.destination }
        s.exportServices.write = { data, url in
            if capture.fail { throw CocoaError(.fileWriteNoPermission) }
            capture.outputs.append(data); try data.write(to: url, options: .atomic)
        }
        s.exportServices.print = { data, _ in capture.outputs.append(data); return !capture.cancel }
        return s
    }
    private struct State: Equatable {
        let project: ScoreProject
        let selection: Set<UUID>
        let cursor: Double
        let source: ListeningSource
        let lane: GuitarLane
        let windowStart: Double
        let windowLength: Double
        let page: Int
        let follow: Bool
        let lengths: Bool
        let dirty: Bool
        let undo: Bool
        let redo: Bool
        let url: URL?
        @MainActor init(_ w: Workspace) {
            project = w.project; selection = w.selectedIDs; cursor = w.cursor; source = w.source; lane = w.lane
            windowStart = w.windowStart; windowLength = w.windowLength; page = w.scorePage; follow = w.followScore
            lengths = w.showLengths; dirty = w.dirty; undo = w.canUndo; redo = w.canRedo; url = w.activeProjectURL
        }
    }

    @Test func actualRequestFormatsRangesAndDialogsPreserveDocumentSessionAndHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        w.project = ExportCoreTests.sample(); w.project.tuningDefinition = .init(openMIDIPitches: [64,59,55,50,45,38], capo: 2)
        let document = root.appendingPathComponent("input.roughscore")
        #expect(w.saveAs(to: document))
        w.select(w.project.events[1]); w.showLengths = false; w.lane = .right; w.windowLength = 2; w.followScore = false
        w.flushSession()
        let state = State(w), original = try Data(contentsOf: document), documents = capture.documents, sessions = capture.sessions
        for format in ScoreExportFormat.allCases {
            w.beginExport(format); let snapshot = try #require(w.exportSnapshot)
            var options = ScoreExportOptions(); options.format = format; options.rangeChoice = .custom
            options.start = "3.125"; options.end = "9.999999999999998"; options.lanes = .both
            let output = root.appendingPathComponent(format.rawValue + "." + format.fileExtension)
            #expect(await w.completeExport(snapshot, options: options, to: output))
            let data = try #require(capture.outputs.last)
            if format == .table {
                let table = try SparseTabExporter.parseEventTable(data)
                #expect(table.events == state.project.events.filter { $0.time >= 3.125 && $0.time < 9.999999999999998 })
                #expect(table.events[0].memo.utf8.elementsEqual(state.project.events[1].memo.utf8))
            } else if format == .tab {
                let text = String(decoding: data, as: UTF8.self)
                #expect(text.contains("L s6 |") && text.contains("R s1 |") && text.contains("capo 2") && text.contains("\\t"))
            } else {
                let pdf = try #require(PDFDocument(data: data)), text = try #require(pdf.string)
                for event in state.project.events where event.time == 3.125 { #expect(text.components(separatedBy: event.id.uuidString).count - 1 == 1) }
                #expect(!text.contains(state.project.events[0].id.uuidString))
            }
            #expect(State(w) == state && capture.documents == documents && capture.sessions == sessions)
            #expect(try Data(contentsOf: document) == original)
        }
        w.beginExport(.pdf); let cancelled = try #require(w.exportSnapshot)
        var options = ScoreExportOptions(); options.format = .pdf
        #expect(await w.completeExport(cancelled, options: options) == false) // Actual destination seam cancellation.
        #expect(State(w) == state)
        capture.fail = true; w.beginExport(.table); let failed = try #require(w.exportSnapshot); options.format = .table
        #expect(await w.completeExport(failed, options: options, to: root.appendingPathComponent("failed.tsv")) == false)
        #expect(State(w) == state && capture.documents == documents && capture.sessions == sessions)
    }

    @Test func cancellationDuringDestinationModalCannotPublishTheSnapshot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        let before = State(w)
        capture.destination = root.appendingPathComponent("cancelled.txt")
        capture.onChoose = { [weak w] in w?.cancelExport() }
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        #expect(await w.completeExport(snapshot, options: .init()) == false)
        #expect(capture.outputs.isEmpty && State(w) == before && !FileManager.default.fileExists(atPath: capture.destination!.path))
    }

    @Test(arguments: [false, true])
    func reentrantCollectedSaveAsInvalidatesExportAndPreservesNewPackage(overwriteMedia: Bool) async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let generated = try h.fixture("export-storage-change", duration: 3)
        let source = h.evidence.appendingPathComponent(overwriteMedia ? "source.txt" : "source.caf")
        try FileManager.default.copyItem(at: generated, to: source)
        let bytes = try Data(contentsOf: source), asset = AudioAsset(reference: .init(path: source.path))
        let package = h.evidence.appendingPathComponent("active.roughscorepkg")
        let media = package.appendingPathComponent("Media/" + asset.id.uuidString + (overwriteMedia ? ".txt" : ".caf"))
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        w.project = ScoreProject(audioPath: source.path, duration: 3); w.project.assets = [asset]
        capture.destination = overwriteMedia ? media : package.appendingPathComponent("shared-tab.txt")
        capture.onChoose = { [weak w] in capture.savedDuringModal = w?.saveAs(to: package, format: .collected) == true }
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        #expect(await w.completeExport(snapshot, options: .init()) == false)
        #expect(capture.savedDuringModal && capture.outputs.isEmpty && w.exportSnapshot == nil)
        #expect(w.activeProjectURL == package && (try? PortableProjectPackage.read(at: package)) != nil)
        #expect(try Data(contentsOf: media) == bytes && Data(contentsOf: source) == bytes)
    }

    @Test func cancelledTaskReturningDestinationCannotWriteOrReportAnError() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        capture.destination = root.appendingPathComponent("cancelled.txt")
        capture.onChoose = { withUnsafeCurrentTask { $0?.cancel() } }
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        let operation = Task { await w.completeExport(snapshot, options: .init()) }
        #expect(await operation.value == false)
        #expect(capture.outputs.isEmpty && w.error == nil && !FileManager.default.fileExists(atPath: capture.destination!.path))
    }

    @Test func ordinarySaveAndSaveCopyRetainAnUnchangedActiveExportBinding() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        let active = root.appendingPathComponent("active.roughscore")
        #expect(w.saveAs(to: active))
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        #expect(w.save(to: active) && w.exportSnapshot?.id == snapshot.id)
        #expect(w.saveCopy(to: root.appendingPathComponent("copy.roughscore")) && w.exportSnapshot?.id == snapshot.id)
        #expect(await w.completeExport(snapshot, options: .init(), to: root.appendingPathComponent("score.txt")))
        #expect(capture.outputs.count == 1 && w.activeProjectURL == active)
    }

    @Test func protectedInputsPackageAliasesInvalidRangeAndDragAreRejected() async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let original = try h.fixture("protected", duration: 3)
        let w = Workspace(services: h.services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        let package = h.evidence.appendingPathComponent("input.roughscorepkg")
        #expect(w.saveAs(to: package, format: .collected))
        w.beginExport(.pdf); let snapshot = try #require(w.exportSnapshot)
        let alias = h.evidence.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package)
        #expect(throws: (any Error).self) { try snapshot.validateDestination(alias.appendingPathComponent("output.pdf"), format: .pdf) }
        let collision = h.evidence.appendingPathComponent("input.pdf")
        try FileManager.default.linkItem(at: package.appendingPathComponent("project.json"), to: collision)
        #expect(throws: (any Error).self) { try snapshot.validateDestination(collision, format: .pdf) }
        var options = ScoreExportOptions(); options.rangeChoice = .custom; options.start = "NaN"; options.end = "3"
        #expect(throws: ScoreExportError.invalidRange) { _ = try snapshot.bytes(options) }
        w.cancelExport(); w.addEvent(time: 1, string: 2); w.beginPositionDrag(try #require(w.selected))
        #expect(!w.canExport); w.beginExport(.tab); #expect(w.exportSnapshot == nil && w.positionDrag != nil)
        w.cancelPositionDrag()
    }

    @Test func stemAnalysisAnchorsAndWaveformRangeAreExplicitWithoutChangingProject() throws {
        var project = ExportCoreTests.sample()
        let original = AudioAsset(role: .original, reference: .init(path: "/generated/original.caf"))
        let stem = AudioAsset(role: .importedGuitarStem, reference: .init(path: "/generated/stem.caf"))
        project.assets = [original, stem]
        project.audioPath = original.reference.path
        project.analyses[project.analysisKey(asset: stem, channel: .left)] = AnalysisSummary(bars: [0, 3, 8])
        let before = project, context = SparseTabExporter.AnalysisContext(project: project, asset: stem)
        let tab = try SparseTabExporter.tab(project, analysis: context)
        #expect(tab.contains("Imported Stem") && tab.contains("analysis-bar=2@3.0s") && !tab.contains("analysis-bar=2@2.75s"))
        let wave = ScoreRenderPlan.WaveformInput(duration: 12, left: [0, 0.8, 0, 0], right: [0, 0, 0.6, 0], label: "Imported Stem")
        let plan = try ScoreRenderPlan(project: project, selection: .init(range: .init(start: 3.1, end: 6.1)),
            settings: .init(showWaveforms: true), analysis: context, waveform: wave)
        let waves = plan.pages.flatMap(\.elements).compactMap { element -> ScoreRenderPlan.Waveform? in if case .waveform(let value) = element { return value }; return nil }
        #expect(waves.count == 2 && waves[0].peaks.max() == 0.8 && waves[1].peaks.max() == 0.6)
        let data = try ScorePDFExporter.data(for: plan), pdf = try #require(PDFDocument(data: data)), text = try #require(pdf.string)
        #expect(text.contains("Imported Stem audio L overview") && text.contains("original-second axis"))
        #expect(plan.placedEventIndices.sorted() == Array(plan.events.indices) && project == before)
        let absent = ScoreProject(duration: 5)
        #expect(try SparseTabExporter.tab(absent).contains("no stored bar analysis"))
        #expect(throws: ScoreExportError.invalidSettings) { _ = try ScoreRenderPlan(project: project, settings: .init(showWaveforms: true)) }
    }

    @Test func realNativeMenuAndPrintOperationUseIndependentOptions() throws {
        _ = NSApplication.shared
        let capture = ExportCapture(), w = Workspace(services: services(capture)); defer { w.shutdown() }
        let before = State(w)
        let host = NotePointerTests.Host(ScoreExportMenu(workspace: w), height: 80, width: 500); defer { host.close() }; host.settle()
        let menu = try #require(host.descendants().compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "score-export-menu" })
        let items = try #require(menu.menu).items.filter { $0.target is BulkActionMenu.Coordinator }
        #expect(items.count == 4)
        for item in items {
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
            #expect(w.exportSnapshot != nil && State(w) == before)
            w.cancelExport()
        }
        let shared = NSPrintInfo.shared, size = shared.paperSize, left = shared.leftMargin
        let settings = ScoreRenderPlan.Settings(paper: .letter)
        let data = try ScorePDFExporter.data(for: ScoreRenderPlan(project: ExportCoreTests.sample(), settings: settings))
        let (document, operation) = try NativeScorePrint.operation(data, settings: settings)
        print("Native print configuration requested=Letter actual=\(operation.printInfo.paperSize) shared=\(shared.paperSize)")
        #expect(document.pageCount > 0 && operation.showsPrintPanel)
        // PrintManager's millimetre conversion differs by 0.000025pt from the PDF media box.
        #expect(abs(operation.printInfo.paperSize.width - 612) < 0.001 && abs(operation.printInfo.paperSize.height - 792) < 0.001)
        #expect(shared.paperSize == size && shared.leftMargin == left)
        // Never run a physical print job in automated tests.
    }

}

struct ExportDocumentGeometryTests {
    @Test(arguments: ScoreRenderPlan.Paper.allCases)
    func threeMinuteWaveformPDFsAndSelectedRhythmOffPreserveEveryChosenNote(paper: ScoreRenderPlan.Paper) throws {
        let project = ExportCoreTests.dense(), count = 1800
        let peaks = (0..<count).map { Float($0 % 13) / 13 }
        let wave = ScoreRenderPlan.WaveformInput(duration: 180, left: peaks, right: peaks.reversed(), label: "Generated Original")
        for range in [TimeSpan(start: 0, end: 180), TimeSpan(start: 47.125, end: 83.125)] {
            let plan = try ScoreRenderPlan(project: project, selection: .init(range: range),
                settings: .init(paper: paper, showRhythm: range.start == 0, showWaveforms: true), waveform: wave)
            let data = try ScorePDFExporter.data(for: plan), pdf = try #require(PDFDocument(data: data)), text = try #require(pdf.string)
            for event in plan.events { #expect(text.components(separatedBy: event.id.uuidString).count - 1 == 1) }
            #expect(plan.placedEventIndices.sorted() == Array(plan.events.indices))
            for page in plan.pages { for element in page.elements {
                switch element {
                case .system(let s): #expect(s.top >= plan.contentTop && s.top + s.height <= plan.contentBottom)
                case .text(let t): #expect(t.top >= plan.contentTop && t.top + t.height <= plan.contentBottom + 0.00001)
                case .waveform(let w): #expect(w.top >= plan.contentTop && w.top + w.height <= plan.contentBottom)
                }
            } }
            if let output = ProcessInfo.processInfo.environment["ROUGH_SCORE_EXPORT_QA_ROOT"] {
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(paper.rawValue)-\(range.start == 0 ? "full" : "selected").pdf"))
            }
        }
    }
}
