import AppKit
import RoughScoreCore
import SwiftUI

enum Palette {
    static let background = Color(red: 0.065, green: 0.078, blue: 0.085)
    static let panel = Color(red: 0.09, green: 0.105, blue: 0.115)
    static let elevated = Color(red: 0.12, green: 0.14, blue: 0.15)
    static let mint = Color(red: 0.60, green: 0.89, blue: 0.72)
    static let purple = Color(red: 0.73, green: 0.68, blue: 0.94)
    static let secondary = Color(red: 0.56, green: 0.61, blue: 0.63)
    static let border = Color.white.opacity(0.08)
}

func clockLabel(_ seconds: Double) -> String {
    String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Palette.border)
            HStack(spacing: 0) {
                sidebar.frame(width: 210)
                Divider().overlay(Palette.border)
                if workspace.scoreView {
                    VStack(spacing: 12) {
                        HStack {
                            Text(workspace.project.title).font(.system(size: 22, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text("\(clockLabel(workspace.project.duration)) · \(workspace.lane.title)")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        transport
                        quickEditBar
                        ScoreSheetView(workspace: workspace)
                    }.padding(18)
                } else { ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        transport
                        quickEditBar
                        audioPanel
                        tabPanel
                        HStack(spacing: 22) {
                            Label("미채보 구간은 빈칸으로 유지", systemImage: "square.dashed")
                            Label("? 음 미확인", systemImage: "questionmark.circle")
                            Label("점선 잠정 프렛", systemImage: "circle.dashed")
                        }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        Spacer(minLength: 4)
                    }.padding(26)
                } }
                if workspace.inspectorVisible {
                    Divider().overlay(Palette.border)
                    NoteInspector(workspace: workspace).frame(width: 250)
                }
            }
            Divider().overlay(Palette.border)
            HStack(spacing: 8) {
                Circle().fill(workspace.busy || workspace.analyzing ? .orange : Palette.mint).frame(width: 5, height: 5)
                Text(workspace.status).lineLimit(1)
                Spacer()
                Text("LOCAL AUDIO  /  STANDARD E").tracking(1.4)
            }
            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 18).frame(height: 30).background(Palette.panel)
        }
        .background(Palette.background).tint(Palette.mint)
        .background(TabKeyboardBridge(workspace: workspace).allowsHitTesting(false))
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("확인") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.mint)
            Text("roughscore").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
            Text("SKETCH, THEN PLAY.").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(Palette.secondary)
            Spacer()
            Picker("보기", selection: $workspace.scoreView) {
                Text("악보 보기").tag(true); Text("구간 편집").tag(false)
            }.pickerStyle(.segmented).frame(width: 165)
            if workspace.isDemo { Text("DEMO").font(.system(size: 9, weight: .bold)).tracking(1).padding(.horizontal, 9).padding(.vertical, 5).background(Palette.elevated, in: Capsule()) }
            if workspace.dirty { Circle().fill(Palette.mint).frame(width: 6, height: 6) }
            Button { workspace.importAudio() } label: { Label("오디오 열기", systemImage: "plus") }
                .disabled(workspace.busy || workspace.analyzing)
            Button { workspace.save() } label: { Label("저장", systemImage: "square.and.arrow.down") }.disabled(workspace.busy)
            Button { workspace.exportText() } label: { Image(systemName: "square.and.arrow.up") }.help("TAB 텍스트 내보내기")
        }.buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 22).frame(height: 60)
            .background(Palette.panel)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                overline("WORKSPACE")
                Label("부분 채보", systemImage: "pencil.and.outline").font(.system(size: 13, weight: .medium))
                Text("들리는 곳부터,\n확실한 음만 남기세요.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                overline("TAB TRACKS")
                ForEach(GuitarLane.allCases) { lane in
                    Button {
                        workspace.clearSelection(); workspace.lane = lane
                        workspace.switchSource(lane == .left ? .left : .right)
                    } label: {
                        HStack(spacing: 10) {
                            Text(lane == .left ? "L" : "R").font(.system(size: 11, weight: .bold)).frame(width: 25, height: 25)
                                .background((lane == .left ? Palette.mint : Palette.purple).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lane.title).font(.system(size: 12, weight: .medium))
                                Text("\(workspace.project.events.filter { $0.lane == lane }.count)개 메모")
                                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            if workspace.lane == lane { Circle().fill(Palette.mint).frame(width: 5, height: 5) }
                        }.padding(10).background(workspace.lane == lane ? Palette.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Text("L/R은 원본 채널입니다.\n기타 파트 분리를 뜻하지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                overline("MUSIC UNDERSTANDING")
                metric("BPM", value: workspace.summary?.bpm.map { String(format: "%.1f", $0) } ?? "—")
                metric("시작 조성", value: workspace.summary?.key ?? "—")
                metric("박 / 구간", value: "\(workspace.summary?.beats.count ?? 0) / \(workspace.summary?.sections.count ?? 0)")
                if workspace.analyzing {
                    ProgressView().controlSize(.small)
                    Button("분석 취소") { workspace.cancelAnalysis() }.font(.system(size: 11))
                } else {
                    Button { workspace.analyze() } label: { Label("현재 소스 분석", systemImage: "sparkle") }
                        .font(.system(size: 11)).disabled(!workspace.canAnalyze)
                }
                Text("원곡 · L · R 결과를 따로 보관\n분석 결과는 TAB을 생성하지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 8) {
                Label("기타 스템", systemImage: "waveform").font(.system(size: 12, weight: .medium))
                Text("기타 분리 모델 연결 예정\n이미 분리한 파일도 열 수 있습니다.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3)
                Button("분리된 파일 열기…") { workspace.importAudio() }.font(.system(size: 10))
                    .disabled(workspace.busy || workspace.analyzing)
            }.padding(12).background(Palette.elevated.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("프로젝트 열기") { workspace.openProject() }
                Spacer()
                Menu("데모") {
                    Button("짧은 데모 · 24초") { Task { await workspace.loadDemo() } }
                    Button("긴 곡 데모 · 3분") { Task { await workspace.loadDemo(long: true) } }
                }
            }.font(.system(size: 10)).buttonStyle(.borderless).disabled(workspace.busy || workspace.analyzing)
        }.padding(18).background(Palette.panel)
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                overline("A WORKING TRANSCRIPTION")
                Text(workspace.project.title).font(.system(size: 28, weight: .medium)).tracking(-0.8).lineLimit(1)
                Text(workspace.isDemo ? "합성 스테레오 예시 · 왼쪽 리프 / 오른쪽 멜로디" : "\(clockLabel(workspace.project.duration)) · 로컬 오디오 · Standard tuning")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Text("ROUGH\nIS ENOUGH.").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.5)
                .lineSpacing(4).foregroundStyle(Palette.mint.opacity(0.7))
        }
    }

    private var transport: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { workspace.togglePlayback() } label: {
                    Image(systemName: workspace.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16)).foregroundStyle(Palette.background).frame(width: 40, height: 40)
                        .background(Palette.mint, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(workspace.prepared == nil || workspace.busy)
                Text(clockLabel(workspace.cursor)).font(.system(size: 17, weight: .medium, design: .monospaced))
                Text("/ \(clockLabel(workspace.project.duration))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                Picker("듣기", selection: Binding(get: { workspace.source }, set: { workspace.switchSource($0) })) {
                    Text("Stereo · S").tag(ListeningSource.stereo)
                    Text("L").tag(ListeningSource.left)
                    Text("R").tag(ListeningSource.right)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 190).disabled(workspace.busy)
                Picker("재생 속도", selection: $workspace.rate) {
                    Text("0.5×").tag(Float(0.5)); Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                }.labelsHidden().frame(width: 70)
                Toggle(isOn: $workspace.looping) { Image(systemName: "repeat") }.toggleStyle(.button).help("A–B 반복")
                Button("A \(clockLabel(workspace.loopStart))") { workspace.setLoopStart() }.help("현재 위치를 반복 시작점으로")
                Button("B \(clockLabel(workspace.loopEnd))") { workspace.setLoopEnd() }.help("현재 위치를 반복 끝점으로")
            }.font(.system(size: 10, design: .monospaced))
            if !workspace.scoreView {
                Slider(value: Binding(get: { workspace.cursor }, set: { workspace.seek($0) }), in: 0...workspace.project.duration)
            }
        }.padding(workspace.scoreView ? 10 : 16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickEditBar: some View {
        HStack(spacing: 12) {
            if let selected = workspace.selected {
                let shown = workspace.renderedEvent(selected)
                Text("\(shown.string)번 줄 ·")
                    .foregroundStyle(Palette.mint).monospacedDigit()
                PositionTimeField(workspace: workspace, event: shown).id(selected.id)
                Text("초 · \(shown.fret.map(String.init) ?? "?")프렛").foregroundStyle(Palette.mint)
                Text("자유 드래그 · Shift 마그넷 · 더블 클릭 확대")
                    .foregroundStyle(Palette.secondary).lineLimit(1)
            } else {
                Text("클릭 후 숫자 입력 · ↑↓ \(workspace.activeString)번 줄 · 파형 드래그로 반복")
                    .foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { workspace.focusSelectedForPosition() } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(workspace.selected == nil).help("선택한 음 주변 2초 확대 · 더블 클릭")
            Button { workspace.auditionSelected() } label: { Image(systemName: "speaker.wave.1") }
                .disabled(workspace.selected == nil).help("선택한 위치부터 듣기 · Shift+Space")
            Toggle("새 음 박 스냅", isOn: $workspace.snapToBeat).toggleStyle(.checkbox)
                .help("새 음 입력에 적용 · 이동은 자유 드래그, Shift로 가까운 음에 정렬")
                .disabled(workspace.scoreSummary?.beats.isEmpty ?? true)
            Button { workspace.undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!workspace.canUndo).help("실행 취소 · ⌘Z")
            Button { workspace.redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!workspace.canRedo).help("다시 실행 · ⇧⌘Z")
            Button { workspace.deleteSelected() } label: { Image(systemName: "trash") }.disabled(workspace.selected == nil).help("선택한 음 삭제 · Delete")
            Toggle("상세", isOn: $workspace.inspectorVisible).toggleStyle(.button).help("상세 편집 · I")
            Text(workspace.hasSaveLocation ? "자동 저장" : "⌘S 저장").font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.font(.system(size: 10)).buttonStyle(.borderless).frame(height: 27)
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("01").foregroundStyle(Palette.mint)
                Text("듣고, 위치 찾기").fontWeight(.medium)
                Spacer()
                Picker("듣기 소스", selection: Binding(get: { workspace.source }, set: { workspace.switchSource($0) })) {
                    ForEach(ListeningSource.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 265)
                    .disabled(workspace.busy)
            }.font(.system(size: 12))
            WaveformView(workspace: workspace)
            HStack {
                Text("파형을 클릭해서 이동").foregroundStyle(Palette.secondary)
                Spacer()
                if workspace.prepared == nil { Button("오디오 다시 연결…") { workspace.importAudio(relink: true) } }
                Text("L / R · 원본 채널").foregroundStyle(Palette.secondary)
            }.font(.system(size: 10))
        }
    }

    private var tabPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("02").foregroundStyle(Palette.mint)
                Text("\(workspace.lane.title) · 부분 TAB").fontWeight(.medium)
                Spacer()
                Toggle("새 음 박 스냅", isOn: $workspace.snapToBeat).disabled(workspace.scoreSummary?.beats.isEmpty ?? true)
                Toggle("음표 길이", isOn: $workspace.showLengths)
            }.font(.system(size: 12)).toggleStyle(.checkbox)
            HStack {
                Text("\(clockLabel(workspace.windowStart)) — \(clockLabel(workspace.windowEnd))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                Spacer()
                Picker("표시 범위", selection: $workspace.windowLength) {
                    if ![1.0, 2.0, 3.0, 6.0, 12.0, 24.0, 48.0].contains(workspace.windowLength) {
                        Text("현재 범위").tag(workspace.windowLength)
                    }
                    Text("1초").tag(1.0); Text("2초").tag(2.0); Text("3초").tag(3.0)
                    Text("6초").tag(6.0); Text("12초").tag(12.0); Text("24초").tag(24.0); Text("48초").tag(48.0)
                }.labelsHidden().frame(width: 75)
                    .onChange(of: workspace.windowLength) { _, _ in workspace.zoomPositionWindow(by: 1) }
                Button { workspace.zoomPositionWindow(by: 0.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("음 주변 확대")
                Button { workspace.zoomPositionWindow(by: 2) } label: { Image(systemName: "minus.magnifyingglass") }.help("음 주변 축소")
                Button { workspace.moveWindow(-1) } label: { Image(systemName: "chevron.left") }.help("이전 구간")
                Button { workspace.moveWindow(1) } label: { Image(systemName: "chevron.right") }.help("다음 구간")
            }
            TabCanvas(workspace: workspace).frame(height: workspace.showLengths ? 308 : 275)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Image(systemName: "cursorarrow.click")
                Text("줄 클릭 후 숫자로 프렛 입력 · 파형 드래그로 반복 듣기")
                Spacer()
                Text("\(workspace.visibleEvents.count) NOTES")
            }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.secondary); Spacer(); Text(value).lineLimit(1) }.font(.system(size: 11))
    }
}

