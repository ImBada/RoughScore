import AppKit
import RoughScoreCore
import SwiftUI

/// A stable staff coordinate space keeps the pointer offset intact while the chip moves.
struct DraggableTabNote: View {
    @ObservedObject var workspace: Workspace
    let event: TabEvent
    let space: String
    let position: (TabEvent) -> CGPoint
    let destination: (TabEvent, CGSize) -> (time: Double, string: Int)
    let magnetTargets: [TabEvent]
    let displayScale: Double
    let compact: Bool
    let background: Color
    let ink: Color
    let tentative: Color
    @State private var tracking = false
    @State private var precise = false

    var body: some View {
        let shown = workspace.renderedEvent(event)
        Button { workspace.select(event) } label: {
            Text(shown.fret.map(String.init) ?? "?")
                .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(workspace.selectedID == event.id || compact ? ink : (shown.fret == nil ? Palette.secondary : .white))
                .frame(width: compact ? 24 : 30, height: compact ? 14 : 26)
                .background(workspace.selectedID == event.id ? Palette.mint : background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(workspace.positionMagnetTargetID == event.id ? Palette.mint : (shown.tentative ? tentative : .clear),
                                                                     style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        }.buttonStyle(.plain)
            .position(position(shown))
            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                .onChanged { value in
                    if !tracking {
                        tracking = true
                        precise = NSEvent.modifierFlags.contains(.option)
                        workspace.beginPositionDrag(event)
                    }
                    guard workspace.positionDrag?.id == event.id else { return }
                    updatePreview(value.translation)
                }.onEnded { value in
                    if workspace.positionDrag?.id == event.id {
                        updatePreview(value.translation)
                        workspace.commitPositionDrag()
                    }
                    tracking = false
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                workspace.select(event); workspace.focusSelectedForPosition()
            })
            .help("\(clockLabel(shown.time)) · \(shown.string)번 줄 · Shift: 가까운 음에 마그넷 정렬 · Option: 정밀 이동 · 더블 클릭: 2초 확대")
    }

    private func updatePreview(_ delta: CGSize) {
        let translation = CGSize(width: delta.width * (precise ? 0.2 : 1), height: delta.height)
        let target = destination(event, translation)
        var raw = event; raw.time = target.time; raw.string = target.string
        let scale = max(0.001, displayScale)
        let anchors = magnetTargets.filter { $0.id != event.id && $0.lane == event.lane }.map {
            NoteMagnetAnchor(id: $0.id, time: $0.time, x: position($0).x * scale)
        }
        workspace.previewMagneticPosition(time: target.time, string: target.string,
                                          screenX: position(raw).x * scale, anchors: anchors,
                                          shift: NSEvent.modifierFlags.contains(.shift))
    }
}

struct PositionTimeField: View {
    @ObservedObject var workspace: Workspace
    let event: TabEvent
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("초", text: $text)
            .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
            .frame(width: 82).focused($focused).help("초 단위 위치 입력 · Enter로 적용")
            .onAppear { refresh() }
            .onChange(of: event.time) { _, _ in if !focused { refresh() } }
            .onSubmit { apply(); focused = false; workspace.requestKeyboardFocus?() }
            .onChange(of: focused) { previous, current in if previous && !current { apply() } }
    }
    private func refresh() { text = String(format: "%.3f", event.time) }
    private func apply() {
        guard workspace.selectedID == event.id else { return }
        if let time = Double(text.replacingOccurrences(of: ",", with: ".")), time.isFinite {
            workspace.moveSelectedPosition(to: time); workspace.revealSelectedPosition()
        }
        text = String(format: "%.3f", workspace.selected?.time ?? event.time)
    }
}
