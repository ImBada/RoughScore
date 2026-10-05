import AppKit
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor private final class AccessibilityTextTarget { var value: NativeTextUndoTarget? }

@MainActor
@Suite(.serialized)
struct EditorAccessibilityTests {
    private func workspace(_ target: AccessibilityTextTarget? = nil) -> Workspace {
        var services = WorkspaceServices.isolatedCache()
        services.rememberProject = { _ in }; services.lastProject = { nil }; services.chooseSaveDestination = { _ in nil }; services.nativeTextUndo = { target?.value }
        let workspace = Workspace(services: services)
        workspace.project = ScoreProject(duration: 32, events: [
            TabEvent(time: 1.12345678901234, lane: .left, string: 3, tentative: true, memo: "한글 unknown"),
            TabEvent(time: 4, lane: .left, string: 4, fret: 12, length: .eighth, memo: "selected group"),
            TabEvent(time: 1.12345678901234, lane: .right, string: 3, fret: 9, length: .quarter, memo: "sentinel")])
        workspace.windowStart = 0; workspace.windowLength = 16; workspace.showScoreWaveforms = false
        return workspace
    }
    private func action(_ view: NSView, _ name: String) throws -> NSAccessibilityCustomAction {
        try #require(view.accessibilityCustomActions()?.first { $0.name == name })
    }
    private func invoke(_ action: NSAccessibilityCustomAction) -> Bool { action.handler?() ?? false }
    private func send(_ host: NotePointerTests.Host, _ text: String = "", code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 100, windowNumber: host.window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        if !event.modifierFlags.contains(.command) || !host.window.performKeyEquivalent(with: event) { host.window.sendEvent(event) }; host.settle()
    }

    @Test(arguments: [false, true])
    func hostedNoteAXSemanticsScopedActionsAndHistory(score: Bool) throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        workspace.select(before.events[1]); workspace.toggleSelection(before.events[2])
        let selection = workspace.selectedIDs, primary = workspace.selectedID
        let inputString = workspace.activeString, cursor = workspace.cursor
        var focus = 0; workspace.requestKeyboardFocus = { focus += 1 }
        let row = try #require(workspace.scoreLayout.systems.first)
        let host = score ? NotePointerTests.Host(ScoreStaff(workspace: workspace, row: row, lane: .left, measured: false, displayScale: 1), height: 123)
                         : NotePointerTests.Host(TabCanvas(workspace: workspace))
        // Timeline is the active lane; deliberately render L while keeping the unrelated selection.
        workspace.lane = .left; host.settle()
        defer { host.close() }
        let control = try #require(host.controls().first { $0.accessibilityIdentifier() == "note-" + before.events[0].id.uuidString })
        let label = try #require(control.accessibilityLabel())
        for text in [before.events[0].lane.title, String(before.events[0].time), "3번 줄", "음 미확인", "길이 미지정", "잠정", "선택 안 됨"] { #expect(label.contains(text)) }
        #expect((control.accessibilityValue() as? String)?.contains("한글 unknown") == true)
        #expect(control.accessibilityRole() == .button && !control.isAccessibilitySelected() && control.isAccessibilityEnabled())
        #expect(control.accessibilityCustomActions()?.contains { $0.name == "겹친 음 목록" } == false)
        let nudge = try action(control, "이 음 10ms 뒤쪽")
        #expect(invoke(nudge)); host.settle()
        var expected = before; expected.events[0].time += 0.01
        #expect(workspace.project == expected && workspace.canUndo && focus == 0)
        #expect(workspace.selectedIDs == selection && workspace.selectedID == primary)
        #expect(workspace.activeString == inputString && workspace.cursor == cursor)
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        workspace.redoEdit(); #expect(workspace.project == expected); workspace.undoEdit()
        host.settle()
        let move = try action(control, "이 음 아래 줄로")
        #expect(invoke(move)); expected = before; expected.events[0].string += 1
        #expect(workspace.project == expected && workspace.project.events[0].time == before.events[0].time)
        workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
        // Lock/no-op/stale actions preserve exact project and history, including a retained closure.
        workspace.beginPositionDrag(before.events[0]); focus = 0
        #expect(!control.isAccessibilityEnabled() && !invoke(nudge)); #expect(workspace.project == before)
        workspace.cancelPositionDrag(); workspace.undoEdit(); host.settle()
        #expect(!workspace.moveAccessibleNote(id: before.events[0].id, editorID: UUID(), timeDelta: 0.01))
        #expect(!workspace.moveAccessibleNote(id: before.events[0].id, editorID: workspace.editorIdentity))
        #expect(!workspace.moveAccessibleNote(id: before.events[0].id, editorID: workspace.editorIdentity, timeDelta: -2))
        #expect(!workspace.moveAccessibleNote(id: before.events[0].id, editorID: workspace.editorIdentity, stringDelta: -3))
        workspace.beginExport(.pdf); #expect(!invoke(nudge)); workspace.cancelExport()
        #expect(workspace.project == before && !workspace.canUndo)
        workspace.shutdown(); #expect(!invoke(nudge) && !control.accessibilityPerformPress())
    }