func overline(_ text: String) -> some View {
    Text(text).font(.system(size: 9, weight: .medium)).tracking(1.4).foregroundStyle(Palette.secondary)
}

struct WaveformView: View {
    @ObservedObject var workspace: Workspace
    @State private var dragRange: TimeSpan?
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let span = max(0.001, workspace.windowEnd - workspace.windowStart)
                let start = workspace.windowStart
                func x(_ t: Double) -> Double { 38 + (t - start) / span * (size.width - 58) }
                if workspace.looping || dragRange != nil {
                    let a = max(38, x(dragRange?.start ?? workspace.loopStart)), b = min(size.width - 20, x(dragRange?.end ?? workspace.loopEnd))
                    if b > a { context.fill(Path(CGRect(x: a, y: 0, width: b - a, height: size.height)), with: .color(Palette.mint.opacity(0.05))) }
                }
                for channel in 0..<2 {
                    let center = CGFloat(channel == 0 ? 30 : 84)
                    let color = channel == 0 ? Palette.mint : Palette.purple
                    context.draw(Text(channel == 0 ? "L" : "R").font(.system(size: 9, weight: .bold)).foregroundColor(color), at: CGPoint(x: 12, y: center))
                    var baseline = Path(); baseline.move(to: CGPoint(x: 38, y: center)); baseline.addLine(to: CGPoint(x: size.width - 20, y: center))
                    context.stroke(baseline, with: .color(Palette.border))
                    let peaks = channel == 0 ? workspace.prepared?.leftPeaks : workspace.prepared?.rightPeaks
                    if let peaks {
                        var waveform = Path()
                        let columns = max(1, Int((size.width - 58) / 3))
                        for i in 0..<columns {
                            let t = workspace.windowStart + Double(i) / Double(columns) * span
                            let end = workspace.windowStart + Double(i + 1) / Double(columns) * span
                            let peak = WaveformEnvelope.peak(peaks, duration: workspace.project.duration, from: t, to: end)
                            let amplitude = CGFloat(min(1, sqrt(peak))) * 23
                            waveform.move(to: CGPoint(x: x(t), y: center - max(0.6, amplitude)))
                            waveform.addLine(to: CGPoint(x: x(t), y: center + max(0.6, amplitude)))
                        }
                        let active = workspace.source == .stereo || (channel == 0 ? workspace.source == .left : workspace.source == .right)
                        context.stroke(waveform, with: .color(color.opacity(active ? 0.75 : 0.18)), lineWidth: 1.5)
                    }
                }
                if workspace.cursor >= workspace.windowStart && workspace.cursor <= workspace.windowEnd {
                    var line = Path(); line.move(to: CGPoint(x: x(workspace.cursor), y: 0)); line.addLine(to: CGPoint(x: x(workspace.cursor), y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.75)), lineWidth: 1)
                }
                if let selected = workspace.selected {
                    let note = workspace.renderedEvent(selected)
                    if note.time >= workspace.windowStart && note.time <= workspace.windowEnd {
                        var guide = Path(); guide.move(to: CGPoint(x: x(note.time), y: 0)); guide.addLine(to: CGPoint(x: x(note.time), y: size.height))
                        context.stroke(guide, with: .color(Palette.mint), style: StrokeStyle(lineWidth: 1.3, dash: [3, 2]))
                        let label = (workspace.positionMagnetTargetID == nil ? "" : "붙음 · ") + String(format: "%.3fs", note.time)
                        context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.mint),
                                     at: CGPoint(x: min(size.width - 35, max(65, x(note.time))), y: 8))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard abs(value.location.x - value.startLocation.x) > 4 else { return }
                let start = time(at: value.startLocation.x, width: geometry.size.width)
                let end = time(at: value.location.x, width: geometry.size.width)
                dragRange = TimeSpan(start: min(start, end), end: max(start, end))
            }.onEnded { value in
                if let dragRange { workspace.setLoop(from: dragRange.start, to: dragRange.end) }
                else { workspace.seekForEditing(time(at: value.location.x, width: geometry.size.width)) }
                dragRange = nil
            })
        }.frame(height: 115).padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func time(at x: Double, width: Double) -> Double {
        let fraction = min(1, max(0, (x - 38) / (width - 58)))
        return workspace.windowStart + fraction * (workspace.windowEnd - workspace.windowStart)
    }
}

