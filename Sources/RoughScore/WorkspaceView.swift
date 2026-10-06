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

/// A settings observer must distinguish restoration into another document from an in-document edit.
struct ProjectViewSetting<Value: Equatable>: Equatable {
    let projectID: UUID
    let value: Value
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @State private var noteListOpen = false
    @State private var tuningOpen = false
    var body: some View {
        VStack(spacing: 0) {
            topBar.disabled(!workspace.canEdit)
            if let message = workspace.externalOpenError {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("external-project-open-error")
                    Spacer()
                    Button("닫기") { workspace.externalOpenError = nil }
                }.font(.system(size: 12)).padding(10).background(Palette.panel)
            }
            Divider().overlay(Palette.border)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.tabInputFocused ? "TAB 입력 · Tab 다음 음 · ⌃Tab 컨트롤로 · ⇧⌃Tab 뒤로" : "컨트롤 탐색 · Tab 이동 · TAB 입력 버튼 또는 ⌘Return으로 입력")
                    .font(.system(size: 11)).accessibilityIdentifier("editor-input-mode")
                HStack(spacing: 8) {
                    Text("편집 커서 · 초").font(.system(size: 11))
                    EditorNavigationControls(workspace: workspace, openNotes: { noteListOpen = true }, openTuning: { tuningOpen = true })
                        .frame(width: 696, height: 32).id(workspace.editorIdentity)
                    Spacer(minLength: 0)
                }
                Text("입력 간격은 표시 설정 오른쪽 초 필드 · 작은 악보 음은 음 목록에서 48pt 행으로 선택")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 6)
                .popover(isPresented: $noteListOpen) {
                    VStack(alignment: .leading) {
                        Text("음 목록 · \(workspace.lane.title) · 원곡 시간순")
                        AccessibleNoteList(workspace: workspace, events: workspace.project.events.filter { $0.lane == workspace.lane }.sorted {
                            if $0.time != $1.time { return $0.time < $1.time }; return $0.id.uuidString < $1.id.uuidString
                        }, dismiss: { noteListOpen = false })
                            .frame(width: 660, height: 320)
                        Button("닫기") { noteListOpen = false; _ = workspace.requestControlFocus?(false) }
                    }.padding(12)
                }
                .popover(isPresented: $tuningOpen) {
                    TuningEditor(workspace: workspace) { tuningOpen = false; _ = workspace.requestControlFocus?(false) }
                }
            if workspace.busy {
                HStack {
                    ProgressView(value: workspace.loadProgress).frame(maxWidth: 280)
                    Text("오디오 준비 \(Int(workspace.loadProgress * 100))%")
                    Spacer()
                    Button("취소") { workspace.cancelLoading() }
                }.font(.system(size: 12)).padding(12)
            }
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
                        audioConnectionBar
                        transport
                        quickEditBar
                        BulkSelectionBar(workspace: workspace)
                        ScoreSheetView(workspace: workspace)
                    }.padding(18)
                } else { ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        transport
                        quickEditBar
                        BulkSelectionBar(workspace: workspace)
                        audioConnectionBar
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
                    NoteInspector(workspace: workspace).frame(width: 250).disabled(!workspace.canMutateNotes)
                }
            }
            // Recreate project-scoped SwiftUI state/observers after activation. Otherwise old
            // onChange reflow/zoom callbacks can replace the page/window we just restored.
            .id(workspace.editorIdentity)
            .disabled(!workspace.canEdit)
            Divider().overlay(Palette.border)
            HStack(spacing: 8) {
                Circle().fill(workspace.busy || workspace.analyzing ? .orange : Palette.mint).frame(width: 5, height: 5)
                Text(workspace.sessionPersistenceError ?? workspace.status).lineLimit(1)
                    .help(workspace.sessionPersistenceError ?? workspace.status)
                Spacer()
                Text("LOCAL AUDIO  /  STANDARD E").tracking(1.4)
            }
            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 18).frame(height: 30).background(Palette.panel)
        }
        .onChange(of: workspace.editorIdentity) { _, _ in noteListOpen = false; tuningOpen = false }
        .onChange(of: workspace.tabInputFocused) { _, focused in if focused { noteListOpen = false; tuningOpen = false } }
        .background(Palette.background).tint(Palette.mint)
        .background(TabKeyboardBridge(workspace: workspace).id(workspace.editorIdentity).allowsHitTesting(false))
        .sheet(item: Binding(get: { workspace.exportSnapshot }, set: { if $0 == nil { workspace.cancelExport() } })) { snapshot in
            ScoreExportOptionsView(snapshot: snapshot, format: snapshot.initialFormat,
                submit: { options in Task { _ = await workspace.completeExport(snapshot, options: options) } }, cancel: { workspace.cancelExport() })
        }
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
            Button { workspace.save() } label: { Label("저장", systemImage: "square.and.arrow.down") }.disabled(!workspace.canSave)
            ProjectSaveMenu(workspace: workspace)
            ScoreExportMenu(workspace: workspace)
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
                    }.buttonStyle(.plain).accessibilityValue(workspace.lane == lane ? "선택됨" : "선택 안 됨")
                }
                Text("L/R은 선택한 파일의 채널입니다.\n기타 파트 분리를 뜻하지 않습니다.")
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
                Text("현재 자산의 Stereo · L · R 결과 보관\n분석 결과는 TAB을 생성하지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if workspace.source != .stereo {
                Button("실험적 단음 후보 · 현재 구간") {
                    workspace.proposePitches(from: workspace.windowStart,
                        to: min(workspace.windowEnd, workspace.windowStart + 60))
                }.font(.system(size: 10)).disabled(workspace.prepared == nil || workspace.analyzing || workspace.busy)
                ForEach(Array(workspace.pitchProposals.prefix(6).enumerated()), id: \.offset) { _, proposal in
                    Text(String(format: "%.3fs · ", proposal.onset) +
                        (proposal.frequencyHz.map { String(format: "%.1fHz", $0) } ?? "음 미확인") +
                        (proposal.qualified ? " · 규칙 통과" : " · 불확실"))
                        .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                }
                Text("깨끗한 단음용 · 확률/운지/리듬 추정 없음").font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 10)
            StemControls(workspace: workspace)
            HStack {
                Button("프로젝트 열기") { workspace.openProject() }
                Spacer()
                Menu("데모") {
                    Button("짧은 데모 · 24초") { workspace.loadDemo() }
                    Button("긴 곡 데모 · 3분") { workspace.loadDemo(long: true) }
                }
            }.font(.system(size: 10)).buttonStyle(.borderless).disabled(workspace.busy || workspace.analyzing)
        }.padding(18).background(Palette.panel)
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                overline("A WORKING TRANSCRIPTION")
                Text(workspace.project.title).font(.system(size: 28, weight: .medium)).tracking(-0.8).lineLimit(1)
                Text(workspace.isDemo ? "합성 스테레오 예시 · 왼쪽 리프 / 오른쪽 멜로디" : "\(clockLabel(workspace.project.duration)) · 로컬 오디오")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                TuningControl(workspace: workspace)
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
                }.accessibilityLabel(workspace.playing ? "일시 정지" : "재생").buttonStyle(.plain).disabled(workspace.prepared == nil || workspace.busy)
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
                Toggle(isOn: $workspace.looping) { Image(systemName: "repeat") }.toggleStyle(.button).accessibilityLabel("A–B 반복").accessibilityValue(workspace.looping ? "켜짐" : "꺼짐").help("A–B 반복")
                Button("A \(clockLabel(workspace.loopStart))") { workspace.setLoopStart() }.help("현재 위치를 반복 시작점으로")
                Button("B \(clockLabel(workspace.loopEnd))") { workspace.setLoopEnd() }.help("현재 위치를 반복 끝점으로")
            }.font(.system(size: 10, design: .monospaced))
            if !workspace.scoreView {
                Slider(value: Binding(get: { workspace.cursor }, set: { workspace.seekForEditing($0, requestFocus: false) }), in: 0...workspace.project.duration).accessibilityLabel("편집 커서 · 원곡 초")
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
                .disabled(workspace.selected == nil).accessibilityLabel("선택한 음 주변 2초 확대").help("선택한 음 주변 2초 확대 · 더블 클릭")
            Button { workspace.auditionSelected() } label: { Image(systemName: "speaker.wave.1") }
                .disabled(workspace.selected == nil).accessibilityLabel("선택한 위치부터 듣기").help("선택한 위치부터 듣기 · Shift+Space")
            Toggle("새 음 박 스냅", isOn: $workspace.snapToBeat).toggleStyle(.checkbox)
                .help("새 음 입력에 적용 · 이동은 자유 드래그, Shift로 가까운 음에 정렬")
                .disabled(workspace.scoreSummary?.beats.isEmpty ?? true)
            Button { workspace.performUndo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!workspace.canPerformUndo).accessibilityLabel("실행 취소").help("실행 취소 · ⌘Z")
            Button { workspace.performRedo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!workspace.canPerformRedo).accessibilityLabel("다시 실행").help("다시 실행 · ⇧⌘Z")
            Button { workspace.deleteSelected() } label: { Image(systemName: "trash") }.disabled(workspace.selected == nil).accessibilityLabel("선택한 음 삭제").help("선택한 음 삭제 · Delete")
            Toggle("상세", isOn: $workspace.inspectorVisible).toggleStyle(.button).help("상세 편집 · I")
            Button("다음 +\(Int(workspace.entryInterval * 1000))ms ↵") { workspace.advanceEntry() }
                .disabled(!workspace.canMutateNotes).help("선택을 마치고 지정한 간격만큼 커서를 이동 · Enter")
            EntryIntervalControl(workspace: workspace)
            Text(workspace.saveState.title).font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }.font(.system(size: 10)).buttonStyle(.borderless).frame(height: 27)
    }

    private var audioConnectionBar: some View {
        HStack {
            Text((workspace.assetRole == .original ? "원곡 · " : "Stem · ") + (workspace.assetRole == .original ? workspace.audioConnection : workspace.stemConnection)).lineLimit(1).foregroundStyle(Palette.secondary)
            Spacer()
            Button("원곡 다시 연결…") { workspace.importAudio(relink: true) }
                .disabled(!workspace.canLoad)
        }.font(.system(size: 10)).buttonStyle(.borderless)
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
                    .onChange(of: ProjectViewSetting(projectID: workspace.editorIdentity, value: workspace.windowLength)) { previous, current in
                        guard previous.projectID == current.projectID else { return }
                        workspace.zoomPositionWindow(by: 1)
                    }
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
                let span = (TimeBounds.span(start: workspace.windowStart, end: workspace.windowEnd) ?? 1)
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
        }.overlay(EditingCursorAXSurface(workspace: workspace, name: "파형")).frame(height: 115).padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
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
            let span = (TimeBounds.span(start: workspace.windowStart, end: workspace.windowEnd) ?? 1)
            let width: Double = Double(geometry.size.width) - 78
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
                        context.draw(Text(workspace.project.stringLabel(string)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(Palette.secondary), at: CGPoint(x: 22, y: y))
                    }
                    if let range = workspace.selectionRange,
                       workspace.project.events.contains(where: { workspace.selection.ids.contains($0.id) && $0.lane == workspace.lane }) {
                        let start = max(workspace.windowStart, range.start), end = min(workspace.windowEnd, range.end)
                        if end > start {
                            context.fill(Path(CGRect(x: x(start), y: 43, width: x(end) - x(start), height: 201)),
                                         with: .color(Palette.mint.opacity(0.10)))
                        }
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
                TabRangeSurface(workspace: workspace, lane: workspace.lane) { x in
                    workspace.windowStart + min(1, max(0, (x - 48) / width)) * span
                }
                pointerNotes(width: width, span: span)
                ForEach(workspace.visibleEvents) { event in
                    let shown = workspace.renderedEvent(event)
                    let x = 48 + (shown.time - workspace.windowStart) / span * width
                    if workspace.showLengths, let length = event.length {
                        Text(length.symbol).font(.system(size: 22)).foregroundStyle(Palette.secondary).position(x: x, y: 272)
                    }
                }
                Text("TAB").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(Palette.secondary).position(x: 22, y: 258)
            }
        }.coordinateSpace(name: "timeline-tab").clipped()
    }

    private func pointerNotes(width: Double, span: Double) -> PointerTabNotes {
        let position: (TabEvent) -> CGPoint = { note in
            let timeX: Double = 48 + (note.time - workspace.windowStart) / span * width
            return CGPoint(x: timeX, y: Double(68 + (note.string - 1) * 32))
        }
        let destination: (TabEvent, CGSize) -> (time: Double, string: Int) = { note, translation in
            (TimeBounds.timelineDragTime(note.time, start: workspace.windowStart, end: workspace.windowEnd,
                                         translation: translation.width, width: width) ?? note.time,
             note.string + Int(round(translation.height / 32)))
        }
        return PointerTabNotes(workspace: workspace, events: workspace.visibleEvents, bounds: 48...(48 + max(1, width)),
                               position: position, destination: destination, displayScale: 1, compact: false,
                               background: Palette.panel, ink: Palette.background, tentative: Palette.purple)
    }

}

