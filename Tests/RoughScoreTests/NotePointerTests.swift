import AppKit
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor
@Suite(.serialized)
struct NotePointerTests {
    @Test(arguments: [0.35, 1.0], [4, 8])
    func denseAndCoincidentTargetsAreIndividuallyReachable(scale: Double, measures: Int) throws {
        let row = try #require(ScoreLayout(duration: 32, measuresPerSystem: measures).systems.first)
        let events = [TabEvent(time: 1, lane: .left, string: 3, memo: "unknown"),
                      TabEvent(time: 1, lane: .left, string: 3, fret: 12, tentative: true),
                      TabEvent(time: 1.05, lane: .left, string: 3, fret: 7),
                      TabEvent(time: 1.1, lane: .left, string: 3, fret: 9),
                      TabEvent(time: row.end.nextDown, lane: .left, string: 3)]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(events)
        let layout = NotePointerLayout(events: events, compact: true, displayScale: scale, bounds: 50...650) {
            CGPoint(x: 50 + row.fraction(at: $0.time) * 600, y: 66)
        }
        #expect(layout.targets.contains { $0.events.count >= 4 })
        for (index, target) in layout.targets.enumerated() {
            #expect(layout.hit(at: target.center)?.id == target.id)
            for other in layout.targets.dropFirst(index + 1) { #expect(!target.frame.intersects(other.frame)) }
            var selected: UUID?
            var reached = Set<UUID>()
            for _ in target.events {
                let event = target.next(selectedID: selected); reached.insert(event.id); selected = event.id
            }
            #expect(reached == Set(target.events.map(\.id)))
        }
        #expect(Set(layout.targets.flatMap { $0.events.map(\.id) }) == Set(events.map(\.id)))
        #expect(try encoder.encode(events) == original)
    }
    private func workspace(_ events: [TabEvent], duration: Double = 32) -> Workspace {
        var services = WorkspaceServices.live
        services.rememberProject = { _ in }; services.lastProject = { nil }; services.chooseSaveDestination = { _ in nil }
        let workspace = Workspace(services: services)
        workspace.project = ScoreProject(duration: duration, events: events)
        workspace.windowStart = 0; workspace.windowLength = 16; workspace.snapToBeat = false
        return workspace
    }

    @MainActor private final class Host {
        let view: NSHostingView<AnyView>
        let window: NSWindow
        init(_ content: some View, height: Double = 290) {
            _ = NSApplication.shared
            view = NSHostingView(rootView: AnyView(content))
            view.frame = CGRect(x: 0, y: 0, width: 666, height: height)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            settle()
        }
        func settle() {
            view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            view.layoutSubtreeIfNeeded()
        }
        func close() { window.contentView = nil; window.close() }
        func controls() -> [NotePointerControl] {
            func walk(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(walk) }
            return walk(view).compactMap { $0 as? NotePointerControl }
        }
        func event(_ type: NSEvent.EventType, control: NotePointerControl, delta: CGSize = .zero,
                   flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let point = control.convert(CGPoint(x: (control.bounds.width - control.chooserWidth) / 2 + delta.width,
                                                 y: control.bounds.height / 2 + delta.height), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                timestamp: 100, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func click(_ control: NotePointerControl) throws {
            let down = try event(.leftMouseDown, control: control)
            let parentPoint = view.superview!.convert(down.locationInWindow, from: nil)
            // NSView.hitTest takes the point in its superview's coordinate space.
            let correct = view.hitTest(parentPoint) === control
            #expect(correct)
            control.mouseDown(with: down)
            control.mouseUp(with: try event(.leftMouseUp, control: control))
            settle()
        }
    }

    @Test(arguments: [false, true])
    func hostedActualScoreAndTimelineCycleEditAndDragEveryCoincidence(score: Bool) throws {
        let notes = [TabEvent(time: 1.123456789, lane: .left, string: 3, memo: "unknown"),
                     TabEvent(time: 1.123456789, lane: .left, string: 3, fret: 12, length: .eighth, tentative: true, memo: "second"),
                     TabEvent(time: 1.173456789, lane: .left, string: 3, fret: 7),
                     TabEvent(time: 1.223456789, lane: .left, string: 3, fret: 9)]
        let other = TabEvent(time: notes[0].time, lane: .right, string: 3, memo: "R independent")
        let workspace = workspace(notes + [other]); defer { workspace.shutdown() }
        workspace.measuresPerSystem = 8
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = score ? Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: 1), height: 123)
                         : Host(TabCanvas(workspace: workspace))
        defer { host.close() }
        let before = workspace.project
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let serialized = try encoder.encode(before.events)
        #expect(host.controls().count == 1)
        var reached = Set<UUID>()
        for _ in notes {
            let control = try #require(host.controls().first)
            try host.click(control)
            let event = try #require(workspace.selected)
            reached.insert(event.id)
            #expect(workspace.project == before)
            #expect(try encoder.encode(workspace.project.events) == serialized)
        }
        #expect(reached == Set(notes.map(\.id)))
        // Each candidate is directly draggable after cycling to it; vertical movement
        // preserves the exact onset, unknown fret, memo, optional rhythm and lane.
        for id in reached.sorted(by: { $0.uuidString < $1.uuidString }) {
            for _ in 0..<notes.count {
                if workspace.selectedID == id { break }
                try host.click(try #require(host.controls().first))
            }
            let original = try #require(workspace.selected)
            let control = try #require(host.controls().first)
            let down = try host.event(.leftMouseDown, control: control)
            control.mouseDown(with: down)
            let delta = CGSize(width: 0, height: score ? 14 : 32)
            func dragEvent(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type,
                    location: CGPoint(x: down.locationInWindow.x, y: down.locationInWindow.y - delta.height),
                    modifierFlags: [], timestamp: 101, windowNumber: host.window.windowNumber,
                    context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            }
            control.mouseDragged(with: try dragEvent(.leftMouseDragged))
            #expect(workspace.positionDrag?.id == id)
            #expect(workspace.project == before)
            // Selection changes during an exclusive drag cannot replace its owner.
            workspace.select(other); workspace.inputDigit(8, at: 10)
            host.settle()
            control.mouseUp(with: try dragEvent(.leftMouseUp))
            var expected = original; expected.string += 1
            #expect(workspace.selected == expected)
            #expect(workspace.project.events.first { $0.id == other.id } == other)
            workspace.undoEdit(); host.settle(); #expect(workspace.project == before)
        }
        // Repeated pointer selection resets the two-digit buffer for the new owner.
        try host.click(try #require(host.controls().first)); let editedID = try #require(workspace.selectedID)
        workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.8)
        #expect(workspace.selected?.fret == 12)
        #expect(workspace.selected?.time == before.events.first { $0.id == editedID }?.time)
        try host.click(try #require(host.controls().first)); #expect(workspace.selectedID != editedID)
        workspace.inputDigit(7, at: 100.85); #expect(workspace.selected?.fret == 7)
        #expect(Set(workspace.project.events.map(\.id)) == Set(before.events.map(\.id)))
    }

    @Test func layoutSeparatesLanesStringsZoomAndExclusiveRowBoundaries() throws {
        let duration = 32.0
        let rows = ScoreLayout(duration: duration, measuresPerSystem: 8).systems
        let edge = rows[0].end
        let notes = [TabEvent(time: edge.nextDown, lane: .left, string: 1),
                     TabEvent(time: edge.nextDown, lane: .left, string: 1),
                     TabEvent(time: edge, lane: .left, string: 1),
                     TabEvent(time: edge, lane: .right, string: 1),
                     TabEvent(time: edge, lane: .left, string: 2)]
        for row in rows {
            for lane in GuitarLane.allCases {
                let events = notes.filter { $0.time >= row.start && $0.time < row.end && $0.lane == lane }
                let layout = NotePointerLayout(events: events, compact: true, displayScale: 0.35, bounds: 50...650) {
                    CGPoint(x: 50 + row.fraction(at: $0.time) * 600, y: Double(38 + ($0.string - 1) * 14))
                }
                #expect(Set(layout.targets.flatMap { $0.events.map(\.id) }) == Set(events.map(\.id)))
                for target in layout.targets {
                    #expect(target.events.allSatisfy { $0.lane == lane && $0.string == target.events[0].string })
                    #expect(target.frame.minX >= 50 - 0.000001 && target.frame.maxX <= 650 + 0.000001)
                }
            }
        }
        let close = [TabEvent(time: 1, lane: .left, string: 1), TabEvent(time: 1.05, lane: .left, string: 1)]
        let zoomed = NotePointerLayout(events: close, compact: false, displayScale: 1, bounds: 48...648) {
            CGPoint(x: 48 + ($0.time - 0.9) / 0.2 * 600, y: 68)
        }
        #expect(zoomed.targets.count == 2 && zoomed.targets.allSatisfy { $0.events.count == 1 })
        let sparse = NotePointerLayout(events: close, compact: true, displayScale: 1, bounds: 50...650) {
            CGPoint(x: 100 + ($0.time - 1) * 600, y: 38)
        }
        #expect(sparse.targets.count == 2 && sparse.targets.allSatisfy { $0.events.count == 1 })
    }

    @Test(arguments: [0.35, 1.0], [false, true])
    func hostedScaledDragUsesStablePointerAndTrueOnsetMagnet(scale: Double, shift: Bool) throws {
        let first = TabEvent(time: 1.123456789, lane: .left, string: 3, memo: "exact")
        let next = TabEvent(time: first.time + 0.5, lane: .left, string: 3, fret: 7)
        let other = TabEvent(time: first.time + 0.3, lane: .right, string: 3)
        let workspace = workspace([first, next, other]); defer { workspace.shutdown() }
        workspace.measuresPerSystem = 8; workspace.select(first)
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: scale)
            .frame(width: 666, height: 123).scaleEffect(scale, anchor: .topLeading), height: 123)
        defer { host.close() }
        let control = try #require(host.controls().first)
        let down = try host.event(.leftMouseDown, control: control)
        let correct = host.view.hitTest(host.view.superview!.convert(down.locationInWindow, from: nil)) === control
        #expect(correct)
        func event(_ type: NSEvent.EventType, translation: Double) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: down.locationInWindow.x + translation * scale, y: down.locationInWindow.y),
                modifierFlags: shift ? [.shift] : [], timestamp: 101, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        }
        control.mouseDown(with: down)
        control.mouseDragged(with: try event(.leftMouseDragged, translation: 12))
        host.settle()
        control.mouseDragged(with: try event(.leftMouseDragged, translation: 15))
        host.settle()
        let expected = shift ? next.time : try #require(TimeBounds.scoreDragTime(first.time, system: row, translation: 15, width: 600))
        #expect(abs((workspace.positionDrag?.time ?? -1) - expected) < 0.000000001)
        control.mouseUp(with: try event(.leftMouseUp, translation: 15))
        #expect(abs((workspace.selected?.time ?? -1) - expected) < 0.000000001)
        #expect(workspace.selected?.id == first.id && workspace.selected?.string == first.string)
        #expect(workspace.project.events.first { $0.id == next.id } == next)
        #expect(workspace.project.events.first { $0.id == other.id } == other)
        workspace.undoEdit(); #expect(workspace.project.events == [first, next, other] && !workspace.canUndo)
    }

    @Test func hostedRowEdgesRightLaneAndZoomRemainPointerReachable() throws {
        let edge = 16.0
        let notes = [TabEvent(time: edge.nextDown, lane: .left, string: 3),
                     TabEvent(time: edge, lane: .left, string: 3),
                     TabEvent(time: edge, lane: .right, string: 3, memo: "R"),
                     TabEvent(time: edge + 0.05, lane: .left, string: 3)]
        let workspace = workspace(notes); defer { workspace.shutdown() }
        workspace.measuresPerSystem = 8
        let rows = workspace.scoreLayout.systems
        let before = workspace.project
        for (row, lane, expected) in [(rows[0], GuitarLane.left, notes[0]),
                                      (rows[1], GuitarLane.left, notes[1]),
                                      (rows[1], GuitarLane.right, notes[2])] {
            workspace.clearSelection()
            let host = Host(ScoreStaff(workspace: workspace, row: row, lane: lane, measured: false, displayScale: 0.35)
                .frame(width: 666, height: 123).scaleEffect(0.35, anchor: .topLeading), height: 123)
            defer { host.close() }
            try host.click(try #require(host.controls().first))
            #expect(workspace.selected == expected && workspace.lane == lane && workspace.project == before)
        }
        workspace.selectLane(.left); workspace.clearSelection()
        workspace.windowStart = edge - 0.05; workspace.windowLength = 0.2
        let zoom = Host(TabCanvas(workspace: workspace)); defer { zoom.close() }
        #expect(zoom.controls().count == 2)
        #expect(zoom.controls().filter { $0.chooserWidth == 0 }.count == 1)
        var reached = Set<UUID>()
        // The two edge events differ by one ULP and remain a collision even at zoom.
        for control in zoom.controls() {
            for _ in 0..<(control.chooserWidth > 0 ? 2 : 1) {
                try zoom.click(control); reached.insert(try #require(workspace.selectedID))
            }
        }
        #expect(reached == Set([notes[0].id, notes[1].id, notes[3].id]))
        #expect(workspace.project == before)
    }

    @Test func actualChooserButtonsSelectExactCoincidentIDsWithoutEditing() throws {
        let notes = [TabEvent(time: 1.123456789, lane: .right, string: 2, memo: "first"),
                     TabEvent(time: 1.123456789, lane: .right, string: 2, tentative: true, memo: "second"),
                     TabEvent(time: 1.173456789, lane: .right, string: 2, length: .quarter)]
        let workspace = workspace(notes); defer { workspace.shutdown() }
        var dismissed = 0
        let host = Host(NoteCollisionChooser(workspace: workspace, events: notes) { dismissed += 1 })
        defer { host.close() }
        let controls = host.controls()
        #expect(controls.count == notes.count)
        let before = workspace.project
        for (index, control) in controls.enumerated() {
            try host.click(control)
            #expect(workspace.selected == notes[index] && workspace.project == before)
        }
        #expect(dismissed == notes.count)
    }

}
