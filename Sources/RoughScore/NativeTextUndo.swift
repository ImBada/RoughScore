import AppKit

/// Uses the active AppKit text editor's own history; no project restore or TAB focus request occurs.
@MainActor
final class NativeTextUndoTarget {
    let manager: UndoManager?
    weak var editor: NSTextView?
    init(_ manager: UndoManager?, editor: NSTextView? = nil) { self.manager = manager; self.editor = editor }
    var canUndo: Bool { manager?.canUndo ?? false }
    var canRedo: Bool { manager?.canRedo ?? false }
    func undo() {
        guard canUndo else { return }
        if let editor, editor.responds(to: Selector(("undo:"))) { editor.perform(Selector(("undo:")), with: nil) }
        else { manager?.undo() }
        editor?.didChangeText() // NSTextView's undo storage changes must reach the model delegate too.
    }
    func redo() {
        guard canRedo else { return }
        if let editor, editor.responds(to: Selector(("redo:"))) { editor.perform(Selector(("redo:")), with: nil) }
        else { manager?.redo() }
        editor?.didChangeText()
    }

    static func active() -> NativeTextUndoTarget? {
        guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView else { return nil }
        // A focused text editor consumes undo even at its history boundary.
        return NativeTextUndoTarget(editor.undoManager, editor: editor)
    }
}
