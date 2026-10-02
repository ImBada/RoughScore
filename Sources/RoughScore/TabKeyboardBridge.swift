import AppKit
import SwiftUI

/// TAB selection owns keyboard focus; ordinary text fields keep their native typing behavior.
struct TabKeyboardBridge: NSViewRepresentable {
    let workspace: Workspace
    func makeNSView(context: Context) -> TabKeyboardView {
        let view = TabKeyboardView()
        view.workspace = workspace
        workspace.requestKeyboardFocus = { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }
    func updateNSView(_ nsView: TabKeyboardView, context: Context) { nsView.workspace = workspace }
}

@MainActor
final class TabKeyboardView: NSView {
    weak var workspace: Workspace?
    override var acceptsFirstResponder: Bool { true }
    override func flagsChanged(with event: NSEvent) {
        workspace?.updatePositionModifiers(shift: event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let workspace, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else {
            super.keyDown(with: event); return
        }
        guard workspace.canEdit else {
            if event.keyCode == 53 { workspace.cancelLoading() }
            return
        }
        let text = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if text.count == 1, let digit = Int(text), (0...9).contains(digit), !event.modifierFlags.contains(.option) {
            workspace.inputDigit(digit, at: event.timestamp); return
        }
        switch event.keyCode {
        case 51, 117: workspace.deleteSelected()
        case 126: workspace.moveSelectedString(by: -1)
        case 125: workspace.moveSelectedString(by: 1)
        case 123: workspace.nudgeSelectedTime(by: event.modifierFlags.contains(.shift) ? -0.01 : -0.05)
        case 124: workspace.nudgeSelectedTime(by: event.modifierFlags.contains(.shift) ? 0.01 : 0.05)
        case 48: workspace.selectAdjacentEvent(backwards: event.modifierFlags.contains(.shift))
        case 36, 76: workspace.finishEntry()
        case 53: workspace.clearSelection()
        case 49:
            if event.modifierFlags.contains(.shift) { workspace.auditionSelected() }
            else { workspace.togglePlayback() }
        default:
            if event.characters == "?" { workspace.markUnknown() }
            else {
                switch text {
                case "t": workspace.toggleTentative()
                case "i": workspace.inspectorVisible.toggle()
                case "s": workspace.switchSource(.stereo)
                case "l": workspace.switchSource(.left)
                case "r": workspace.switchSource(.right)
                case "[": workspace.setLoopStart()
                case "]": workspace.setLoopEnd()
                case "\\": workspace.looping.toggle()
                case "-": workspace.rate = workspace.rate > 0.75 ? 0.75 : 0.5
                case "=", "+": workspace.rate = workspace.rate < 0.75 ? 0.75 : 1
                default: super.keyDown(with: event)
                }
            }
        }
    }
}
