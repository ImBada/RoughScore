import AppKit
import RoughScoreCore
import SwiftUI

/// Small optional tools beside sparse entry. Every action uses the Workspace transaction owner.
struct BulkSelectionBar: View {
    @ObservedObject var workspace: Workspace
    @State private var offsetOpen = false
    @State private var rangeOpen = false
    @State private var offset = 0.0
    @State private var rangeStart = 0.0
    @State private var rangeEnd = 1.0
    var body: some View {
        HStack(spacing: 10) {
            Text("\(workspace.selectedIDs.count)개 선택").monospacedDigit()
            Button("구간 선택…") {
                rangeStart = workspace.windowStart; rangeEnd = workspace.windowEnd; rangeOpen = true
            }.popover(isPresented: $rangeOpen) {
                VStack(alignment: .leading) {
                    Text("\(workspace.lane.title) · 시작 포함 / 끝 제외")
                    HStack {
                        TextField("선택 시작 · 초", value: $rangeStart, format: .number).frame(width: 95)
                        Text("—")
                        TextField("선택 끝 · 초", value: $rangeEnd, format: .number).frame(width: 95)
                        Button("선택") {
                            if workspace.selectRange(lane: workspace.lane, from: rangeStart, to: rangeEnd) { rangeOpen = false }
                        }
                    }
                }.padding(12)
            }
            if !workspace.selectedIDs.isEmpty {
                BulkActionButton(title: "커서에 복제", identifier: "bulk-duplicate", enabled: workspace.canEditSelection) {
                    _ = workspace.duplicateSelection()
                }
                Button("오프셋…") { offsetOpen = true }.popover(isPresented: $offsetOpen) {
                    HStack {
                        TextField("선택 시간 오프셋 · 초", value: $offset, format: .number).frame(width: 110)
                        Button("전체 이동") { if workspace.offsetSelection(time: offset) { offsetOpen = false } }
                    }.padding(12)
                }
                BulkActionMenu(title: "길이", identifier: "bulk-length", enabled: workspace.canEditSelection,
                    items: [.init(title: "미지정으로 지우기", action: { _ = workspace.setSelectionLength(nil) })] +
                        NoteLength.allCases.map { length in
                            .init(title: length.title, action: { _ = workspace.setSelectionLength(length) })
                        })
                BulkActionMenu(title: "잠정", identifier: "bulk-tentative", enabled: workspace.canEditSelection, items: [
                    .init(title: "잠정으로 표시", action: { _ = workspace.setSelectionTentative(true) }),
                    .init(title: "잠정 해제", action: { _ = workspace.setSelectionTentative(false) })])
                BulkActionMenu(title: "L / R 전송", identifier: "bulk-lanes", enabled: workspace.canEditSelection,
                    items: GuitarLane.allCases.flatMap { target in [
                        .init(title: "\(target.title)로 커서에 복사", action: { _ = workspace.duplicateSelection(targetLane: target) }),
                        .init(title: "\(target.title)로 이동 · 시간 유지", action: { _ = workspace.offsetSelection(time: 0, targetLane: target) })]
                    })
                BulkActionButton(title: "선택 삭제", identifier: "bulk-delete", enabled: workspace.canEditSelection) {
                    workspace.deleteSelected()
                }
            }
            Spacer(minLength: 0)
            if workspace.selectedIDs.isEmpty {
                Text("⌘클릭 추가 · ⌘드래그 구간 · ⌘C/V/D").foregroundStyle(Palette.secondary)
            }
        }.font(.system(size: 10)).buttonStyle(.borderless)
        .help("⌘클릭: 선택 추가/해제 · ⌘드래그: 현재 기타 구간 선택 · ⌘클릭 빈 곳: 커서 이동 · ⌘C/V/D: 복사/붙여넣기/복제")
        .disabled(!workspace.canMutateNotes)
    }
}

/// Native target/action is shared by the actual toolbar and hidden hosted control regressions.
struct BulkActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let enabled: Bool
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: Any?) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke(_:)))
        button.bezelStyle = .inline; button.font = .systemFont(ofSize: 10)
        button.setAccessibilityLabel(title); button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action; button.isEnabled = enabled; button.title = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct BulkActionMenu: NSViewRepresentable {
    struct Item {
        let title: String
        let action: () -> Void
    }
    let title: String
    let identifier: String
    let enabled: Bool
    let items: [Item]
    final class Coordinator: NSObject {
        var items: [Item] = []
        @objc func invoke(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }; items[sender.tag].action()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton { NSPopUpButton(frame: .zero, pullsDown: true) }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.items = items
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.invoke(_:)), keyEquivalent: "")
            entry.tag = index; entry.target = context.coordinator; menu.addItem(entry)
        }
        button.menu = menu; button.isEnabled = enabled; button.font = .systemFont(ofSize: 10)
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
