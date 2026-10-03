import AppKit
import RoughScoreCore
import SwiftUI

private enum Paper {
    static let background = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let ink = Color(red: 0.17, green: 0.21, blue: 0.20)
    static let muted = Color(red: 0.49, green: 0.51, blue: 0.47)
    static let accent = Color(red: 0.20, green: 0.43, blue: 0.32)
}

private func scoreTime(_ time: Double) -> String {
    String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
}

struct ScoreSheetView: View {
    @ObservedObject var workspace: Workspace
    @State private var fitPage = false
    @State private var paperHeight = 740.0

    var body: some View {
        let layout = workspace.scoreLayout
        let page = workspace.displayedScorePage
        let currentRowID = layout.rows(on: page).first { workspace.cursor >= $0.start && workspace.cursor < $0.end }?.id
        VStack(spacing: 12) {
            SongOverview(workspace: workspace, layout: layout)
            controls(layout: layout, page: page)
            GeometryReader { geometry in
                let scale = fitPage ? min(1, geometry.size.height / max(1, paperHeight)) : 1
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.project.title).font(.system(size: 18, weight: .semibold))
                                Text(workspace.showBothLanes ? "Guitar L + R · Standard tuning" : "\(workspace.lane.title) · Standard tuning")
                                    .font(.system(size: 10)).foregroundStyle(Paper.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(page + 1) / \(layout.pageCount)").font(.system(size: 12, design: .monospaced))
                                Text(layout.usesDetectedBars ? "검출 마디 기준" : "분석 전 · 시간 구간 기준")
                                    .font(.system(size: 9)).foregroundStyle(Paper.muted)
                            }
                        }.padding(.bottom, 14).id("page-top")
                        ForEach(layout.rows(on: page)) { row in
                            system(row, layout: layout, scale: scale).id(row.id)
                        }
                        HStack {
                            Text("빈칸 = 미채보    ? = 음 미확인    점선 = 잠정 프렛")
                            Spacer()
                            Text("\(page + 1)")
                        }.font(.system(size: 9)).foregroundStyle(Paper.muted).padding(.top, 12)
                    }.padding(22).foregroundStyle(Paper.ink)
                        .frame(width: geometry.size.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Paper.background, in: RoundedRectangle(cornerRadius: 4))
                        .background(GeometryReader { natural in
                            Color.clear.preference(key: PaperHeightKey.self, value: natural.size.height)
                        })
                        .scaleEffect(scale, anchor: .top)
                        .frame(height: paperHeight * scale, alignment: .top)
                }
                .onPreferenceChange(PaperHeightKey.self) { paperHeight = $0 }
                .onChange(of: page) { _, _ in proxy.scrollTo("page-top", anchor: .top) }
                .onChange(of: currentRowID) { _, rowID in
                    if workspace.playing && workspace.followScore && !fitPage && workspace.selectedID == nil, let rowID {
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(rowID, anchor: .top) }
                    }
                }
                }
            }
        }
        .onChange(of: workspace.measuresPerSystem) { previous, _ in
            workspace.reflowScore(from: ScoreLayout(duration: workspace.project.duration, bars: workspace.scoreSummary?.bars ?? [],
                                                   measuresPerSystem: previous, systemsPerPage: workspace.showBothLanes ? 2 : 4))
        }
        .onChange(of: workspace.showBothLanes) { previous, _ in
            workspace.reflowScore(from: ScoreLayout(duration: workspace.project.duration, bars: workspace.scoreSummary?.bars ?? [],
                                                   measuresPerSystem: workspace.measuresPerSystem, systemsPerPage: previous ? 2 : 4))
        }
        .onChange(of: workspace.project.analyses) { previous, _ in
            let summary = previous["stereo"] ?? previous[workspace.source.rawValue] ?? previous["left"] ?? previous["right"]
            workspace.reflowScore(from: ScoreLayout(duration: workspace.project.duration, bars: summary?.bars ?? [],
                                                   measuresPerSystem: workspace.measuresPerSystem, systemsPerPage: workspace.showBothLanes ? 2 : 4))
        }
    }

    private func controls(layout: ScoreLayout, page: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
            Picker("한 줄", selection: $workspace.measuresPerSystem) {
                Text(layout.usesDetectedBars ? "4마디 / 줄" : "8초 / 줄").tag(4)
                Text(layout.usesDetectedBars ? "8마디 / 줄" : "16초 / 줄").tag(8)
            }.labelsHidden().frame(width: 110)
            Toggle("L/R 함께", isOn: $workspace.showBothLanes)
            Toggle("음표 길이", isOn: $workspace.showLengths)
            Toggle("파형", isOn: $workspace.showScoreWaveforms)
            Toggle("페이지 맞춤", isOn: $fitPage)
            Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
            Text(layout.usesDetectedBars ? "검출된 마디에 맞춰 줄바꿈" : "분석 전 · 시간 구간으로 줄바꿈")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
            Toggle("재생 따라가기", isOn: $workspace.followScore)
                .onChange(of: workspace.followScore) { _, follow in if follow { workspace.followScoreCursor() } }
            Button { workspace.browseScorePage(page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0).help("이전 악보 페이지")
            Picker("페이지", selection: Binding(get: { workspace.displayedScorePage }, set: { workspace.browseScorePage($0) })) {
                ForEach(0..<layout.pageCount, id: \.self) { Text("\($0 + 1) / \(layout.pageCount) 페이지").tag($0) }
            }.labelsHidden().frame(width: 125)
            Button { workspace.browseScorePage(page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page == layout.pageCount - 1).help("다음 악보 페이지")
            }
        }.font(.system(size: 11)).toggleStyle(.checkbox)
    }

    private func system(_ row: ScoreSystem, layout: ScoreLayout, scale: Double) -> some View {
        let sections = (workspace.scoreSummary?.sections ?? []).enumerated().filter { $0.element.start >= row.start && $0.element.start < row.end }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text("\(scoreTime(row.start)) — \(scoreTime(row.end))").font(.system(size: 10, weight: .medium, design: .monospaced))
                ForEach(sections.map(\.offset), id: \.self) { index in
                    Text("구간 \(index + 1)").font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Paper.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Button { workspace.editSystem(row) } label: { Label("구간 편집", systemImage: "waveform") }
                    .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(Paper.accent)
            }
            ForEach(workspace.showBothLanes ? GuitarLane.allCases : [workspace.lane]) { lane in
                ScoreStaff(workspace: workspace, row: row, lane: lane, measured: layout.usesDetectedBars, displayScale: scale)
                    .frame(height: (workspace.showLengths ? 144 : 123) + (workspace.showScoreWaveforms ? 24 : 0))
            }
        }.padding(.vertical, 8)
    }
}

