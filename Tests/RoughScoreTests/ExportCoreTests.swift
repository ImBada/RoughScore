import Foundation
import PDFKit
import CoreGraphics
import RoughScoreCore
import Testing

struct ExportCoreTests {
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    static func sample() -> ScoreProject {
        ScoreProject(title: "밤의 기타 - 부분 채보", duration: 12, events: [
            TabEvent(id: id(1), time: -0.0, lane: .left, string: 6, fret: 0, memo: "시작"),
            TabEvent(id: id(2), time: 3.125, lane: .left, string: 6, fret: 12, length: .eighth, tentative: true, memo: "한글\n탭\t\"quote\" literal \\n e\u{301}"),
            TabEvent(id: id(3), time: 3.125, lane: .left, string: 6, fret: nil, length: nil, memo: "같은 줄 동시 음"),
            TabEvent(id: id(4), time: 3.125, lane: .right, string: 1, fret: 24, length: .quarter),
            TabEvent(id: id(5), time: 9.999999999999998, lane: .right, string: 2, fret: nil, tentative: true, memo: "미채보와 쉼표는 다름")
        ], analyses: ["left": AnalysisSummary(bars: [0, 2.75, 5.25]), "right": AnalysisSummary(bars: [1, 3, 9])])
    }
    static func dense() -> ScoreProject {
        var events = [TabEvent]()
        for i in 0..<720 {
            events.append(TabEvent(id: id(i + 100), time: Double(i / 2) * 0.5,
                lane: i % 3 == 0 ? .right : .left, string: i % 6 + 1,
                fret: i % 7 == 0 ? nil : i % 25, length: i % 4 == 0 ? .sixteenth : nil,
                tentative: i % 9 == 0, memo: i % 31 == 0 ? "밀집 동시 음 \(i)\n수동 시간 유지" : ""))
        }
        var project = ScoreProject(title: "3분 밀집 - 생성된 수동 예시", duration: 180, events: events,
                                   analyses: ["stereo": AnalysisSummary(bars: stride(from: 0.0, to: 180, by: 4).map { $0 })])
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
        return project
    }

    @Test func eventTableRoundTripsEveryAttributeAndLiteralEscape() throws {
        var project = Self.sample()
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
        let table = try SparseTabExporter.eventTable(project)
        #expect(table.components(separatedBy: "\n").count == project.events.count + 4)
        #expect(table.contains("\\t") && table.contains("\\n") && table.contains("\\\""))
        let decoded = try SparseTabExporter.parseEventTable(Data(table.utf8))
        #expect(decoded.events == project.events)
        #expect(decoded.tuningDefinition == project.tuningDefinition && decoded.title == project.title)
        for (a, b) in zip(project.events, decoded.events) {
            #expect(a.time.bitPattern == b.time.bitPattern)
            #expect(a.memo.utf8.elementsEqual(b.memo.utf8))
        }
        #expect(project.events == Self.sample().events)
    }

