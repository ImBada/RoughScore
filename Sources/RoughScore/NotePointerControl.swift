import AppKit
import SwiftUI

/// The actual note surface used in both score and timeline, also hosted by pointer tests.
/// Freeze callbacks on mouse-down: observable selection/layout changes during a drag
/// must not transfer ownership to a different coincident event.
@MainActor
final class NotePointerControl: NSView {
    struct Actions {
        var click: () -> Void
        var available: () -> Bool = { true }
        var accessibilityPress: (() -> Bool)? = nil
        var custom: [(String, () -> Bool)] = []
        var toggle: (() -> Void)? = nil
        var chooser: () -> Void
        var doubleClick: () -> Void
        var begin: () -> Void
        var update: (CGSize, Bool, Bool) -> Void
        var end: () -> Void
    }
    var actions: Actions?
    var chooserWidth = 0.0
    var navigationGroup: UUID?
    var hitGroup: UUID?
    private var active: Actions?
    private var start = CGPoint.zero
    private var axes = CGSize(width: 1, height: -1)
    private var dragging = false
    private var precise = false
    private var inChooser = false
    private var clicks = 1
    private var adding = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { actions?.available() == true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard navigationGroup != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  let first = self.navigationPeers.first, first === self else { return }
            if !(window.firstResponder is NotePointerControl) { window.makeFirstResponder(self) }
        }
    }
    private var navigationPeers: [NotePointerControl] {
        guard let group = navigationGroup, let root = window?.contentView else { return [] }
        func walk(_ view: NSView) -> [NotePointerControl] {
            (view as? NotePointerControl).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(root).filter { $0.navigationGroup == group && $0.actions?.available() == true }
    }
    override func isAccessibilityEnabled() -> Bool { actions?.available() ?? false }
    override func keyDown(with event: NSEvent) {
        if navigationGroup != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 48 || event.keyCode == 125 || event.keyCode == 126 {
            let peers = navigationPeers
            if let index = peers.firstIndex(where: { $0 === self }), !peers.isEmpty {
                let backwards = event.keyCode == 126 || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
                window?.makeFirstResponder(peers[(index + (backwards ? -1 : 1) + peers.count) % peers.count])
            }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 36 || event.keyCode == 49 { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let ownHit = super.hitTest(point), let group = hitGroup,
              let root = window?.contentView else { return super.hitTest(point) }
        let windowPoint = convert(convert(point, from: superview), to: nil)
        func walk(_ node: NSView) -> [NotePointerControl] {
            (node as? NotePointerControl).map { [$0] } ?? node.subviews.flatMap(walk)
        }
        // Resolve ownership using actual displaced screen frames, never model onset or view z-order.
        let candidates = walk(root).filter {
            $0.hitGroup == group && !$0.isHidden && $0.visibleRect.contains($0.convert(windowPoint, from: nil))
        }
        return candidates.min {
            let a = $0.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil)
            let b = $1.convert(CGPoint(x: $1.bounds.midX, y: $1.bounds.midY), to: nil)
            let da = hypot(windowPoint.x - a.x, windowPoint.y - a.y)
            let db = hypot(windowPoint.x - b.x, windowPoint.y - b.y)
            return da == db ? ($0.accessibilityIdentifier() < $1.accessibilityIdentifier()) : da < db
        } ?? ownHit
    }

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
    func detach() { actions = nil; active = nil }
    override func accessibilityPerformPress() -> Bool {
        guard let actions, actions.available() else { return false }
        if let press = actions.accessibilityPress { return press() }
        actions.click(); return true
    }
}

struct NotePointerSurface: NSViewRepresentable {
    let chooserWidth: Double
    let label: String
    var selected = false
    var identifier: String? = nil
    var detail = ""
    var navigationGroup: UUID? = nil
    var hitGroup: UUID? = nil
    let actions: NotePointerControl.Actions
    func makeNSView(context: Context) -> NotePointerControl { NotePointerControl() }
    static func dismantleNSView(_ view: NotePointerControl, coordinator: ()) { view.detach() }
    func updateNSView(_ view: NotePointerControl, context: Context) {
        view.actions = actions; view.chooserWidth = chooserWidth; view.navigationGroup = navigationGroup; view.hitGroup = hitGroup
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button); view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilitySelected(selected)
        view.setAccessibilityValue((selected ? "선택됨" : "선택 안 됨") + (detail.isEmpty ? "" : " · " + detail))
        var custom = actions.custom
        if actions.toggle != nil {
            custom.insert(("선택 추가 또는 해제", { [weak view] in
                guard let actions = view?.actions, actions.available(), let toggle = actions.toggle else { return false }
                toggle(); return true
            }), at: 0)
        }
        if chooserWidth > 0 {
            custom.append(("겹친 음 목록", { [weak view] in
                guard let view, let actions = view.actions, actions.available(), view.chooserWidth > 0 else { return false }
                actions.chooser(); return true
            }))
        }
        view.setAccessibilityCustomActions(custom.map { name, handler in NSAccessibilityCustomAction(name: name, handler: handler) })
    }
}
