import AppKit
import SwiftUI

/// A plain AppKit editor retains its own caret, marked text and native undo history.
struct MemoEditor: NSViewRepresentable {
    let workspace: Workspace
    let eventID: UUID
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, eventID: eventID) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = MemoTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
        view.isRichText = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 11); view.textColor = .labelColor; view.drawsBackground = false
        view.textContainerInset = CGSize(width: 6, height: 6)
        view.minSize = NSSize(width: 0, height: 74)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.onFocus = { [weak coordinator = context.coordinator] focused in
            guard let coordinator else { return }
            if focused { coordinator.workspace?.beginMemoEditing(eventID: coordinator.eventID) }
            else { coordinator.workspace?.endMemoEditing(eventID: coordinator.eventID) }
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MemoTextView else { return }
        let memo = workspace.project.events.first { $0.id == eventID }?.memo ?? ""
        if context.coordinator.eventID != eventID {
            workspace.endMemoEditing(eventID: context.coordinator.eventID)
            context.coordinator.eventID = eventID; view.history.removeAllActions()
        }
        // Do not rewrite identical text: native insertion/undo/composition owns the caret.
        if view.string != memo {
            let range = view.selectedRange()
            view.string = memo; view.history.removeAllActions()
            let count = (memo as NSString).length
            let location = min(range.location, count)
            view.setSelectedRange(NSRange(location: location, length: min(range.length, count - location)))
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        weak var workspace: Workspace?
        var eventID: UUID
        init(workspace: Workspace, eventID: UUID) { self.workspace = workspace; self.eventID = eventID }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            workspace?.setMemo(view.string, eventID: eventID)
        }
    }
}

@MainActor
final class MemoTextView: NSTextView {
    let history = UndoManager()
    var onFocus: ((Bool) -> Void)?
    override var undoManager: UndoManager? { history }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }
}