struct TabCanvas: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        GeometryReader { geometry in
            let span = max(0.001, workspace.windowEnd - workspace.windowStart)
            let width = geometry.size.width - 78
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let start = workspace.windowStart
                    func x(_ t: Double) -> Double { 48 + (t - start) / span * width }
                    let steps = 6
                    for i in 0...steps {
                        let time = workspace.windowStart + Double(i) / Double(steps) * span
                        let px = x(time)
                        var line = Path(); line.move(to: CGPoint(x: px, y: 49)); line.addLine(to: CGPoint(x: px, y: 245))
                        context.stroke(line, with: .color(Palette.border), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                        context.draw(Text(String(format: "%.1fs", time)).font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.secondary), at: CGPoint(x: px, y: 25))
                    }
                    for beat in workspace.summary?.beats ?? [] where beat >= workspace.windowStart && beat <= workspace.windowEnd {
                        var line = Path(); line.move(to: CGPoint(x: x(beat), y: 47)); line.addLine(to: CGPoint(x: x(beat), y: 240))
                        context.stroke(line, with: .color(Palette.mint.opacity(0.10)), lineWidth: 1)
                    }
                    for string in 1...6 {
                        let y = Double(68 + (string - 1) * 32)
                        var line = Path(); line.move(to: CGPoint(x: 48, y: y)); line.addLine(to: CGPoint(x: size.width - 30, y: y))
                        context.stroke(line, with: .color(.white.opacity(0.17)), lineWidth: string >= 4 ? 1.3 : 0.8)
                        context.draw(Text(workspace.project.tuning[string - 1]).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(Palette.secondary), at: CGPoint(x: 22, y: y))
                    }
                    if workspace.cursor >= workspace.windowStart && workspace.cursor <= workspace.windowEnd {
                        var cursor = Path(); cursor.move(to: CGPoint(x: x(workspace.cursor), y: 43)); cursor.addLine(to: CGPoint(x: x(workspace.cursor), y: size.height - 20))
                        context.stroke(cursor, with: .color(Palette.mint.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        if workspace.selectedID == nil {
                            let y = Double(68 + (workspace.activeString - 1) * 32)
                            context.stroke(Path(ellipseIn: CGRect(x: x(workspace.cursor) - 5, y: y - 5, width: 10, height: 10)), with: .color(Palette.mint), lineWidth: 1)
                        }
                    }
                    if let selected = workspace.selected, selected.lane == workspace.lane {
                        let note = workspace.renderedEvent(selected)
                        if note.time >= workspace.windowStart && note.time <= workspace.windowEnd {
                            var guide = Path(); guide.move(to: CGPoint(x: x(note.time), y: 42)); guide.addLine(to: CGPoint(x: x(note.time), y: size.height - 16))
                            context.stroke(guide, with: .color(Palette.mint), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            let label = (workspace.positionMagnetTargetID == nil ? "" : "붙음 · ") + String(format: "%.3fs", note.time)
                            context.draw(Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(Palette.mint),
                                         at: CGPoint(x: min(size.width - 40, max(70, x(note.time))), y: 8))
                        }
                    }
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard hypot(value.translation.width, value.translation.height) <= 4 else { return }
                    let y = value.location.y
                    guard y >= 52, y <= 244, value.location.x >= 48, value.location.x <= geometry.size.width - 30 else { return }
                    let string = min(6, max(1, Int(round((y - 68) / 32)) + 1))
                    let time = workspace.windowStart + (value.location.x - 48) / width * span
                    if NSEvent.modifierFlags.contains(.option), workspace.selected != nil {
                        workspace.moveSelectedPosition(to: time, string: string); return
                    }
                    workspace.addEvent(time: time, string: string)
                })
                ForEach(workspace.visibleEvents) { event in
                    let shown = workspace.renderedEvent(event)
                    let x = 48 + (shown.time - workspace.windowStart) / span * width
                    DraggableTabNote(workspace: workspace, event: event, space: "timeline-tab",
                                     position: { note in CGPoint(x: 48 + (note.time - workspace.windowStart) / span * width,
                                                                  y: Double(68 + (note.string - 1) * 32)) },
                                     destination: { note, translation in
                                         (min(workspace.windowEnd - 0.001, max(workspace.windowStart, note.time + translation.width / width * span)),
                                          note.string + Int(round(translation.height / 32)))
                                     }, magnetTargets: workspace.visibleEvents, displayScale: 1,
                                     compact: false, background: Palette.panel, ink: Palette.background, tentative: Palette.purple)
                    if workspace.showLengths, let length = event.length {
                        Text(length.symbol).font(.system(size: 22)).foregroundStyle(Palette.secondary).position(x: x, y: 272)
                    }
                }
                Text("TAB").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(Palette.secondary).position(x: 22, y: 258)
            }
        }.coordinateSpace(name: "timeline-tab").clipped()
    }
}