    @Test func nativeWindowEscapeTraversalReentryAndExactCursorRoundTrip() throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1440); defer { host.close() }
        let bridge = try #require(host.descendants().compactMap { $0 as? TabKeyboardView }.first)
        let controls = try #require(host.descendants().compactMap { $0 as? EditorNavigationView }.first)
        let original = workspace.project
        workspace.seekForEditing(original.events[0].time); host.settle()
        #expect(host.window.firstResponder === bridge && workspace.tabInputFocused)
        try send(host, "\t", code: 48, flags: .control)
        let editor = try #require(host.window.firstResponder as? NSTextView)
        #expect(controls.cursorField.currentEditor() === editor && !workspace.tabInputFocused)
        let exact = workspace.cursor
        try send(host, "\t", code: 48)
        #expect(host.window.firstResponder === controls.input)
        #expect(workspace.cursor == exact && workspace.project == original && !workspace.canUndo)
        try send(host, "\t", code: 48)
        #expect(host.window.firstResponder === controls.notes)
        try send(host, "\t", code: 48, flags: .shift)
        #expect(host.window.firstResponder === controls.input)
        try send(host, "\r", code: 36)
        #expect(host.window.firstResponder === bridge && workspace.tabInputFocused)
        try send(host, "\t", code: 48, flags: [.control, .shift])
        #expect(host.window.firstResponder === controls.tuning)
        try send(host, "\t", code: 48)
        #expect(controls.cursorField.currentEditor() === host.window.firstResponder)
        // Explicit Command-Return field leave; field contents are unchanged, exact seconds stay intact.
        try send(host, "\r", code: 36, flags: .command)
        #expect(host.window.firstResponder === bridge)
        #expect(workspace.cursor == exact && workspace.project == original && !workspace.canUndo && !workspace.dirty)
        // VO control-option and all Command+Option chords never create/edit a note.
        try send(host, "5", code: 23, flags: [.control, .option])
        try send(host, "5", code: 23, flags: [.command, .option])
        #expect(host.window.firstResponder === bridge && workspace.project == original)
        try send(host, "?", code: 44, flags: .shift)
        try send(host, "", code: 124)
        try send(host, "1", code: 18); try send(host, "2", code: 19)
        #expect(workspace.project.events.count == original.events.count + 2)
        #expect(workspace.project.events.suffix(2).map(\.fret) == [nil, 12])
        #expect(workspace.project.events.suffix(2).allSatisfy { $0.length == nil })
    }

    @Test func nativeCursorFieldTypingIMEClipboardCaretAndNoteUndoBoundary() throws {
        let target = AccessibilityTextTarget()
        let workspace = workspace(target); defer { workspace.shutdown() }
        let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1440); defer { host.close() }
        let controls = try #require(host.descendants().compactMap { $0 as? EditorNavigationView }.first)
        workspace.select(workspace.project.events[1]); workspace.inputDigit(7, at: 100)
        let before = workspace.project
        #expect(workspace.requestControlFocus?(false) == true)
        let editor = try #require(host.window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        workspace.status = "unrelated"; host.settle()
        #expect(editor.selectedRange() == NSRange(location: 1, length: 2))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let marked = editor.markedRange(); workspace.tabInputFocused = false; host.settle()
        #expect(editor.hasMarkedText() && editor.markedRange() == marked)
        editor.unmarkText()
        // Named pasteboard, native editor read/write, no general clipboard/user data.
        let pasteboard = NSPasteboard(name: .init("RoughScore-issue17-native-" + UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        pasteboard.declareTypes(editor.writablePasteboardTypes, owner: nil)
        #expect(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
        let manager = try #require(editor.undoManager)
        manager.groupsByEvent = false; manager.removeAllActions()
        target.value = NativeTextUndoTarget(manager, editor: editor)
        manager.beginUndoGrouping()
        editor.insertText("3.23456789012345", replacementRange: editor.selectedRange())
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        workspace.performUndo(); #expect(workspace.project == before && manager.canRedo)
        workspace.performRedo(); #expect(editor.string == "3.23456789012345")
        manager.removeAllActions(); workspace.performUndo()
        #expect(workspace.project == before && workspace.canUndo) // Native boundary consumes undo.
        #expect(workspace.project == before && workspace.canUndo)
        // Submit native field: clear selection intentionally; no note undo, no focus theft.
        controls.cursorField.stringValue = "3.23456789012345"
        try send(host, "\r", code: 36)
        #expect(workspace.cursor == 3.23456789012345 && workspace.selectedID == nil)
        #expect(host.window.firstResponder === editor && workspace.project == before)
    }

    @Test func hostedListChooserAndMapWaveformAX() async throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        let list = NotePointerTests.Host(AccessibleNoteList(workspace: workspace, events: before.events, dismiss: {}), height: 240, width: 660); defer { list.close() }
        // Let AppKit's deferred initial-focus callback run, as it does between UI events.
        try await Task.sleep(for: .milliseconds(20)); list.settle()
        let rows = list.descendants().compactMap { $0 as? AccessibleNoteRow }
        #expect(rows.count == 3)
        for (event, row) in zip(before.events, rows) {
            #expect(row.frame.height == 48 && row.frame.width >= 600)
            #expect(row.accessibilityIdentifier() == "note-" + event.id.uuidString)
            #expect(row.accessibilityLabel() == NoteAccessibility.label(event, workspace: workspace))
            #expect(row.isAccessibilityEnabled() && !row.isAccessibilitySelected())
        }
        #expect(list.window.firstResponder === rows[0])
        try send(list, "\t", code: 48); #expect(list.window.firstResponder === rows[1])
        try send(list, "\t", code: 48, flags: .shift); #expect(list.window.firstResponder === rows[0])
        #expect(invoke(try action(rows[0], "이 음 50ms 뒤쪽")))
        #expect(list.window.firstResponder === rows[0]); workspace.undoEdit(); #expect(workspace.project == before)
        let chooser = NotePointerTests.Host(NoteCollisionChooser(workspace: workspace, events: Array(before.events.prefix(2)), dismiss: {})); defer { chooser.close() }
        #expect(chooser.controls().count == 2)
        #expect(chooser.controls().allSatisfy { $0.accessibilityCustomActions()?.contains { $0.name == "겹친 음 목록" } == false })
        #expect(chooser.controls()[0].accessibilityLabel()?.contains("길이 미지정") == true)
        #expect(chooser.window.makeFirstResponder(chooser.controls()[0]))
        try send(chooser, "\t", code: 48)
        #expect(chooser.window.firstResponder === chooser.controls()[1])
        try send(chooser, "\t", code: 48, flags: .shift)
        #expect(chooser.window.firstResponder === chooser.controls()[0])
        #expect(rows[1].accessibilityPerformPress()); list.settle()
        #expect(workspace.project == before && !workspace.canUndo)
        #expect(rows[1].isAccessibilitySelected() && rows[1].accessibilityLabel()?.contains("주 선택") == true)
        workspace.clearSelection()
        for score in [true, false] {
            workspace.scoreView = score
            let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1440); defer { host.close() }
            let cursor = try #require(host.descendants().compactMap { $0 as? EditingCursorAXView }.first)
            #expect(cursor.accessibilityRole() == .slider && cursor.isAccessibilityEnabled())
            workspace.select(before.events[0]); host.settle(); let time = workspace.cursor
            #expect(cursor.accessibilityPerformIncrement())
            #expect(workspace.cursor == time + 0.05 && workspace.selectedID == nil && workspace.project == before && !workspace.canUndo)
            #expect(cursor.accessibilityPerformDecrement()); #expect(workspace.project == before)
        }
    }

    @Test func tuningNativeKeyViewsAreReachableFromFocusedDraft() async throws {
        let workspace = workspace(); defer { workspace.shutdown() }
        let before = workspace.project
        let host = NotePointerTests.Host(TuningEditor(workspace: workspace), height: 600, width: 420); defer { host.close() }
        try await Task.sleep(for: .milliseconds(20)); host.settle()
        let fields = host.descendants().compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let pitchFields = fields.filter { $0.placeholderString == "open MIDI" }
        #expect(pitchFields.count == 6)
        let first = try #require(pitchFields.first)
        #expect(first.currentEditor() === host.window.firstResponder && first.stringValue == "64")
        #expect(first.accessibilityLabel() == "1번 줄 open MIDI")
        let editor = try #require(first.currentEditor() as? NSTextView)
        let original = editor.string
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        let marked = editor.markedRange(); let caret = editor.selectedRange()
        workspace.status = "draft unrelated"; host.settle()
        #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == caret)
        editor.unmarkText(); editor.insertText(original, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); host.settle()
        var seen = Set<String>()
        for _ in 0..<14 {
            if let editor = host.window.firstResponder as? NSTextView {
                if let index = pitchFields.firstIndex(where: { $0.currentEditor() === editor }) { seen.insert("tuning-open-\(index + 1)") }
                else if fields.contains(where: { $0.placeholderString == "0–24" && $0.currentEditor() === editor }) { seen.insert("tuning-capo") }
            } else if let button = host.window.firstResponder as? NSButton { seen.insert(button.identifier?.rawValue ?? "") }
            try send(host, "\t", code: 48)
        }
        #expect((1...6).allSatisfy { seen.contains("tuning-open-\($0)") })
        #expect(seen.contains("tuning-capo") && seen.contains("tuning-apply") && seen.contains("tuning-cancel"))
        #expect(workspace.project == before && !workspace.canUndo && !workspace.dirty)
    }

    @Test func activationRejectsRetainedNoteAndFocusCallbacksWithSameUUID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-issue17-activation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("generated.caf")
        try StreamingCacheFixture.write(audio, seconds: 2, channels: 2)
        let workspace = workspace(); defer { workspace.shutdown() }
        let old = workspace.project.events[0]
        let host = NotePointerTests.Host(WorkspaceView(workspace: workspace), height: 900, width: 1440); defer { host.close() }
        let action = try #require(NoteAccessibility.actions(old.id, workspace: workspace).first { $0.0 == "이 음 10ms 뒤쪽" }?.1)
        let oldInputFocus = try #require(workspace.requestKeyboardFocus)
        let oldControlFocus = try #require(workspace.requestControlFocus)
        let identity = workspace.editorIdentity
        #expect(await workspace.loadAudio(at: audio)?.value == true)
        workspace.project.events = [old]; host.settle()
        #expect(workspace.editorIdentity != identity)
        let current = try #require(host.descendants().compactMap { $0 as? EditorNavigationView }.first)
        #expect(workspace.requestControlFocus?(false) == true)
        let responder = host.window.firstResponder
        let dirty = workspace.dirty // A newly imported, unsaved document is already dirty.
        #expect(!action() && !oldControlFocus(false))
        oldInputFocus(); #expect(host.window.firstResponder === responder)
        #expect(workspace.project.events == [old] && !workspace.canUndo && workspace.dirty == dirty)
        #expect(current.cursorField.currentEditor() === responder)
        workspace.requestKeyboardFocus?()
        #expect(host.window.firstResponder is TabKeyboardView)
    }

    @Test func nativeOverlappingDisplacedHitsChooseClosestRegardlessOfSubviewOrder() throws {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = NSWindow(contentRect: root.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.contentView = nil; window.close() }
        let group = UUID()
        let a = NotePointerControl(frame: NSRect(x: 20, y: 20, width: 40, height: 30))
        let b = NotePointerControl(frame: NSRect(x: 40, y: 20, width: 40, height: 30))
        a.hitGroup = group; b.hitGroup = group
        a.setAccessibilityIdentifier("note-a"); b.setAccessibilityIdentifier("note-b")
        root.addSubview(a); root.addSubview(b)
        #expect(root.hitTest(NSPoint(x: 45, y: 35)) === a)
        #expect(root.hitTest(NSPoint(x: 55, y: 35)) === b)
        #expect(root.hitTest(NSPoint(x: 50, y: 35)) === a)
        a.removeFromSuperview(); root.addSubview(a)
        #expect(root.hitTest(NSPoint(x: 55, y: 35)) === b)
        #expect(root.hitTest(NSPoint(x: 50, y: 35)) === a)
    }

    @Test(arguments: [0.35, 1.0])
    func adjacentStringsDenseGroupsAndRowBoundaryGeometry(scale: Double) throws {
        let row = try #require(ScoreLayout(duration: 32).systems.first)
        let notes = (1...6).flatMap { string in [TabEvent(time: 0, lane: .left, string: string),
            TabEvent(time: 0.0001, lane: .left, string: string), TabEvent(time: row.end.nextDown, lane: .left, string: string)] }
        let layout = NotePointerLayout(events: notes, compact: true, displayScale: scale, bounds: 50...650) {
            CGPoint(x: 50 + row.fraction(at: $0.time) * 600, y: Double(38 + ($0.string - 1) * 14))
        }
        for target in layout.targets {
            #expect(layout.hit(at: target.center)?.id == target.id)
            #expect(target.frame.minX >= 50 && target.frame.maxX <= 650)
            #expect(target.height == 14) // Honest physical constraint; 48pt list supplies safe selection.
        }
        #expect(layout.targets.flatMap(\.events).count == notes.count)
        let next = TabEvent(time: row.end, lane: .left, string: 3)
        #expect(!notes.contains(next))
    }
}
