import AppKit
import RoughScoreCore
import SwiftUI

/// A collision chip cycles with a click; its count opens the full exact-onset list.
/// Only the label is offset. Projection and magnets always use `position`.
struct DraggableTabNote: View {
    @ObservedObject var workspace: Workspace
    let event: TabEvent
    let target: NotePointerTarget
    let position: (TabEvent) -> CGPoint
    let destination: (TabEvent, CGSize) -> (time: Double, string: Int)
    let magnetTargets: [TabEvent]
    let displayScale: Double
    let compact: Bool
    let background: Color
    let ink: Color
    let tentative: Color
    @State private var choosing = false

    var body: some View {
        let shown = workspace.renderedEvent(event)
        let anchor = position(shown)
        let originalAnchor = position(event)
        let center = CGPoint(x: target.center.x + anchor.x - originalAnchor.x,
                             y: target.center.y + anchor.y - originalAnchor.y)
        let countWidth = target.events.count > 1 ? target.width / 2 : 0
        HStack(spacing: 0) {
            Text(shown.fret.map(String.init) ?? "?")
                .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(workspace.selectedID == event.id || compact ? ink : (shown.fret == nil ? Palette.secondary : .white))
                .frame(width: target.width - countWidth, height: target.height)
                .background(workspace.selectedID == event.id ? Palette.mint : background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(workspace.positionMagnetTargetID == event.id ? Palette.mint : (shown.tentative ? tentative : .clear),
                                                                     style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            if countWidth > 0 {
                Text("×\(target.events.count)").lineLimit(1).minimumScaleFactor(0.6).font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(compact ? ink : Palette.mint)
                    .frame(width: countWidth, height: target.height)
                    .background(background, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .overlay(NotePointerSurface(chooserWidth: countWidth,
            label: "\(String(shown.time))초 · \(shown.lane.title) · \(shown.string)번 줄 · \(shown.fret.map(String.init) ?? "?") · \(target.events.count)개 음",
            actions: NotePointerControl.Actions(
                click: { workspace.select(target.next(selectedID: workspace.selectedID)) },
                chooser: { choosing = true },
                doubleClick: { workspace.select(event); workspace.focusSelectedForPosition() },
                begin: { workspace.beginPositionDrag(event) },
                update: { delta, precise, shift in updatePreview(delta, precise: precise, shift: shift) },
                end: { workspace.commitPositionDrag() })))
        .frame(width: target.width, height: target.height)
        .position(center)
        .popover(isPresented: $choosing) {
            NoteCollisionChooser(workspace: workspace, events: target.events) { choosing = false }
        }
        .help(target.events.count > 1
            ? "\(target.events.count)개 겹친 음 · 클릭: 다음 음 · ×개수: 목록 · 선택한 프렛을 드래그 · 선/점은 실제 시작 위치"
            : "\(clockLabel(shown.time)) · \(shown.string)번 줄 · Shift: 가까운 음에 마그넷 정렬 · Option: 정밀 이동 · 더블 클릭: 2초 확대")
    }

    private func updatePreview(_ delta: CGSize, precise: Bool, shift: Bool) {
        guard workspace.positionDrag?.id == event.id else { return }
        let translation = CGSize(width: delta.width * (precise ? 0.2 : 1), height: delta.height)
        let target = destination(event, translation)
        var raw = event; raw.time = target.time; raw.string = target.string
        let scale = max(0.001, displayScale)
        let anchors = magnetTargets.filter { $0.id != event.id && $0.lane == event.lane }.map {
            NoteMagnetAnchor(id: $0.id, time: $0.time, x: position($0).x * scale)
        }
        workspace.previewMagneticPosition(time: target.time, string: target.string,
                                          screenX: position(raw).x * scale, anchors: anchors, shift: shift)
    }
}

struct NoteCollisionChooser: View {
    @ObservedObject var workspace: Workspace
    let events: [TabEvent]
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("겹친 음 \(events.count)개 · 실제 시작 시간").font(.system(size: 12, weight: .semibold))
            Text("음을 선택하고 프렛을 드래그 · 더블 클릭하면 2초 확대")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(String(event.time))s · \(event.lane == .left ? "L" : "R") · \(event.string)번 줄 · \(event.fret.map(String.init) ?? "?")프렛\(event.tentative ? " · 잠정" : "")")
                                    if let length = event.length { Text(length.symbol) }
                                    if !event.memo.isEmpty { Text(event.memo).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                                if workspace.selectedID == event.id { Image(systemName: "checkmark") }
                        }.font(.system(size: 11, design: .monospaced)).padding(6)
                        .overlay(NotePointerSurface(chooserWidth: 0,
                            label: "음 \(index + 1) · \(String(event.time))초 · \(event.memo)",
                            actions: NotePointerControl.Actions(
                                click: { workspace.select(event); dismiss() }, chooser: {},
                                doubleClick: { workspace.select(event); dismiss() },
                                begin: {}, update: { _, _, _ in }, end: {})))
                    }
                }
            }.frame(maxHeight: 260)
        }.padding(12).frame(width: 390)
    }
}

