import SwiftUI
import PDFKit
import RoughScoreCore

struct ScoreExportOptionsView: View {
    let snapshot: ScoreExportSnapshot
    let submit: (ScoreExportOptions) -> Void
    let cancel: () -> Void
    @State private var options: ScoreExportOptions
    @State private var preview: Data?
    @State private var message: String?
    @State private var previewing = false
    init(snapshot: ScoreExportSnapshot, format: ScoreExportFormat, submit: @escaping (ScoreExportOptions) -> Void, cancel: @escaping () -> Void) {
        self.snapshot = snapshot; self.submit = submit; self.cancel = cancel
        var value = ScoreExportOptions(); value.format = format; value.end = String(snapshot.project.duration)
        _options = State(initialValue: value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TAB · 표 · PDF 내보내기").font(.title2)
            Text(snapshot.project.title).font(.headline)
            Form {
                Picker("형식", selection: $options.format) { ForEach(ScoreExportFormat.allCases) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("export-format")
                Picker("시간 범위", selection: $options.rangeChoice) {
                    Text("곡 전체").tag(ScoreExportOptions.RangeChoice.full)
                    Text("선택 시간 구간").tag(ScoreExportOptions.RangeChoice.selected).disabled(snapshot.selectedRange == nil)
                    Text("직접 지정").tag(ScoreExportOptions.RangeChoice.custom)
                }.accessibilityIdentifier("export-range")
                if options.rangeChoice == .custom {
                    HStack {
                        TextField("시작 초", text: $options.start).accessibilityIdentifier("export-start")
                        TextField("끝 초", text: $options.end).accessibilityIdentifier("export-end")
                    }
                } else if options.rangeChoice == .selected, let range = snapshot.selectedRange {
                    Text("\(range.start) - \(range.end)초 · 끝점은 포함하지 않습니다")
                }
                Picker("기타 메모", selection: $options.lanes) { ForEach(ScoreExportOptions.Lanes.allCases) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("export-lanes")
                Toggle("기록된 음표 길이 표시", isOn: $options.showRhythm).disabled(options.format == .table)
                if options.format == .pdf || options.format == .print {
                    Picker("용지", selection: $options.paper) { Text("A4").tag(ScoreRenderPlan.Paper.a4); Text("Letter").tag(ScoreRenderPlan.Paper.letter) }
                    HStack { Text("여백 \(Int(options.margin))pt"); Slider(value: $options.margin, in: 24...90, step: 1) }
                    Toggle("준비된 L/R 파형 개요", isOn: $options.showWaveforms).disabled(snapshot.waveform == nil)
                    if snapshot.waveform == nil { Text("준비된 오디오가 없어 파형을 포함할 수 없습니다.").font(.caption) }
                }
            }
            Text("박·파형 출처: \(snapshot.analysis.label) · 원곡 초 단위 위치\n빈칸은 미채보이며 쉼표나 음표 길이를 추정하지 않습니다.").font(.caption)
            if let message { Text(message).foregroundStyle(.red).font(.caption) }
            if let preview { ExportPDFPreview(data: preview).frame(height: 270) }
            HStack {
                Button("취소", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if options.format == .pdf || options.format == .print {
                    Button("문서 미리보기") {
                        let requested = options
                        previewing = true
                        Task {
                            do {
                                let bytes = try await Task.detached(priority: .userInitiated) { try snapshot.bytes(requested) }.value
                                if requested == options { preview = bytes; message = nil }
                            } catch { if requested == options { message = error.localizedDescription } }
                            previewing = false
                        }
                    }.disabled(previewing).accessibilityIdentifier("export-preview")
                }
                Button(options.format == .print ? "인쇄 대화상자…" : "내보내기…") {
                    do { _ = try options.selection(snapshot); submit(options) } catch { message = "시작·끝 위치를 곡의 유효 범위로 지정하세요." }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("export-submit")
            }
        }.padding(24).frame(width: 580).onChange(of: options) { _, _ in preview = nil }
    }
}

private struct ExportPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) { view.document = PDFDocument(data: data) }
}

struct ScoreExportCommands: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        ForEach([ScoreExportFormat.tab, .table, .pdf]) { format in
            Button(format.title + " 내보내기…") { workspace.beginExport(format) }.disabled(!workspace.canExport)
        }
    }
}
struct ScoreExportMenu: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        BulkActionMenu(title: "내보내기", identifier: "score-export-menu", enabled: workspace.canExport,
            items: ScoreExportFormat.allCases.map { format in .init(title: format.title + "…", action: { workspace.beginExport(format) }) })
    }
}