private struct PaperHeightKey: PreferenceKey {
    static let defaultValue = 740.0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}

private struct SongOverview: View {
    @ObservedObject var workspace: Workspace
    let layout: ScoreLayout
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                overline("SONG MAP")
                Text("곡 전체 · 클릭해서 이동").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("\(workspace.project.events.count)개 메모 · \(layout.pageCount)페이지").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            GeometryReader { geometry in
                Canvas { context, size in
                    let duration = workspace.project.duration
                    let page = workspace.displayedScorePage
                    let rows = layout.rows(on: page)
                    func x(_ t: Double) -> Double { 24 + t / duration * (size.width - 36) }
                    if let first = rows.first, let last = rows.last {
                        context.fill(Path(CGRect(x: x(first.start), y: 0, width: x(last.end) - x(first.start), height: 64)), with: .color(Palette.mint.opacity(0.10)))
                    }
                    for (index, section) in (workspace.scoreSummary?.sections ?? []).enumerated() {
                        let rect = CGRect(x: x(section.start), y: 2, width: max(1, x(section.end) - x(section.start)), height: 15)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color((index.isMultiple(of: 2) ? Palette.mint : Palette.purple).opacity(0.15)))
                        if rect.width > 55 {
                            context.draw(Text("구간 \(index + 1)").font(.system(size: 8)).foregroundColor(Palette.secondary), at: CGPoint(x: rect.midX, y: rect.midY))
                        }
                    }
                    for lane in GuitarLane.allCases {
                        let y = CGFloat(lane == .left ? 29 : 49)
                        let color = lane == .left ? Palette.mint : Palette.purple
                        context.draw(Text(lane == .left ? "L" : "R").font(.system(size: 9, weight: .bold)).foregroundColor(color), at: CGPoint(x: 8, y: y))
                        context.fill(Path(CGRect(x: 24, y: y - 1, width: size.width - 36, height: 2)), with: .color(Palette.border))
                        for event in workspace.project.events where event.lane == lane {
                            context.fill(Path(CGRect(x: x(event.time) - 1, y: y - 5, width: 2, height: 10)), with: .color(color.opacity(event.fret == nil ? 0.35 : 0.9)))
                        }
                    }
                    for i in 0...4 {
                        let t = duration * Double(i) / 4
                        context.draw(Text(scoreTime(t)).font(.system(size: 8, design: .monospaced)).foregroundColor(Palette.secondary), at: CGPoint(x: x(t), y: 75))
                    }
                    var cursor = Path(); cursor.move(to: CGPoint(x: x(workspace.cursor), y: 0)); cursor.addLine(to: CGPoint(x: x(workspace.cursor), y: 64))
                    context.stroke(cursor, with: .color(Palette.mint), lineWidth: 1.5)
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(1, max(0, (value.location.x - 24) / (geometry.size.width - 36)))
                    workspace.jumpToScoreTime(fraction * workspace.project.duration)
                })
            }.frame(height: 83)
        }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScoreStaff: View {
    @ObservedObject var workspace: Workspace
    let row: ScoreSystem
    let lane: GuitarLane
    let measured: Bool
    let displayScale: Double
    @State private var dragRange: TimeSpan?

    private var events: [TabEvent] {
        workspace.project.events.filter { $0.lane == lane && $0.time >= row.start && $0.time < row.end }
    }

    var body: some View {
        GeometryReader { geometry in
            let left = 50.0
            let width = geometry.size.width - left - 16
            let offset = workspace.showScoreWaveforms ? 24.0 : 0
            let stringTop = 38.0 + offset
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let strings = workspace.project.tuning
                    let current = workspace.cursor
                    if current >= row.start && current < row.end {
                        context.fill(Path(CGRect(x: left, y: 31 + offset, width: width, height: 82)), with: .color(Paper.accent.opacity(0.035)))
                    }
                    if let selected = workspace.selected, selected.lane == lane {
                        let note = workspace.renderedEvent(selected)
                        if note.time >= row.start && note.time <= row.end {
                            let guideX = left + row.fraction(at: note.time) * width
                            var guide = Path(); guide.move(to: CGPoint(x: guideX, y: 25)); guide.addLine(to: CGPoint(x: guideX, y: 137 + offset))
                            context.stroke(guide, with: .color(Paper.accent), style: StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
                            let label = (workspace.positionMagnetTargetID == nil ? "" : "붙음 · ") + String(format: "%.3fs", note.time)
                            context.draw(Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(Paper.accent),
                                         at: CGPoint(x: min(left + width - 27, max(left + 27, guideX)), y: 7))
                        }
                    }
                    if workspace.looping || dragRange != nil {
                        let start = max(row.start, dragRange?.start ?? workspace.loopStart)
                        let end = min(row.end, dragRange?.end ?? workspace.loopEnd)
                        if end > start {
                            let x = left + row.fraction(at: start) * width
                            let endX = left + row.fraction(at: end) * width
                            context.fill(Path(CGRect(x: x, y: 26, width: endX - x, height: 113 + offset)), with: .color(Paper.accent.opacity(0.09)))
                        }
                    }
                    if workspace.showScoreWaveforms {
                        let waveformY = 39.0
                        let peaks = lane == .left ? workspace.prepared?.leftPeaks : workspace.prepared?.rightPeaks
                        context.fill(Path(CGRect(x: left, y: 26, width: width, height: 27)), with: .color(Paper.accent.opacity(0.045)))
                        context.draw(Text(lane == .left ? "L" : "R").font(.system(size: 9, weight: .bold)).foregroundColor(Paper.accent), at: CGPoint(x: 20, y: waveformY))
                        var baseline = Path(); baseline.move(to: CGPoint(x: left, y: waveformY)); baseline.addLine(to: CGPoint(x: left + width, y: waveformY))
                        context.stroke(baseline, with: .color(Paper.accent.opacity(0.2)), lineWidth: 0.5)
                        if let peaks {
                            let duration = workspace.project.duration
                            let columns = max(1, min(2048, Int(width / 1.5)))
                            var waveform = Path()
                            for column in 0..<columns {
                                let startFraction = Double(column) / Double(columns)
                                let endFraction = Double(column + 1) / Double(columns)
                                let peak = WaveformEnvelope.peak(peaks, duration: duration,
                                                                 from: row.time(at: startFraction), to: row.time(at: endFraction))
                                let amplitude = max(0.2, Double(sqrt(min(1, peak))) * 12)
                                let x = left + (startFraction + endFraction) / 2 * width
                                waveform.move(to: CGPoint(x: x, y: waveformY - amplitude))
                                waveform.addLine(to: CGPoint(x: x, y: waveformY + amplitude))
                            }
                            context.stroke(waveform, with: .color(Paper.accent.opacity(lane == .left ? 0.75 : 0.55)), lineWidth: 1)
                        } else {
                            context.draw(Text("오디오를 연결하면 이 줄의 파형이 표시됩니다").font(.system(size: 9)).foregroundColor(Paper.muted), at: CGPoint(x: left + width / 2, y: waveformY))
                        }
                    }
                    for string in 1...6 {
                        let y = stringTop + Double((string - 1) * 14)
                        var line = Path(); line.move(to: CGPoint(x: left, y: y)); line.addLine(to: CGPoint(x: size.width - 16, y: y))
                        context.stroke(line, with: .color(Paper.ink.opacity(0.35)), lineWidth: string < 4 ? 0.7 : 1)
                        context.draw(Text(strings[string - 1]).font(.system(size: 9, design: .monospaced)).foregroundColor(Paper.muted), at: CGPoint(x: 36, y: y))
                    }
                    context.draw(Text(lane == .left ? "L" : "R").font(.system(size: 10, weight: .bold)).foregroundColor(Paper.accent), at: CGPoint(x: 10, y: 68 + offset))
                    context.draw(Text("T\nA\nB").font(.system(size: 9, weight: .semibold)).foregroundColor(Paper.ink), at: CGPoint(x: 21, y: 72 + offset))
                    for (index, measure) in row.measures.enumerated() {
                        let x = left + Double(index) / Double(row.measures.count) * width
                        if workspace.showScoreWaveforms {
                            var grid = Path(); grid.move(to: CGPoint(x: x, y: 26)); grid.addLine(to: CGPoint(x: x, y: 53))
                            context.stroke(grid, with: .color(Paper.ink.opacity(0.20)), lineWidth: 0.5)
                        }
                        var line = Path(); line.move(to: CGPoint(x: x, y: stringTop)); line.addLine(to: CGPoint(x: x, y: 108 + offset))
                        context.stroke(line, with: .color(Paper.ink.opacity(0.55)), lineWidth: 1)
                        let label = measure.number.map { String($0) } ?? (measured ? "전주" : scoreTime(measure.start))
                        context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(Paper.muted), at: CGPoint(x: x + 14, y: 18))
                    }
                    var end = Path(); end.move(to: CGPoint(x: left + width, y: stringTop)); end.addLine(to: CGPoint(x: left + width, y: 108 + offset))
                    context.stroke(end, with: .color(Paper.ink.opacity(0.6)), lineWidth: 1)
                    if current >= row.start && current < row.end {
                        let x = left + row.fraction(at: current) * width
                        var line = Path(); line.move(to: CGPoint(x: x, y: 30)); line.addLine(to: CGPoint(x: x, y: size.height - 2))
                        context.stroke(line, with: .color(Paper.accent.opacity(0.6)), lineWidth: 1)
                        if workspace.selectedID == nil && lane == workspace.lane {
                            let y = stringTop + Double((workspace.activeString - 1) * 14)
                            context.stroke(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(Paper.accent), lineWidth: 1)
                        }
                    }
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard workspace.showScoreWaveforms, (26...53).contains(value.startLocation.y),
                          abs(value.location.x - value.startLocation.x) > 4 else { return }
                    let start = row.time(at: (value.startLocation.x - left) / width)
                    let end = row.time(at: (value.location.x - left) / width)
                    dragRange = TimeSpan(start: min(start, end), end: max(start, end))
                }.onEnded { value in
                    if let dragRange {
                        workspace.selectLane(lane); workspace.setLoop(from: dragRange.start, to: dragRange.end)
                        self.dragRange = nil; return
                    }
                    guard hypot(value.translation.width, value.translation.height) <= 4 else { return }
                    guard value.location.x >= left, value.location.x < left + width else { return }
                    let time = row.time(at: (value.location.x - left) / width)
                    if workspace.showScoreWaveforms && (26...53).contains(value.location.y) {
                        if NSEvent.modifierFlags.contains(.option), workspace.selected?.lane == lane {
                            workspace.moveSelectedPosition(to: time); return
                        }
                        workspace.seekForEditing(time, lane: lane)
                        return
                    }
                    guard value.location.y >= 31 + offset, value.location.y <= 115 + offset else { return }
                    let string = min(6, max(1, Int(round((value.location.y - stringTop) / 14)) + 1))
                    if NSEvent.modifierFlags.contains(.option), workspace.selected?.lane == lane {
                        workspace.moveSelectedPosition(to: time, string: string); return
                    }
                    workspace.selectLane(lane)
                    workspace.addEvent(time: time, string: string)
                })
                .accessibilityLabel("\(lane.title) · \(clockLabel(row.start))부터 \(clockLabel(row.end)) · 클릭 후 숫자로 프렛 입력, 파형 드래그로 반복 구간 설정")
                ForEach(events) { event in
                    let shown = workspace.renderedEvent(event)
                    let x = left + row.fraction(at: shown.time) * width
                    DraggableTabNote(workspace: workspace, event: event, space: "score-\(row.id)-\(lane.rawValue)",
                                     position: { note in CGPoint(x: left + row.fraction(at: note.time) * width,
                                                                  y: stringTop + Double((note.string - 1) * 14)) },
                                     destination: { note, translation in
                                         (TimeBounds.scoreDragTime(note.time, system: row, translation: translation.width, width: width) ?? note.time,
                                          note.string + Int(round(translation.height / 14)))
                                     }, magnetTargets: events, displayScale: displayScale,
                                     compact: true, background: Paper.background, ink: Paper.ink, tentative: Paper.muted)
                    if workspace.showLengths, let length = event.length {
                        Text(length.symbol).font(.system(size: 20)).foregroundStyle(Paper.ink).position(x: x, y: 131 + offset)
                    }
                }
            }
        }.coordinateSpace(name: "score-\(row.id)-\(lane.rawValue)")
    }
}
