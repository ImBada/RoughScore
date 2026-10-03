import AppKit
import SwiftUI

/// The actual note surface used in both score and timeline, also hosted by pointer tests.
/// Freeze callbacks on mouse-down: observable selection/layout changes during a drag
/// must not transfer ownership to a different coincident event.
@MainActor
final class NotePointerControl: NSView {
    struct Actions {
        var click: () -> Void
        var toggle: (() -> Void)? = nil
        var chooser: () -> Void
        var doubleClick: () -> Void
        var begin: () -> Void
        var update: (CGSize, Bool, Bool) -> Void
        var end: () -> Void
    }
    var actions: Actions?
    var chooserWidth = 0.0
    private var active: Actions?
    private var start = CGPoint.zero
    private var axes = CGSize(width: 1, height: -1)
    private var dragging = false
    private var precise = false
    private var inChooser = false
    private var clicks = 1
    private var adding = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        active = actions; start = event.locationInWindow
        let origin = convert(CGPoint.zero, to: nil)
        axes = CGSize(width: convert(CGPoint(x: 1, y: 0), to: nil).x - origin.x,
                      height: convert(CGPoint(x: 0, y: 1), to: nil).y - origin.y)
        adding = event.modifierFlags.contains(.command)
        dragging = false; precise = event.modifierFlags.contains(.option); clicks = event.clickCount
        let local = convert(event.locationInWindow, from: nil)
        inChooser = chooserWidth > 0 && local.x >= bounds.width - chooserWidth
    }
    override func mouseDragged(with event: NSEvent) {
        guard let active, !inChooser, !adding else { return }
        let point = event.locationInWindow
        guard abs(axes.width) > 0.001, abs(axes.height) > 0.001 else { return }
        let delta = CGSize(width: (point.x - start.x) / axes.width, height: (point.y - start.y) / axes.height)
        if !dragging, hypot(point.x - start.x, point.y - start.y) >= 3 {
            dragging = true; active.begin()
        }
        if dragging { active.update(delta, precise, event.modifierFlags.contains(.shift)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let active else { return }
        if dragging { mouseDragged(with: event); active.end() }
        else if inChooser { active.chooser() }
        else if adding { active.toggle?() }
        else if clicks == 2 { active.doubleClick() }
        else { active.click() }
        self.active = nil; dragging = false
    }
    override func accessibilityPerformPress() -> Bool {
        guard let actions else { return false }; actions.click(); return true
    }
}

struct NotePointerSurface: NSViewRepresentable {
    let chooserWidth: Double
    let label: String
    var selected = false
    let actions: NotePointerControl.Actions
    func makeNSView(context: Context) -> NotePointerControl { NotePointerControl() }
    func updateNSView(_ view: NotePointerControl, context: Context) {
        view.actions = actions; view.chooserWidth = chooserWidth
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button); view.setAccessibilityLabel(label)
        view.setAccessibilityValue(selected ? "선택됨" : "선택 안 됨")
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "선택 추가 또는 해제") { [weak view] in
                guard let toggle = view?.actions?.toggle else { return false }; toggle(); return true
            },
            NSAccessibilityCustomAction(name: "겹친 음 목록") { [weak view] in
                guard let view, view.chooserWidth > 0 else { return false }; view.actions?.chooser(); return true
            }
        ])
    }
}