struct NoteInspector: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        ScrollView {
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
                        Text("\(event.string)번 줄 · \(workspace.project.stringLabel(event.string))").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("위치 · 초")
                    PositionTimeField(workspace: workspace, event: event)
                    fieldLabel("기타 줄")
                    Picker("줄", selection: binding(\.string)) {
                        ForEach(1...6, id: \.self) { Text("\($0)번 · \(workspace.project.stringLabel($0))").tag($0) }
                    }.labelsHidden()
                    fieldLabel("프렛")
                    Picker("프렛", selection: binding(\.fret)) {
                        Text("? · 음 미확인").tag(Int?.none)
                        ForEach(0...24, id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }.labelsHidden()
                    Text("같은 음도 여러 줄에서 낼 수 있습니다.\n실제 운지는 직접 선택하세요.")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3)
                }
                PitchAlternatives(workspace: workspace, event: event).id(event.id)
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
                    MemoEditor(workspace: workspace, eventID: event.id)
                        .frame(minHeight: 74, maxHeight: 110).background(Palette.elevated, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("듣기 메모 · 일반 텍스트")
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
        }.padding(20)
        }.frame(maxHeight: .infinity, alignment: .topLeading).background(Palette.panel)
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

private struct EntryIntervalControl: View {
    @ObservedObject var workspace: Workspace
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "ellipsis") }
            .help("다음 입력 간격 · 초 단위 위치만 이동하며 리듬을 지정하지 않습니다")
            .popover(isPresented: $open) {
                HStack {
                    Text("다음 입력 간격")
                    TextField("ms", value: Binding(get: { workspace.entryInterval * 1000 },
                        set: { _ = workspace.setEntryInterval($0 / 1000) }), format: .number)
                        .frame(width: 80).textFieldStyle(.roundedBorder)
                    Text("ms")
                }.font(.system(size: 11)).padding(14)
            }
    }
}
