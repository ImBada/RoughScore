import AppKit
import SwiftUI
import RoughScoreCore

/// TAB selection owns keyboard focus; ordinary text fields keep their native typing behavior.
struct TabKeyboardBridge: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    func makeNSView(context: Context) -> TabKeyboardView { TabKeyboardView() }
    func updateNSView(_ view: TabKeyboardView, context: Context) {
        view.workspace = workspace; view.editorID = workspace.editorIdentity
        workspace.keyboardFocusOwner = view.owner
        let identity = workspace.editorIdentity
        workspace.requestKeyboardFocus = { [weak view, weak workspace] in
            guard let view, let workspace, workspace.editorIdentity == identity,
                  workspace.keyboardFocusOwner == view.owner, workspace.canEdit else { return }
            if view.window?.isVisible == true { view.window?.makeKey() }
            view.window?.makeFirstResponder(view)
        }
    }
    static func dismantleNSView(_ view: TabKeyboardView, coordinator: ()) {
        if let workspace = view.workspace, workspace.keyboardFocusOwner == view.owner {
            workspace.requestKeyboardFocus = nil; workspace.keyboardFocusOwner = nil
            workspace.tabInputFocused = false
        }
        view.workspace = nil
    }
}

@MainActor
final class TabKeyboardView: NSView {
    weak var workspace: Workspace?
    let owner = UUID()
    var editorID: UUID?
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        workspace?.tabInputFocused = true; return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        workspace?.tabInputFocused = false; return true
    }
    // Tests use a unique named pasteboard; production uses the normal clipboard.
    var pasteboard = NSPasteboard.general
    @objc func copy(_ sender: Any?) { _ = workspace?.copySelection(to: pasteboard) }
    @objc func paste(_ sender: Any?) { _ = workspace?.pasteSelection(from: pasteboard) }
    @objc func cut(_ sender: Any?) {
        guard workspace?.copySelection(to: pasteboard) == true else { return }
        workspace?.deleteSelected()
    }
    override func selectAll(_ sender: Any?) { workspace?.selectAllInLane() }
    @objc func duplicate(_ sender: Any?) { _ = workspace?.duplicateSelection() }
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers Control-Tab/backtab as a key equivalent before keyDown.
        // Claim it only while this editor owns the responder, before native traversal.
        guard window?.firstResponder === self, let workspace,
              editorID == nil || editorID == workspace.editorIdentity,
              event.keyCode == 48, event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return workspace.requestControlFocus?(event.modifierFlags.contains(.shift)) ?? false
    }
    override func flagsChanged(with event: NSEvent) {
        workspace?.updatePositionModifiers(shift: event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let workspace, editorID == nil || editorID == workspace.editorIdentity else { super.keyDown(with: event); return }
        // Explicit control navigation is bridge-local; VoiceOver and Command chords pass through.
        if event.keyCode == 48, event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            _ = workspace.requestControlFocus?(event.modifierFlags.contains(.shift)); return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 36,
           !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            workspace.requestKeyboardFocus?(); return
        }
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil)
            case "v": paste(nil)
            case "x": cut(nil)
            case "a": selectAll(nil)
            case "d": duplicate(nil)
            case "z":
                if event.modifierFlags.contains(.shift) { workspace.performRedo() } else { workspace.performUndo() }
            default: super.keyDown(with: event)
            }
            return
        }
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
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
        case 36, 76: workspace.advanceEntry()
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