struct NoteInspector: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                overline("NOTE INSPECTOR")
                Spacer()
                Button { workspace.inspectorVisible = false; workspace.requestKeyboardFocus?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 10)).help("편집 패널 닫기")
            }
            if let event = workspace.selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.fret.map(String.init) ?? "?").font(.system(size: 44, weight: .light, design: .monospaced)).foregroundStyle(Palette.mint)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(event.lane.title).font(.system(size: 12, weight: .medium))
                        Text("\(event.string)번 줄 · \(workspace.project.tuning[event.string - 1])").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("위치 · 초")
                    TextField("위치", value: binding(\.time, transform: { min(max(0, $0.isFinite ? $0 : 0), workspace.project.duration - 0.001) }), format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                    fieldLabel("기타 줄")
                    Picker("줄", selection: binding(\.string)) {
                        ForEach(1...6, id: \.self) { Text("\($0)번 · \(workspace.project.tuning[$0 - 1])").tag($0) }
                    }.labelsHidden()
                    fieldLabel("프렛")
                    Picker("프렛", selection: binding(\.fret)) {
                        Text("? · 음 미확인").tag(Int?.none)
                        ForEach(0...24, id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }.labelsHidden()
                    Text("같은 음도 여러 줄에서 낼 수 있습니다.\n실제 운지는 직접 선택하세요.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3)
                }
                Divider()
                Toggle("잠정 프렛으로 표시", isOn: binding(\.tentative)).font(.system(size: 11))
                if workspace.showLengths {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("음표 길이 · 선택 사항")
                        Picker("길이", selection: binding(\.length)) {
                            Text("미지정").tag(NoteLength?.none)
                            ForEach(NoteLength.allCases) { Text("\($0.symbol)  \($0.title)").tag(Optional($0)) }
                        }.labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("듣기 메모")
                    TextField("예: 벤딩 / 다시 확인", text: binding(\.memo), axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                }
                Button(role: .destructive) { workspace.deleteSelected() } label: { Label("이 메모 삭제", systemImage: "trash") }.font(.system(size: 11))
                Spacer()
            } else {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.secondary).padding(.top, 28)
                Text("한 음씩,\n천천히 기록하세요.").font(.system(size: 19, weight: .medium)).lineSpacing(5)
                Text("TAB의 줄 위를 클릭하면\n그 위치에 메모가 생깁니다.\n\n프렛을 모르면 ?로 두고,\n들리는 부분만 적어도 됩니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(5)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 9) {
                overline("QUICK GUIDE")
                shortcut("0–24", "프렛 바로 입력")
                shortcut("↑ ↓", "줄 이동")
                shortcut("← →", "시간 ±50ms")
                shortcut("⇧ ← →", "시간 ±10ms")
                shortcut("Tab", "다음 음")
                shortcut("Delete", "선택한 음 삭제")
                shortcut("⌘ Z", "실행 취소")
                shortcut("Space", "재생 / 정지")
                shortcut("[  ]", "반복 시작 / 끝")
                shortcut("⌘ S", "프로젝트 저장")
            }.padding(.top, 12)
        }.padding(20).frame(maxHeight: .infinity, alignment: .topLeading).background(Palette.panel)
    }
    private func binding<Value>(_ path: WritableKeyPath<TabEvent, Value>, transform: @escaping (Value) -> Value = { $0 }) -> Binding<Value> {
        Binding(get: { (workspace.selected ?? TabEvent(time: 0, lane: .left, string: 1))[keyPath: path] },
                set: { value in workspace.updateSelected { $0[keyPath: path] = transform(value) } })
    }
    private func fieldLabel(_ title: String) -> some View { Text(title).font(.system(size: 10)).foregroundStyle(Palette.secondary) }
    private func shortcut(_ key: String, _ title: String) -> some View {
        HStack { Text(key).font(.system(size: 10, design: .monospaced)).frame(width: 50, alignment: .leading); Text(title).font(.system(size: 10)) }.foregroundStyle(Palette.secondary)
    }
}
