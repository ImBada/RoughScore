import AppKit
import RoughScoreCore
import SwiftUI

/// Background-only Command gestures. Shift remains owned by the note magnet.
/// Returning nil for ordinary hits leaves the existing sparse entry/loop gestures intact.
@MainActor
final class TabRangeControl: NSView {
    var workspace: Workspace?
    var lane: GuitarLane = .left
    var timeAtX: (Double) -> Double = { $0 }
    private var start: CGPoint?
    private var frozenTime: ((Double) -> Double)?
    private var frozenLane: GuitarLane = .left
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command) else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), workspace?.canMutateNotes == true else { return }
        start = convert(event.locationInWindow, from: nil); frozenTime = timeAtX; frozenLane = lane
    }
    override func mouseUp(with event: NSEvent) {
        guard let start, let time = frozenTime, let workspace else { return }
        defer { self.start = nil; frozenTime = nil }
        let end = convert(event.locationInWindow, from: nil)
        if abs(end.x - start.x) >= 4 {
            _ = workspace.selectRange(lane: frozenLane, from: time(start.x), to: time(end.x))
        } else { workspace.placeSelectionCursor(time(end.x)) }
    }
}

struct TabRangeSurface: NSViewRepresentable {
    let workspace: Workspace
    let lane: GuitarLane
    let timeAtX: (Double) -> Double
    func makeNSView(context: Context) -> TabRangeControl { TabRangeControl() }
    func updateNSView(_ view: TabRangeControl, context: Context) {
        view.workspace = workspace; view.lane = lane; view.timeAtX = timeAtX
    }
}