/// Both actual view paths share the same grouping, target surface and drag callbacks.
struct PointerTabNotes: View {
    @ObservedObject var workspace: Workspace
    let events: [TabEvent]
    let bounds: ClosedRange<Double>
    let position: (TabEvent) -> CGPoint
    let destination: (TabEvent, CGSize) -> (time: Double, string: Int)
    let displayScale: Double
    let compact: Bool
    let background: Color
    let ink: Color
    let tentative: Color

    var body: some View {
        let layout = NotePointerLayout(events: events, compact: compact, displayScale: displayScale,
                                       bounds: bounds, position: position)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for target in layout.targets {
                    let event = target.representative(selectedID: workspace.selectedID)
                    let shown = workspace.renderedEvent(event)
                    let anchor = position(shown), original = position(event)
                    let center = CGPoint(x: target.center.x + anchor.x - original.x,
                                         y: target.center.y + anchor.y - original.y)
                    if target.events.count > 1 || abs(center.x - anchor.x) > 0.1 {
                        // Leaders sit below the chips; ticks show every original onset.
                        let y = center.y + target.height / 2 + 2
                        var leader = Path(); leader.move(to: CGPoint(x: center.x, y: center.y))
                        leader.addLine(to: CGPoint(x: center.x, y: y)); leader.addLine(to: CGPoint(x: anchor.x, y: y))
                        leader.addLine(to: anchor)
                        context.stroke(leader, with: .color(tentative), lineWidth: 0.7)
                        for candidate in target.events {
                            let point = position(workspace.renderedEvent(candidate))
                            context.fill(Path(CGRect(x: point.x - 0.7, y: point.y + target.height / 2, width: 1.4, height: 3)), with: .color(workspace.positionMagnetTargetID == candidate.id ? Palette.mint : tentative))
                        }
                    }
                }
            }.allowsHitTesting(false)
            ForEach(layout.targets) { target in
                DraggableTabNote(workspace: workspace, event: target.representative(selectedID: workspace.selectedID),
                    target: target, position: position, destination: destination, magnetTargets: events,
                    displayScale: displayScale, compact: compact, background: background, ink: ink, tentative: tentative)
            }
        }
    }
}

struct PositionTimeField: View {
    @ObservedObject var workspace: Workspace
    let event: TabEvent
    @State private var text = ""
    @State private var displayedText = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("초", text: $text)
            .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
            .frame(width: 82).focused($focused).disabled(!workspace.canMutateNotes).help("초 단위 위치 입력 · Enter로 적용")
            .onAppear { refresh() }
            .onChange(of: event.time) { _, _ in if !focused { refresh() } }
            .onSubmit { apply(); focused = false; workspace.requestKeyboardFocus?() }
            .onChange(of: focused) { previous, current in if previous && !current { apply() } }
    }
    private func refresh() {
        let actual = workspace.project.events.first { $0.id == event.id }?.time ?? event.time
        displayedText = String(format: "%.6f", actual); text = displayedText
    }
    private func apply() {
        _ = workspace.applyPositionTimeInput(text, displayed: displayedText, eventID: event.id)
        refresh()
    }
}