    @Test func sparseTabContainsSixStringsBothLanesAndAllCoincidentEvents() throws {
        let project = Self.sample(), text = try SparseTabExporter.tab(project, columnsPerSystem: 3)
        for lane in ["L", "R"] { for string in 1...6 { #expect(text.contains("\(lane) s\(string) |")) } }
        for event in project.events { #expect(text.components(separatedBy: event.id.uuidString).count - 1 == 1) }
        #expect(text.contains("~12[2]") && text.contains("?[3]") && text.contains("24[4]"))
        #expect(text.contains("analysis-bar=2@2.75s"))
        #expect(text.contains("length=null") && text.contains("untranscribed, not rest"))
        #expect(project == Self.sample())
    }

    @Test func actualTuningCapoAndUnresolvedLabelsHaveHonestHeaders() throws {
        var project = Self.sample()
        #expect(try SparseTabExporter.tuningHeader(for: project).contains("Standard legacy"))
        project.tuningDefinition = TuningDefinition(capo: 3)
        let standard = try SparseTabExporter.tuningHeader(for: project)
        #expect(standard.contains("capo 3") && standard.contains("G4"))
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
        let dropD = try SparseTabExporter.tuningHeader(for: project)
        #expect(dropD.contains("Drop D") && dropD.contains("D2 (38)") && dropD.contains("capo 2") && dropD.contains("capo-relative"))
        project.tuningDefinition = TuningDefinition(openMIDIPitches: [65, 58, 54, 49, 44, 39], capo: 3)
        let custom = try SparseTabExporter.tuningHeader(for: project)
        #expect(custom.contains("Custom") && custom.contains("capo 3") && custom.contains("D#2 (39)"))
        project.tuningDefinition = nil; project.tuning = ["D", "A", "F", "C", "G", "D"]
        let unknown = try SparseTabExporter.tuningHeader(for: project)
        #expect(unknown.contains("Unresolved") && unknown.contains("unknown") && !unknown.contains("D2"))
    }

    @Test func selectionIsHalfOpenAndLeavesExactOriginalTimesAndSourceUntouched() throws {
        let project = Self.sample()
        let selection = SparseTabExporter.Selection(range: TimeSpan(start: 3.125, end: 9.999999999999998), lanes: [.left, .right])
        let table = try SparseTabExporter.parseEventTable(Data(SparseTabExporter.eventTable(project, selection: selection).utf8))
        #expect(table.events.map(\.id) == [Self.id(2), Self.id(3), Self.id(4)])
        #expect(table.events.allSatisfy { $0.time == 3.125 })
        let plan = try ScoreRenderPlan(project: project, selection: selection)
        #expect(plan.events == table.events && plan.placedEventIndices.sorted() == [0, 1, 2])
        #expect(project == Self.sample())
        let left = try ScoreRenderPlan(project: project, selection: .init(lanes: [.left]))
        #expect(left.events.map(\.id) == [Self.id(1), Self.id(2), Self.id(3)])
    }

    @Test(arguments: ScoreRenderPlan.Paper.allCases)
    func threeMinuteDensePaginationPreservesEveryNoteOnce(paper: ScoreRenderPlan.Paper) throws {
        let project = Self.dense()
        let plan = try ScoreRenderPlan(project: project, settings: .init(paper: paper, minimumColumnWidth: 48))
        #expect(plan.pages.count > 1)
        #expect(plan.noteIDs == project.events.map(\.id))
        #expect(plan.placedEventIndices.sorted() == Array(project.events.indices))
        for page in plan.pages { for element in page.elements {
            switch element {
            case .system(let system): #expect(system.top >= plan.contentTop && system.top + system.height <= plan.contentBottom)
            case .text(let text): #expect(text.top >= plan.contentTop && text.top + text.height <= plan.contentBottom + 0.00001)
            case .waveform(let wave): #expect(wave.top >= plan.contentTop && wave.top + wave.height <= plan.contentBottom + 0.00001)
            }
        } }
        #expect(project == Self.dense())
    }

    @Test func widthAndRhythmPresentationDoNotChangeAnnotations() throws {
        let project = Self.sample()
        let narrow = try ScoreRenderPlan(project: project, settings: .init(margin: 80, minimumColumnWidth: 140, showRhythm: false))
        let wide = try ScoreRenderPlan(project: project, settings: .init(minimumColumnWidth: 48, showRhythm: true))
        #expect(narrow.events == wide.events && narrow.noteIDs == wide.noteIDs)
        #expect(narrow.placedEventIndices.count == 5 && wide.placedEventIndices.count == 5)
        let noRhythm = try SparseTabExporter.tab(project, showRhythm: false)
        #expect(!noRhythm.contains("length="))
        #expect(project.events[1].length == .eighth && project.events[2].length == nil)
    }

    @Test func nativePDFContainsEveryIDOnceAndKoreanTextWithoutTransportChrome() throws {
        let project = Self.sample(), plan = try ScoreRenderPlan(project: project)
        let bytes = try ScorePDFExporter.data(for: plan)
        let pdf = try #require(PDFDocument(data: bytes))
        #expect(pdf.pageCount == plan.pages.count)
        let text = try #require(pdf.string)
        for e in project.events { #expect(text.components(separatedBy: e.id.uuidString).count - 1 == 1) }
        #expect(text.contains("밤의 기타") && text.contains("같은 줄 동시 음") && text.contains("Guitar L") && text.contains("Guitar R"))
        #expect(!text.contains("Play") && !text.contains("transport") && !text.contains("Drag"))
        #expect(project == Self.sample())
    }

    @Test func longMemoWrapsAcrossPagesWithoutDroppingContentOrDuplicatingID() throws {
        let memo = (0..<180).map { "한글 메모 줄 \($0) - 보존" }.joined(separator: "\n")
        let event = TabEvent(id: Self.id(9000), time: 1, lane: .left, string: 2, memo: memo)
        let project = ScoreProject(duration: 3, events: [event])
        let plan = try ScoreRenderPlan(project: project)
        #expect(plan.pages.count > 1 && plan.placedEventIndices == [0])
        let pdf = try #require(PDFDocument(data: ScorePDFExporter.data(for: plan)))
        let text = try #require(pdf.string)
        #expect(text.components(separatedBy: event.id.uuidString).count - 1 == 1)
        #expect(text.contains("한글 메모 줄 0") && text.contains("한글 메모 줄 179"))
    }

    @Test func everyPageHeaderRendersAfterIndependentGraphicsStateReset() throws {
        let events = (0..<60).map { TabEvent(id: Self.id($0 + 2000), time: Double($0) * 0.25, lane: .left, string: 1, fret: $0 % 25) }
        let project = ScoreProject(title: "HEADER 한글", duration: 20, events: events)
        let plan = try ScoreRenderPlan(project: project)
        let bytes = try ScorePDFExporter.data(for: plan)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        #expect(pdf.numberOfPages > 1)
        for number in [1, pdf.numberOfPages] {
            let page = try #require(pdf.page(at: number))
            let width = Int(plan.settings.paper.width), height = Int(plan.settings.paper.height)
            let bitmap = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.drawPDFPage(page)
            let raw = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
            // Bitmap rows are top-down. The actual title glyphs occupy this fixed
            // header band, independently of PDF text extraction's cached mappings.
            var dark = 0
            for y in 38..<68 { for x in 40..<180 {
                let offset = (y * width + x) * 4
                if raw[offset] < 100 && raw[offset + 1] < 100 && raw[offset + 2] < 100 { dark += 1 }
            } }
            #expect(dark > 50, "actual raster title pixels on page \(number)")
        }
    }

    @Test func emptyAndTinyPositiveSelectionsRemainUntranscribed() throws {
        let project = ScoreProject(duration: Double.leastNonzeroMagnitude,
                                   events: [TabEvent(id: Self.id(1), time: 0, lane: .left, string: 1)])
        let plan = try ScoreRenderPlan(project: project)
        #expect(plan.noteIDs == [Self.id(1)])
        let empty = try ScoreRenderPlan(project: project, selection: .init(range: TimeSpan(start: 0, end: 0)))
        #expect(empty.events.isEmpty && empty.pages.count == 1)
        #expect(try SparseTabExporter.tab(project, selection: .init(lanes: [.right])).contains("No annotations"))
    }

    @Test func malformedTablesAndUnsafeSettingsFailSafely() throws {
        let project = Self.sample()
        #expect(throws: ScoreExportError.invalidSettings) { try SparseTabExporter.tab(project, columnsPerSystem: 0) }
        #expect(throws: ScoreExportError.invalidSettings) { try ScoreRenderPlan(project: project, settings: .init(margin: .nan)) }
        #expect(throws: ScoreExportError.invalidSettings) { try ScoreRenderPlan(project: project, settings: .init(fontSize: 0)) }
        #expect(throws: ScoreExportError.invalidSettings) { try ScoreRenderPlan(project: project, selection: .init(lanes: [])) }
        for span in [TimeSpan(start: -1, end: 2), TimeSpan(start: 4, end: 3), TimeSpan(start: .nan, end: 2), TimeSpan(start: 0, end: 13)] {
            #expect(throws: ScoreExportError.invalidRange) { try ScoreRenderPlan(project: project, selection: .init(range: span)) }
        }
        let table = try SparseTabExporter.eventTable(project)
        #expect(throws: ScoreExportError.unsupportedTableVersion) { try SparseTabExporter.parseEventTable(Data(table.replacingOccurrences(of: "#roughscore-event-table\t1", with: "#roughscore-event-table\t2").utf8)) }
        #expect(throws: (any Error).self) { try SparseTabExporter.parseEventTable(Data(table.replacingOccurrences(of: "3.125", with: "1e999").utf8)) }
        #expect(throws: (any Error).self) { try SparseTabExporter.parseEventTable(Data(table.replacingOccurrences(of: Self.id(2).uuidString, with: Self.id(1).uuidString).utf8)) }
        #expect(throws: ScoreExportError.invalidTable) { try SparseTabExporter.parseEventTable(Data(repeating: 32, count: SparseTabExporter.maximumBytes + 1)) }
        var tooLarge = project; tooLarge.events[0].memo = String(repeating: "x", count: SparseTabExporter.maximumMemoBytes + 1)
        #expect(throws: ScoreExportError.limitExceeded) { try ScoreRenderPlan(project: tooLarge) }
    }
}
