import AppKit
import RoughScoreCore
import SwiftUI

enum Palette {
    static let background = Color(red: 0.078, green: 0.084, blue: 0.090)
    static let panel = Color(red: 0.106, green: 0.113, blue: 0.121)
    static let elevated = Color(red: 0.150, green: 0.158, blue: 0.168)
    static let mint = Color(red: 0.55, green: 0.86, blue: 0.69)
    static let purple = Color(red: 0.71, green: 0.66, blue: 0.95)
    static let secondary = Color(red: 0.58, green: 0.61, blue: 0.64)
    static let tertiary = Color(red: 0.40, green: 0.43, blue: 0.46)
    static let border = Color.white.opacity(0.07)
}

func clockLabel(_ seconds: Double) -> String {
    String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}

/// A settings observer must distinguish restoration into another document from an in-document edit.
struct ProjectViewSetting<Value: Equatable>: Equatable {
    let projectID: UUID
    let value: Value
}

/// Source-list style group: a quiet caption over its rows.
struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Icon-only toolbar button with a tooltip and a spoken label.
struct ToolIcon: View {
    let symbol: String
    let label: String
    var help: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).accessibilityLabel(label).help(help ?? label)
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @State private var noteListOpen = false
    @State private var tuningOpen = false
    /// Width of the editing column; narrow layouts (inspector open, small window) drop secondary chrome.
    @State private var mainWidth: CGFloat = 1200
    private var compact: Bool { mainWidth < 820 }
    var body: some View {
        VStack(spacing: 0) {
            if let message = workspace.externalOpenError {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityIdentifier("external-project-open-error")
                    Spacer()
                    Button("닫기") { workspace.externalOpenError = nil }
                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8).background(Palette.elevated)
                Divider().overlay(Palette.border)
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                Divider().overlay(Palette.border)
                VStack(spacing: 0) {
                    transport
                    Divider().overlay(Palette.border)
                    editorBar
                    Divider().overlay(Palette.border)
                    if workspace.scoreView {
                        ScoreSheetView(workspace: workspace).padding(16)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Slider(value: Binding(get: { workspace.cursor }, set: { workspace.seekForEditing($0, requestFocus: false) }),
                                       in: 0...workspace.project.duration).controlSize(.small).accessibilityLabel("편집 커서 · 원곡 초")
                                audioPanel
                                tabPanel
                                HStack(spacing: 22) {
                                    Label("미채보 구간은 빈칸으로 유지", systemImage: "square.dashed")
                                    Label("? 음 미확인", systemImage: "questionmark.circle")
                                    Label("점선 잠정 프렛", systemImage: "circle.dashed")
                                }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                            }.padding(20)
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mainWidth = $0 }
                if workspace.inspectorVisible {
                    Divider().overlay(Palette.border)
                    NoteInspector(workspace: workspace).frame(width: 260).disabled(!workspace.canMutateNotes)
                }
            }
            // Recreate project-scoped SwiftUI state/observers after activation. Otherwise old
            // onChange reflow/zoom callbacks can replace the page/window we just restored.
            .id(workspace.editorIdentity)
            .disabled(!workspace.canEdit)
            Divider().overlay(Palette.border)
            statusBar
        }
        .onChange(of: workspace.editorIdentity) { _, _ in noteListOpen = false; tuningOpen = false }
        .onChange(of: workspace.tabInputFocused) { _, focused in if focused { noteListOpen = false; tuningOpen = false } }
        .background(Palette.background).tint(Palette.mint)
        .background(TabKeyboardBridge(workspace: workspace).id(workspace.editorIdentity).allowsHitTesting(false))
        .toolbar { toolbarContent }
        .navigationTitle(workspace.project.title)
        .navigationSubtitle(subtitle)
        .sheet(item: Binding(get: { workspace.exportSnapshot }, set: { if $0 == nil { workspace.cancelExport() } })) { snapshot in
            ScoreExportOptionsView(snapshot: snapshot, format: snapshot.initialFormat,
                submit: { options in Task { _ = await workspace.completeExport(snapshot, options: options) } }, cancel: { workspace.cancelExport() })
        }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("확인") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }

    private var subtitle: String {
        var parts = [clockLabel(workspace.project.duration), workspace.project.tuningDisplay]
        if workspace.isDemo { parts.insert("데모", at: 0) }
        if workspace.dirty { parts.append("편집됨") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("보기", selection: $workspace.scoreView) {
                Label("악보", systemImage: "music.note.list").tag(true)
                Label("구간 편집", systemImage: "waveform").tag(false)
            }.pickerStyle(.segmented).labelStyle(.titleOnly).frame(width: 170).help("악보 보기 / 구간 편집")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.importAudio() } label: { Label("오디오 열기", systemImage: "waveform.badge.plus") }
                .help("오디오 열기 · ⌘O").disabled(workspace.busy || workspace.analyzing || !workspace.canEdit)
            Button { workspace.save() } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .help("프로젝트 저장 · ⌘S").disabled(!workspace.canSave || !workspace.canEdit)
            ProjectSaveMenu(workspace: workspace, prominent: true).disabled(!workspace.canEdit)
            ScoreExportMenu(workspace: workspace, prominent: true).disabled(!workspace.canEdit)
        }
    }

    // MARK: Sidebar

    /// Scrolls when its panels (L/R proposals, stem controls) outgrow the window; otherwise the
    /// whole window layout grows and pushes the top bar off screen. The min height keeps the
    /// footer pinned to the bottom when everything fits.
    private var sidebar: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                sidebarContent.frame(minHeight: proxy.size.height, alignment: .top)
            }.scrollIndicators(.automatic)
        }.background(Palette.panel)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SidebarSection("트랙") {
                VStack(spacing: 2) {
                    ForEach(GuitarLane.allCases) { lane in laneRow(lane) }
                }
            }.help("L/R은 선택한 파일의 채널입니다. 기타 파트 분리를 뜻하지 않습니다.")
            SidebarSection("오디오") {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("원곡").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("다시 연결…") { workspace.importAudio(relink: true) }
                            .buttonStyle(.borderless).font(.system(size: 11)).disabled(!workspace.canLoad)
                    }
                    Text(workspace.audioConnection).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                StemControls(workspace: workspace)
            }
            SidebarSection("분석") {
                VStack(spacing: 6) {
                    metric("BPM", value: workspace.summary?.bpm.map { String(format: "%.1f", $0) } ?? "—")
                    metric("시작 조성", value: workspace.summary?.key ?? "—")
                    metric("박 / 구간", value: "\(workspace.summary?.beats.count ?? 0) / \(workspace.summary?.sections.count ?? 0)")
                }
                if workspace.analyzing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Button("분석 취소") { workspace.cancelAnalysis() }.controlSize(.small)
                    }
                } else {
                    Button { workspace.analyze() } label: { Label("현재 소스 분석", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .controlSize(.small).disabled(!workspace.canAnalyze)
                        .help("현재 자산의 Stereo · L · R 결과를 따로 보관합니다. 분석 결과는 TAB을 만들지 않습니다.")
                }
            }
            if workspace.source != .stereo {
                SidebarSection("음 후보 · \(workspace.source == .left ? "L" : "R")") {
                    Group {
                        Button { workspace.proposePitches(from: workspace.windowStart, to: min(workspace.windowEnd, workspace.windowStart + 60)) } label: {
                            Text("실험적 단음 후보 · 현재 구간").frame(maxWidth: .infinity)
                        }.help("깨끗한 단음용 · 수락하면 잠정 음, 리듬 없음")
                        Button { workspace.proposeChords(from: workspace.windowStart, to: min(workspace.windowEnd, workspace.windowStart + 60)) } label: {
                            Text("코드·다성 후보 · 현재 구간").frame(maxWidth: .infinity)
                        }.help("Basic Pitch로 현재 구간의 코드·다성 음 후보를 찾습니다. 배음이 섞일 수 있습니다.")
                    }.controlSize(.small).disabled(workspace.prepared == nil || workspace.analyzing || workspace.busy)
                    if !workspace.pitchProposals.isEmpty { proposalReview }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button { workspace.openProject() } label: { Label("프로젝트 열기", systemImage: "folder") }
                Spacer()
                Menu("데모") {
                    Button("짧은 데모 · 24초") { workspace.loadDemo() }
                    Button("긴 곡 데모 · 3분") { workspace.loadDemo(long: true) }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(Palette.secondary)
                .disabled(workspace.busy || workspace.analyzing)
        }.padding(.horizontal, 14).padding(.vertical, 16)
    }

    private func laneRow(_ lane: GuitarLane) -> some View {
        let selected = workspace.lane == lane
        return Button {
            workspace.clearSelection(); workspace.lane = lane
            workspace.switchSource(lane == .left ? .left : .right)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(lane == .left ? Palette.mint : Palette.purple).frame(width: 3, height: 16)
                Text(lane.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                Text("\(workspace.project.events.filter { $0.lane == lane }.count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
                    .accessibilityLabel("\(workspace.project.events.filter { $0.lane == lane }.count)개 메모")
            }.padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                .background(selected ? Palette.elevated : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityValue(selected ? "선택됨" : "선택 안 됨")
    }

    // MARK: Transport & editor bars

    private var transport: some View {
        HStack(spacing: 14) {
            Button { workspace.togglePlayback() } label: {
                Image(systemName: workspace.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.background)
                    .frame(width: 32, height: 32).background(Palette.mint, in: Circle())
            }.accessibilityLabel(workspace.playing ? "일시 정지" : "재생").buttonStyle(.plain)
                .disabled(workspace.prepared == nil || workspace.busy).help("재생 / 일시 정지 · Space")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(clockLabel(workspace.cursor)).font(.system(size: 19, weight: .medium, design: .monospaced))
                if !compact {
                    Text(clockLabel(workspace.project.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary)
                }
            }.fixedSize()
            Divider().frame(height: 20)
            Picker("듣기", selection: Binding(get: { workspace.source }, set: { workspace.switchSource($0) })) {
                Text("Stereo").tag(ListeningSource.stereo)
                Text("L").tag(ListeningSource.left)
                Text("R").tag(ListeningSource.right)
            }.labelsHidden().pickerStyle(.segmented).frame(width: compact ? 120 : 150).disabled(workspace.busy)
                .help("듣기 채널 · L/R은 원본 파일의 채널")
            Picker("재생 속도", selection: $workspace.rate) {
                Text("0.5×").tag(Float(0.5)); Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
            }.labelsHidden().frame(width: 68).help("재생 속도")
            Divider().frame(height: 20)
            HStack(spacing: 6) {
                Toggle(isOn: $workspace.looping) { Image(systemName: "repeat") }.toggleStyle(.button)
                    .accessibilityLabel("A–B 반복").accessibilityValue(workspace.looping ? "켜짐" : "꺼짐").help("A–B 반복")
                Button(compact ? "A" : "A \(clockLabel(workspace.loopStart))") { workspace.setLoopStart() }
                    .help("현재 위치를 반복 시작점으로 · [ · \(clockLabel(workspace.loopStart))")
                Button(compact ? "B" : "B \(clockLabel(workspace.loopEnd))") { workspace.setLoopEnd() }
                    .help("현재 위치를 반복 끝점으로 · ] · \(clockLabel(workspace.loopEnd))")
            }.font(.system(size: 11, design: .monospaced)).fixedSize()
            Spacer(minLength: 0)
            if !compact { assetBadge }
        }.controlSize(.small).padding(.horizontal, 16).frame(height: 54).background(Palette.panel)
    }

    private var assetBadge: some View {
        Text(workspace.assetRole == .original ? "원곡" : "기타 스템")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(workspace.assetRole == .original ? Palette.secondary : Palette.mint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((workspace.assetRole == .original ? Palette.elevated : Palette.mint.opacity(0.14)), in: Capsule())
            .help(workspace.assetRole == .original ? workspace.audioConnection : workspace.stemConnection)
    }

    /// Native navigation row (Tab/⌃Tab focus loop) + note tools + selection actions.
    private var editorBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !compact { inputModeBadge }
                EditorNavigationControls(workspace: workspace, openNotes: { noteListOpen = true }, openTuning: { tuningOpen = true })
                    .frame(width: EditorNavigationView.preferredWidth, height: 24).id(workspace.editorIdentity)
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
                Spacer(minLength: 0)
                if !compact { historyTools }
            }.padding(.horizontal, 14).frame(height: 40)
            HStack(spacing: 10) {
                quickEditInfo.layoutPriority(-1)
                Spacer(minLength: 8)
                quickEditTools.fixedSize()
                if compact { Divider().frame(height: 16); historyTools.fixedSize() }
            }.padding(.horizontal, 14).frame(height: 30).disabled(!workspace.canEdit)
            BulkSelectionBar(workspace: workspace).padding(.horizontal, 14).frame(height: 28).disabled(!workspace.canEdit)
        }.background(Palette.panel.opacity(0.55))
    }

    private var historyTools: some View {
        HStack(spacing: 4) {
            ToolIcon(symbol: "arrow.uturn.backward", label: "실행 취소", help: "실행 취소 · ⌘Z") { workspace.performUndo() }
                .disabled(!workspace.canPerformUndo)
            ToolIcon(symbol: "arrow.uturn.forward", label: "다시 실행", help: "다시 실행 · ⇧⌘Z") { workspace.performRedo() }
                .disabled(!workspace.canPerformRedo)
            Divider().frame(height: 16).padding(.horizontal, 2)
            Toggle(isOn: $workspace.inspectorVisible) { Image(systemName: "sidebar.right") }
                .toggleStyle(.button).buttonStyle(.borderless).accessibilityLabel("상세").help("상세 편집 패널 · I")
        }.disabled(!workspace.canEdit)
    }

    private var inputModeBadge: some View {
        Label(workspace.tabInputFocused ? "입력 중" : "탐색", systemImage: "keyboard")
            .font(.system(size: 10, weight: .semibold)).labelStyle(.titleAndIcon)
            .foregroundStyle(workspace.tabInputFocused ? Palette.mint : Palette.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(workspace.tabInputFocused ? Palette.mint.opacity(0.14) : Palette.elevated, in: Capsule())
            .fixedSize()
            .help(workspace.tabInputFocused ? "TAB 입력 · Tab 다음 음 · ⌃Tab 컨트롤로 · ⇧⌃Tab 뒤로"
                  : "컨트롤 탐색 · Tab 이동 · TAB 입력 버튼 또는 ⌘Return으로 입력. 입력 간격은 표시 설정 오른쪽 초 필드")
            .accessibilityIdentifier("editor-input-mode")
    }

    @ViewBuilder private var quickEditInfo: some View {
        if let selected = workspace.selected {
            let shown = workspace.renderedEvent(selected)
            HStack(spacing: 6) {
                Text("\(shown.string)번 줄").foregroundStyle(Palette.mint).monospacedDigit()
                PositionTimeField(workspace: workspace, event: shown).id(selected.id)
                Text("초 · \(shown.fret.map { "\($0)프렛" } ?? "? 프렛")").foregroundStyle(Palette.mint)
            }.font(.system(size: 11)).help("자유 드래그 · Shift 마그넷 · 더블 클릭 확대")
        } else {
            Text("줄 클릭 후 숫자로 프렛 입력 · ↑↓ \(workspace.activeString)번 줄 · 파형 드래그로 반복")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
        }
    }

    private var quickEditTools: some View {
        HStack(spacing: 4) {
            ToolIcon(symbol: "plus.magnifyingglass", label: "선택한 음 주변 2초 확대", help: "선택한 음 주변 2초 확대 · 더블 클릭") { workspace.focusSelectedForPosition() }
                .disabled(workspace.selected == nil)
            ToolIcon(symbol: "speaker.wave.2", label: "선택한 위치부터 듣기", help: "선택한 위치부터 듣기 · Shift+Space") { workspace.auditionSelected() }
                .disabled(workspace.selected == nil)
            ToolIcon(symbol: "trash", label: "선택한 음 삭제", help: "선택한 음 삭제 · Delete") { workspace.deleteSelected() }
                .disabled(workspace.selected == nil)
            Divider().frame(height: 16).padding(.horizontal, 4)
            Toggle("박 스냅", isOn: $workspace.snapToBeat).toggleStyle(.checkbox).font(.system(size: 11))
                .accessibilityLabel("새 음 박 스냅")
                .help("새 음 입력을 분석된 박에 맞춥니다 · 이동은 자유 드래그, Shift로 가까운 음에 정렬")
                .disabled(workspace.scoreSummary?.beats.isEmpty ?? true)
            Button("다음 +\(Int(workspace.entryInterval * 1000))ms") { workspace.advanceEntry() }
                .controlSize(.small).disabled(!workspace.canMutateNotes).help("선택을 마치고 지정한 간격만큼 커서를 이동 · Enter")
            EntryIntervalControl(workspace: workspace)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if workspace.busy {
                ProgressView(value: workspace.loadProgress).controlSize(.small).frame(width: 140)
                Text("오디오 준비 \(Int(workspace.loadProgress * 100))%").monospacedDigit()
                Button("취소") { workspace.cancelLoading() }.buttonStyle(.borderless).font(.system(size: 11))
                Divider().frame(height: 12)
            } else {
                Circle().fill(workspace.analyzing ? .orange : Palette.mint).frame(width: 6, height: 6)
            }
            Text(workspace.sessionPersistenceError ?? workspace.status).lineLimit(1)
                .help(workspace.sessionPersistenceError ?? workspace.status)
            Spacer()
            Text(workspace.saveState.title)
            Divider().frame(height: 12)
            Text(workspace.lane.title)
            Divider().frame(height: 12)
            Text(workspace.project.tuningDisplay).lineLimit(1)
        }
        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        .padding(.horizontal, 14).frame(height: 26).background(Palette.panel)
    }

    /// Click a row to move the cursor to its onset; 수락 inserts one tentative note (⌘Z undoes it).
    private var proposalReview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("후보 \(workspace.pitchProposals.count)개 · \(workspace.proposalLane.title)")
            Button(workspace.pitchProposals.first?.source == .basicPitch
                   ? "강도 \(String(format: "%.1f", PitchProposal.basicPitchAcceptAllAmplitude)) 이상 모두 수락" : "규칙 통과 모두 수락") {
                workspace.acceptQualifiedProposals()
            }
                .disabled(!workspace.pitchProposals.contains(where: \.qualified))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(workspace.pitchProposals.enumerated()), id: \.offset) { _, proposal in
                        proposalRow(proposal)
                    }
                }
            }.frame(maxHeight: 220)
        }.font(.system(size: 9)).buttonStyle(.borderless).disabled(!workspace.canMutateNotes)
    }

    private func proposalRow(_ proposal: PitchProposal) -> some View {
        let note = workspace.proposedNote(proposal)
        let name = proposal.midi.map(TuningDefinition.pitchName) ?? "음 미확인"
        let time = String(format: "%.3fs", proposal.onset)
        return VStack(alignment: .leading, spacing: 3) {
            Button { workspace.seekForEditing(proposal.onset, requestFocus: false) } label: {
                Text("\(time) · \(name) · \(note.string)번 줄 \(note.fret.map { "\($0)프렛" } ?? "?")")
                    .foregroundStyle(.primary)
            }.help("커서를 후보 시작 위치로 이동 · 재생으로 확인")
            HStack(spacing: 8) {
                Text(proposal.label)
                    .foregroundStyle(proposal.qualified ? Palette.mint : Palette.secondary)
                Spacer()
                Button("수락") { workspace.acceptProposals([proposal]) }.accessibilityLabel("\(time) 후보 수락")
                Button("거절") { workspace.rejectProposal(proposal) }.accessibilityLabel("\(time) 후보 거절")
            }
        }.padding(6).background(Palette.elevated, in: RoundedRectangle(cornerRadius: 6))
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("파형").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("L / R · 원본 채널").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
            WaveformView(workspace: workspace).help("클릭해서 이동 · 드래그해서 반복 구간 지정")
        }
    }

    private var tabPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(workspace.lane.title) · TAB").font(.system(size: 12, weight: .semibold))
                Text("\(clockLabel(workspace.windowStart)) — \(clockLabel(workspace.windowEnd))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.tertiary)
                Spacer()
                Toggle("음표 길이", isOn: $workspace.showLengths).toggleStyle(.checkbox).font(.system(size: 11))
                Picker("표시 범위", selection: $workspace.windowLength) {
                    if ![1.0, 2.0, 3.0, 6.0, 12.0, 24.0, 48.0].contains(workspace.windowLength) {
                        Text("현재 범위").tag(workspace.windowLength)
                    }
                    Text("1초").tag(1.0); Text("2초").tag(2.0); Text("3초").tag(3.0)
                    Text("6초").tag(6.0); Text("12초").tag(12.0); Text("24초").tag(24.0); Text("48초").tag(48.0)
                }.labelsHidden().frame(width: 76)
                    .onChange(of: ProjectViewSetting(projectID: workspace.editorIdentity, value: workspace.windowLength)) { previous, current in
                        guard previous.projectID == current.projectID else { return }
                        workspace.zoomPositionWindow(by: 1)
                    }
                HStack(spacing: 2) {
                    ToolIcon(symbol: "plus.magnifyingglass", label: "음 주변 확대") { workspace.zoomPositionWindow(by: 0.5) }
                    ToolIcon(symbol: "minus.magnifyingglass", label: "음 주변 축소") { workspace.zoomPositionWindow(by: 2) }
                    ToolIcon(symbol: "chevron.left", label: "이전 구간") { workspace.moveWindow(-1) }
                    ToolIcon(symbol: "chevron.right", label: "다음 구간") { workspace.moveWindow(1) }
                }
            }.controlSize(.small)
            TabCanvas(workspace: workspace).frame(height: workspace.showLengths ? 308 : 275)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
                .help("줄 클릭 후 숫자로 프렛 입력 · 파형 드래그로 반복 듣기")
            HStack {
                Spacer()
                Text("\(workspace.visibleEvents.count)개 음").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(Palette.secondary); Spacer(); Text(value).monospacedDigit().lineLimit(1) }.font(.system(size: 12))
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
        }.overlay(EditingCursorAXSurface(workspace: workspace, name: "파형")).frame(height: 115).padding(10)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
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
                Text("음 상세").font(.system(size: 13, weight: .semibold))
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("선택한 음 없음").font(.system(size: 13, weight: .medium))
                    Text("TAB 줄을 클릭하면 그 위치에 음이 생깁니다. 프렛을 모르면 ?로 두고 들리는 부분만 적어도 됩니다.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("단축키").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiary)
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
