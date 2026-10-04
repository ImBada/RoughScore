import AppKit
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor
@Suite(.serialized)
struct BulkWorkspaceTests {
    private func workspace() -> Workspace {
        var services = WorkspaceServices.isolatedCache()
        services.rememberProject = { _ in }; services.lastProject = { nil }; services.chooseSaveDestination = { _ in nil }
        let workspace = Workspace(services: services)
        workspace.project = ScoreProject(duration: 16, events: [
            TabEvent(time: 1.125, lane: .left, string: 3, fret: 12, memo: "known"),
            TabEvent(time: 1.125, lane: .left, string: 3, tentative: true, memo: "unknown 한글"),
            TabEvent(time: 1.375, lane: .left, string: 4, fret: 0, length: .eighth, memo: "riff"),
            TabEvent(time: 1.125, lane: .right, string: 3, fret: 9, memo: "other lane")])
        workspace.windowStart = 0; workspace.windowLength = 16
        workspace.showScoreWaveforms = false
        return workspace
    }
    private func keyboard(_ workspace: Workspace) -> TabKeyboardView {
        let view = TabKeyboardView(); view.workspace = workspace
        view.pasteboard = NSPasteboard(name: .init("RoughScore-bulk-test-" + UUID().uuidString))
        return view
    }
    private func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], at: Double = 100) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: at,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
    }
    private func assertCopied(_ original: [TabEvent], _ pasted: [TabEvent], origin: Double, cursor: Double) {
        #expect(pasted.count == original.count)
        #expect(Set(pasted.map(\.id)).isDisjoint(with: Set(original.map(\.id))))
        for (source, copy) in zip(original, pasted) {
            var expected = source; expected.id = copy.id; expected.time = cursor + (source.time - origin)
            #expect(copy == expected)
        }
    }

    @Test(arguments: [false, true])
    func actualHostedSurfacesMultiSelectCursorClipboardDuplicateAndToolbar(score: Bool) throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = score ? NotePointerTests.Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: 1), height: 123)
                         : NotePointerTests.Host(TabCanvas(workspace: workspace))
        defer { host.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(before)
        // The dense ×2 chip adds each exact UUID while ordinary click still cycles.
        let coincident = try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("2개 음") })
        try host.click(coincident, flags: .command)
        try host.click(try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("2개 음") }), flags: .command)
        let riff = try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("4번 줄") })
        try host.click(riff, flags: .command)
        #expect(workspace.selectedIDs == Set(before.events.prefix(3).map(\.id)))
        #expect(workspace.project == before && !workspace.canUndo)
        #expect(try encoder.encode(workspace.project) == bytes)
        let selected = workspace.selectedID
        let range = try #require(host.descendants().compactMap { $0 as? TabRangeControl }.first)
        let x = score ? 50 + row.fraction(at: 4) * 600 : 48 + 4.0 / 16 * 588
        let point = range.convert(CGPoint(x: x, y: 90), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command, timestamp: 100,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        range.mouseDown(with: try mouse(.leftMouseDown)); range.mouseUp(with: try mouse(.leftMouseUp)); host.settle()
        #expect(abs(workspace.cursor - 4) < 1e-12 && workspace.selectedID == selected)
        #expect(workspace.selectedIDs.count == 3)
        let keys = keyboard(workspace); defer { keys.pasteboard.releaseGlobally() }
        keys.keyDown(with: try key("c", flags: .command))
        keys.keyDown(with: try key("v", flags: .command))
        assertCopied(Array(before.events.prefix(3)), Array(workspace.project.events.suffix(3)), origin: 1.125, cursor: 4)
        #expect(workspace.project.events[3] == before.events[3])
        #expect(workspace.selectedIDs == Set(workspace.project.events.suffix(3).map(\.id)))
        workspace.undoEdit(); host.settle(); #expect(workspace.project == before && !workspace.canUndo)
        #expect(workspace.selectedIDs == Set(before.events.prefix(3).map(\.id)))
        // The actual toolbar's native button calls the same transaction, without a clipboard round trip.
        let bar = NotePointerTests.Host(BulkSelectionBar(workspace: workspace), height: 60); defer { bar.close() }
        let duplicate = try #require(bar.descendants().compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "bulk-duplicate" })
        duplicate.performClick(nil); bar.settle()
        assertCopied(Array(before.events.prefix(3)), Array(workspace.project.events.suffix(3)), origin: 1.125, cursor: 4)
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        keys.keyDown(with: try key("d", flags: .command))
        #expect(workspace.project.events.count == 7); workspace.undoEdit(); host.settle()
        // Normal click collapses a group; fast ordinary two-digit entry still edits only the active UUID.
        try host.click(try #require(host.controls().first))
        #expect(workspace.selectedIDs.count == 1)
        let active = try #require(workspace.selectedID)
        keys.keyDown(with: try key("1", at: 101)); keys.keyDown(with: try key("2", at: 101.1))
        #expect(workspace.selected?.fret == 12 && workspace.selected?.id == active)
        #expect(workspace.project.events.filter { $0.id != active } == before.events.filter { $0.id != active })
    }

    @Test(arguments: [false, true])
    func actualHostedRangeRetainsLeadingSilenceAndBatchKeyboardUndo(score: Bool) throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = score ? NotePointerTests.Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: 1), height: 123)
                         : NotePointerTests.Host(TabCanvas(workspace: workspace))
        defer { host.close() }
        let control = try #require(host.descendants().compactMap { $0 as? TabRangeControl }.first)
        func event(_ type: NSEvent.EventType, time: Double) throws -> NSEvent {
            let x = score ? 50 + row.fraction(at: time) * 600 : 48 + time / 16 * 588
            let point = control.convert(CGPoint(x: x, y: 90), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command, timestamp: 100,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        control.mouseDown(with: try event(.leftMouseDown, time: 1))
        control.mouseUp(with: try event(.leftMouseUp, time: 1.5)); host.settle()
        #expect(workspace.selectedIDs == Set(before.events.prefix(3).map(\.id)))
        #expect(workspace.selectionRange?.start == 1)
        workspace.placeSelectionCursor(4)
        #expect(workspace.duplicateSelection())
        assertCopied(Array(before.events.prefix(3)), Array(workspace.project.events.suffix(3)), origin: 1, cursor: 4)
        workspace.undoEdit(); #expect(workspace.project == before)
        let keys = keyboard(workspace); defer { keys.pasteboard.releaseGlobally() }
        keys.keyDown(with: try key("", code: 124))
        for (old, moved) in zip(before.events.prefix(3), workspace.project.events.prefix(3)) {
            #expect(moved.time == old.time + 0.05 && moved.id == old.id)
        }
        #expect(workspace.project.events[3] == before.events[3])
        keys.keyDown(with: try key("z", flags: .command)); #expect(workspace.project == before && !workspace.canUndo)
        keys.keyDown(with: try key("", code: 51)); #expect(workspace.project.events == [before.events[3]])
        #expect(workspace.selectedIDs.isEmpty && workspace.selectedID == nil)
        keys.keyDown(with: try key("z", flags: .command))
        #expect(workspace.project == before && workspace.selectedIDs.count == 3 && !workspace.canUndo)
    }

    @Test func rangeLengthTentativeTransferAndBoundsAreWholeHistoryTransactions() throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        #expect(workspace.selectRange(lane: .left, from: 1, to: 2))
        for length: NoteLength? in [.quarter, nil] {
            // Give clear an actual authored length to remove.
            if length == nil { #expect(workspace.setSelectionLength(.quarter)) }
            let baseline = workspace.project
            #expect(workspace.setSelectionLength(length))
            #expect(workspace.project.events.prefix(3).allSatisfy { $0.length == length })
            #expect(workspace.project.events[3] == before.events[3])
            workspace.undoEdit(); #expect(workspace.project == baseline)
            if length == nil { workspace.undoEdit() }
        }
        #expect(workspace.project == before && !workspace.canUndo)
        #expect(workspace.setSelectionTentative(true)); workspace.undoEdit()
        #expect(workspace.project == before && !workspace.canUndo)
        #expect(workspace.offsetSelection(time: 0, targetLane: .right))
        #expect(workspace.project.events.prefix(3).allSatisfy { $0.lane == .right })
        #expect(workspace.project.events.map(\.id) == before.events.map(\.id))
        workspace.undoEdit(); #expect(workspace.project == before)
        // An error preserves both undo and redo, every UUID, and selection.
        let selected = workspace.selectedIDs
        #expect(workspace.canRedo)
        #expect(!workspace.offsetSelection(time: -2))
        #expect(!workspace.offsetSelection(time: 15))
        #expect(!workspace.offsetSelection(time: 0, strings: -4))
        workspace.placeSelectionCursor(15.9)
        #expect(!workspace.duplicateSelection(targetLane: .right))
        #expect(workspace.project == before && !workspace.canUndo && workspace.canRedo && workspace.selectedIDs == selected)
        workspace.redoEdit(); #expect(workspace.project.events.prefix(3).allSatisfy { $0.lane == .right })
        workspace.undoEdit(); workspace.placeSelectionCursor(4)
        #expect(workspace.duplicateSelection(targetLane: .right))
        #expect(workspace.project.events.suffix(3).allSatisfy { $0.lane == .right })
        #expect(Array(workspace.project.events.prefix(4)) == before.events)
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
    }

    @Test(arguments: [false, true])
    func groupDragCommandSelectionAndFirstEscapeRemainExclusive(score: Bool) throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        #expect(workspace.selectRange(lane: .left, from: 1, to: 2))
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = score ? NotePointerTests.Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: 1), height: 123)
                         : NotePointerTests.Host(TabCanvas(workspace: workspace))
        defer { host.close() }
        let control = try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("4번 줄") })
        let down = try host.event(.leftMouseDown, control: control)
        func drag(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: down.locationInWindow.x, y: down.locationInWindow.y - (score ? 14 : 32)),
                modifierFlags: flags, timestamp: 101, windowNumber: host.window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        }
        control.mouseDown(with: down); control.mouseDragged(with: try drag(.leftMouseDragged))
        #expect(workspace.positionDrag != nil && workspace.project == before)
        workspace.toggleSelection(before.events[3]); workspace.selectRange(lane: .right, from: 0, to: 2)
        workspace.deleteSelected(); workspace.duplicateSelection(); workspace.setSelectionLength(.half)
        #expect(workspace.project == before && workspace.selectedIDs.count == 3 && !workspace.canUndo)
        workspace.clearSelection(); #expect(workspace.positionDrag == nil && workspace.selectedIDs.count == 3)
        let fragment = try workspace.selectedFragment()
        let primary = try #require(fragment.primaryIndex)
        #expect(fragment.events[primary].memo == workspace.selected?.memo)
        control.mouseUp(with: try drag(.leftMouseUp)); #expect(workspace.project == before && !workspace.canUndo)
        workspace.clearSelection(); #expect(workspace.selectedIDs.isEmpty)
        #expect(workspace.selectRange(lane: .left, from: 1, to: 2)); host.settle()
        let again = try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("4번 줄") })
        again.mouseDown(with: try host.event(.leftMouseDown, control: again))
        again.mouseDragged(with: try drag(.leftMouseDragged)); again.mouseUp(with: try drag(.leftMouseUp))
        for (old, moved) in zip(before.events.prefix(3), workspace.project.events.prefix(3)) {
            var expected = old; expected.string += 1; #expect(moved == expected)
        }
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        // Holding Command while moving a note is selection, never a hidden drag mutation.
        let adding = try #require(host.controls().first)
        adding.mouseDown(with: try host.event(.leftMouseDown, control: adding, flags: .command))
        adding.mouseDragged(with: try host.event(.leftMouseDragged, control: adding, delta: CGSize(width: 30, height: 30), flags: [.command, .shift]))
        adding.mouseUp(with: try host.event(.leftMouseUp, control: adding, flags: .command))
        #expect(workspace.positionDrag == nil && workspace.project == before && !workspace.canUndo)
    }

    @Test func actualWorkspaceControlsApplyLengthTentativeAndExplicitLaneTransfers() throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        #expect(workspace.selectRange(lane: .left, from: 1, to: 2))
        workspace.placeSelectionCursor(4)
        let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1200)
        defer { host.close() }
        #expect(host.descendants().contains { $0 is TabKeyboardView })
        func invoke(_ identifier: String, title: String) throws {
            host.settle()
            let button = try #require(host.descendants().compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == identifier })
            let item = try #require(button.menu?.items.first { $0.title == title })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        try invoke("bulk-length", title: NoteLength.quarter.title)
        #expect(workspace.project.events.prefix(3).allSatisfy { $0.length == .quarter })
        #expect(workspace.project.events[3] == before.events[3])
        try invoke("bulk-length", title: "미지정으로 지우기")
        #expect(workspace.project.events.prefix(3).allSatisfy { $0.length == nil })
        workspace.undoEdit(); #expect(workspace.project.events.prefix(3).allSatisfy { $0.length == .quarter })
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        try invoke("bulk-tentative", title: "잠정으로 표시")
        #expect(workspace.project.events.prefix(3).allSatisfy { $0.tentative })
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        try invoke("bulk-lanes", title: "\(GuitarLane.right.title)로 커서에 복사")
        #expect(workspace.project.events.suffix(3).allSatisfy { $0.lane == .right })
        #expect(workspace.project.events.count == 7 && Array(workspace.project.events.prefix(4)) == before.events)
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        try invoke("bulk-lanes", title: "\(GuitarLane.right.title)로 이동 · 시간 유지")
        #expect(workspace.project.events.prefix(3).allSatisfy { $0.lane == .right })
        #expect(workspace.project.events.map(\.id) == before.events.map(\.id))
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        host.settle()
        let note = try #require(host.controls().first)
        let toggle = try #require(note.accessibilityCustomActions()?.first { $0.name == "선택 추가 또는 해제" })
        let originalCount = workspace.selectedIDs.count
        let handler = try #require(toggle.handler)
        #expect(handler())
        #expect(workspace.selectedIDs.count == originalCount - 1 && workspace.project == before && !workspace.canUndo)
    }

    @Test func pruningSerializationAutosaveOpenAndToolbarDelete() async throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-bulk-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bulk.roughscore")
        #expect(workspace.save(to: url)); let before = workspace.project
        #expect(workspace.selectRange(lane: .left, from: 1, to: 2))
        #expect(!workspace.dirty && !workspace.canUndo)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) == before)
        let host = NotePointerTests.Host(BulkSelectionBar(workspace: workspace), height: 60); defer { host.close() }
        let button = try #require(host.descendants().compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "bulk-delete" })
        button.performClick(nil); host.settle()
        #expect(workspace.project.events == [before.events[3]] && workspace.selectedIDs.isEmpty)
        workspace.undoEdit(); #expect(workspace.project == before && workspace.selectedIDs.count == 3)
        #expect(workspace.offsetSelection(time: 1))
        await workspace.awaitAutosave()
        #expect(!workspace.dirty)
        let saved = try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url))
        #expect(saved == workspace.project)
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == saved && workspace.selectedID == nil && workspace.selectedIDs.isEmpty)
        #expect(!workspace.canUndo && !workspace.canRedo)
    }
}
