import AppKit
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor
private final class TextTargetBox { var target: NativeTextUndoTarget? }

@MainActor
@Suite(.serialized)
struct FieldUndoTests {
    private func services(_ box: TextTargetBox = TextTargetBox()) -> WorkspaceServices {
        var value = WorkspaceServices.isolatedCache()
        value.rememberProject = { _ in }; value.lastProject = { nil }; value.chooseSaveDestination = { _ in nil }
        value.nativeTextUndo = { box.target }
        return value
    }

    /// Hosts the actual inspector/representable in a hidden window. Native command
    /// routing is injected separately: this fixture cannot establish NSApp.keyWindow.
    @MainActor private final class HostedInspector {
        let host: NSHostingView<NoteInspector>
        let window: NSWindow
        let editor: MemoTextView

        init(_ workspace: Workspace) throws {
            _ = NSApplication.shared
            host = NSHostingView(rootView: NoteInspector(workspace: workspace))
            host.frame = NSRect(x: 0, y: 0, width: 290, height: 900)
            window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            Self.settle(host)
            editor = try #require(Self.descendants(host).compactMap { $0 as? MemoTextView }.first)
            editor.history.groupsByEvent = false
        }

        private static func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }

        private static func settle(_ view: NSView) {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            view.layoutSubtreeIfNeeded()
        }

        func settle() { Self.settle(host) }
        func currentEditor() throws -> MemoTextView {
            try #require(Self.descendants(host).compactMap { $0 as? MemoTextView }.first)
        }
        func close() { window.contentView = nil; window.close() }
        func insert(_ text: String) {
            editor.history.beginUndoGrouping()
            editor.insertText(text, replacementRange: editor.selectedRange())
            editor.history.endUndoGrouping()
        }
    }

    @Test func hostedMemoSameIDRestorationInvalidatesOnlyObsoleteNativeHistory() throws {
        let box = TextTargetBox()
        let workspace = Workspace(services: services(box)); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(2.123456789, lane: .right); workspace.inputDigit(7, at: 100)
        let original = try #require(workspace.selected)
        let inspector = try HostedInspector(workspace); defer { inspector.close() }
        let editor = inspector.editor
        #expect(inspector.window.makeFirstResponder(editor))
        box.target = NativeTextUndoTarget(editor.history, editor: editor)
        var focusRequests = 0
        workspace.requestKeyboardFocus = { focusRequests += 1 }

        inspector.insert("abcdef"); inspector.settle()
        #expect(workspace.selected?.memo == "abcdef" && editor.history.canUndo)
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        workspace.status = "Unrelated observable update"
        inspector.settle()
        #expect(editor.selectedRange() == NSRange(location: 2, length: 2) && editor.history.canUndo)
        #expect(inspector.window.firstResponder === editor && focusRequests == 0)

        workspace.performUndo(); inspector.settle()
        #expect(editor.string.isEmpty && workspace.selected?.memo == "")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(!workspace.canPerformUndo && workspace.canUndo && editor.history.canRedo)
        let nativeBoundary = workspace.project
        workspace.performUndo(); inspector.settle()
        #expect(workspace.project == nativeBoundary)
        workspace.performRedo(); inspector.settle()
        #expect(editor.string == "abcdef" && workspace.selected?.memo == "abcdef" && editor.history.canUndo)
        #expect(inspector.window.firstResponder === editor && focusRequests == 0)

        // Same-value publications retain both an undo and a redo stack.
        inspector.insert("g"); inspector.settle()
        workspace.performUndo(); inspector.settle()
        #expect(editor.string == "abcdef" && editor.history.canUndo && editor.history.canRedo)
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        workspace.setMemo("abcdef", eventID: original.id); inspector.settle()
        #expect(editor.history.canUndo && editor.history.canRedo)
        #expect(editor.selectedRange() == NSRange(location: 3, length: 2))

        workspace.setMemo("abc", eventID: original.id); inspector.settle()
        #expect(editor.string == "abc" && workspace.selected?.memo == "abc")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
        #expect(!editor.history.canUndo && !editor.history.canRedo)
        #expect(inspector.window.firstResponder === editor && focusRequests == 0)
        #expect(workspace.selected?.id == original.id && workspace.selected?.time == original.time)
        #expect(workspace.selected?.lane == .right && workspace.selected?.length == nil)

        // An exhausted native target still consumes the command after restoration.
        let restored = workspace.project
        workspace.performUndo(); workspace.performRedo(); inspector.settle()
        #expect(workspace.project == restored && editor.string == "abc" && focusRequests == 0)
        box.target = nil
        #expect(inspector.window.makeFirstResponder(nil))
        workspace.undoEdit(); inspector.settle()
        #expect(editor.string.isEmpty && workspace.selected?.memo == "")
        workspace.redoEdit(); inspector.settle()
        #expect(editor.string == "abc" && workspace.selected?.memo == "abc")
        #expect(!editor.history.canUndo && !editor.history.canRedo)

        workspace.seekForEditing(3); workspace.inputDigit(2, at: 101); inspector.settle()
        let secondID = try #require(workspace.selectedID)
        #expect(secondID != original.id && editor.string.isEmpty && !editor.history.canUndo)
        #expect(inspector.window.makeFirstResponder(editor))
        inspector.insert("second"); inspector.settle()
        #expect(workspace.selected?.id == secondID && workspace.selected?.memo == "second")
        #expect(workspace.project.events.first { $0.id == original.id }?.memo == "abc")
    }

    @Test func hostedMemo101AutosaveExitTabUndoRedoAndReopenDisplayAgree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-hosted-field-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memo.roughscore")
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        #expect(workspace.save(to: url))
        workspace.seekForEditing(2.123456789, lane: .right); workspace.inputDigit(7, at: 100)
        let original = try #require(workspace.selected)
        let inspector = try HostedInspector(workspace); defer { inspector.close() }
        let editor = inspector.editor
        #expect(inspector.window.makeFirstResponder(editor))
        for _ in 1...50 { inspector.insert("가") }
        await workspace.awaitAutosave(); inspector.settle()
        #expect(!workspace.dirty && editor.string.count == 50 && editor.history.canUndo)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) == workspace.project)
        for _ in 51...101 { inspector.insert("가") }
        inspector.settle()
        #expect(workspace.selected?.memo.count == 101 && editor.string.count == 101 && editor.history.canUndo)
        #expect(inspector.window.makeFirstResponder(nil))
        workspace.undoEdit(); inspector.settle()
        #expect(workspace.selected?.memo == "" && workspace.project.events.count == 1)
        #expect(editor.string.isEmpty && !editor.history.canUndo && !editor.history.canRedo)
        workspace.undoEdit(); inspector.settle()
        #expect(workspace.project.events.isEmpty && !workspace.canUndo)
        workspace.redoEdit(); inspector.settle()
        workspace.redoEdit(); inspector.settle()
        let restoredEditor = try inspector.currentEditor()
        #expect(restoredEditor.string.count == 101 && workspace.selected?.memo == restoredEditor.string)
        #expect(workspace.selected?.id == original.id && workspace.selected?.time == original.time)
        #expect(workspace.selected?.lane == .right && workspace.selected?.length == nil)
        await workspace.awaitAutosave()
        let saved = workspace.project
        #expect(!workspace.dirty)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) == saved)
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == saved)
        workspace.select(try #require(workspace.project.events.first { $0.id == original.id }))
        inspector.settle()
        #expect(try inspector.currentEditor().string == workspace.selected?.memo)
    }

    @Test func hostedMemoMarkedTextSurvivesUnrelatedUpdatesAndCommitKeepsCaret() throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.inputDigit(7, at: 100)
        let inspector = try HostedInspector(workspace); defer { inspector.close() }
        let editor = inspector.editor
        #expect(inspector.window.makeFirstResponder(editor))
        // Start composition before the queued SwiftUI update for the insertion.
        inspector.insert("prefix")
        editor.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        let markedRange = editor.markedRange()
        #expect(editor.hasMarkedText())
        workspace.status = "Composition must survive an unrelated publication"
        inspector.settle()
        #expect(editor.hasMarkedText() && editor.markedRange() == markedRange)
        #expect(editor.string == "prefix가" && editor.selectedRange() == selection)
        #expect(inspector.window.firstResponder === editor && editor.history.canUndo)
        editor.history.beginUndoGrouping()
        editor.insertText("각", replacementRange: editor.markedRange())
        editor.history.endUndoGrouping()
        inspector.settle()
        #expect(!editor.hasMarkedText() && editor.string == "prefix각")
        #expect(workspace.selected?.memo == editor.string && editor.selectedRange().location == 7)
        #expect(editor.history.canUndo && inspector.window.firstResponder === editor)

        // An authoritative same-ID replacement also ends obsolete marked text safely.
        editor.setMarkedText("나", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let id = try #require(workspace.selectedID)
        workspace.setMemo("restored", eventID: id); inspector.settle()
        #expect(editor.string == "restored")
        #expect(workspace.selected?.memo == "restored" && !editor.hasMarkedText())
        #expect(!editor.history.canUndo && !editor.history.canRedo && inspector.window.firstResponder === editor)
    }

    @Test func hundredAndOneCharactersCoalesceAcrossAutosaveAndUndoCreationNext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-field-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memo.roughscore")
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        #expect(workspace.save(to: url))
        workspace.seekForEditing(2); workspace.inputDigit(7, at: 100)
        let id = try #require(workspace.selectedID)
        workspace.beginMemoEditing(eventID: id)
        for count in 1...50 { workspace.setMemo(String(repeating: "가", count: count), eventID: id) }
        await workspace.awaitAutosave() // Autosave must not split a focused field session.
        #expect(!workspace.dirty)
        for count in 51...101 { workspace.setMemo(String(repeating: "가", count: count), eventID: id) }
        workspace.endMemoEditing(eventID: id)
        #expect(workspace.selected?.memo.count == 101)
        workspace.undoEdit(); #expect(workspace.selected?.memo == "" && workspace.project.events.count == 1)
        workspace.undoEdit(); #expect(workspace.project.events.isEmpty && !workspace.canUndo)
        workspace.redoEdit(); workspace.redoEdit()
        #expect(workspace.selected?.id == id && workspace.selected?.memo.count == 101)
        workspace.save()
        let saved = workspace.project
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == saved)
    }

    @Test func actualTextViewUndoRedoKeepsCaretAndUsesNativeHistoryWithoutTabFocus() throws {
        let box = TextTargetBox()
        let workspace = Workspace(services: services(box)); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(2); workspace.inputDigit(7, at: 100)
        let id = try #require(workspace.selectedID)
        var focusRequests = 0
        workspace.requestKeyboardFocus = { focusRequests += 1 }
        workspace.beginMemoEditing(eventID: id)
        let editor = MemoTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
        editor.allowsUndo = true; editor.isRichText = false; editor.history.groupsByEvent = false
        let delegate = MemoEditor.Coordinator(workspace: workspace, eventID: id)
        editor.delegate = delegate
        box.target = NativeTextUndoTarget(editor.history, editor: editor)
        editor.history.beginUndoGrouping()
        editor.insertText("일반 메모", replacementRange: NSRange(location: 0, length: 0))
        editor.history.endUndoGrouping()
        #expect(workspace.selected?.memo == editor.string && editor.string == "일반 메모")
        #expect(workspace.canPerformUndo)
        workspace.performUndo()
        #expect(editor.string == "" && workspace.selected?.memo == "")
        #expect(editor.selectedRange().location == 0 && focusRequests == 0)
        #expect(workspace.canPerformRedo)
        workspace.performRedo()
        #expect(editor.string == "일반 메모" && workspace.selected?.memo == editor.string)
        #expect(editor.selectedRange().location <= (editor.string as NSString).length && focusRequests == 0)
        workspace.endMemoEditing(eventID: id); box.target = nil
        workspace.undoEdit(); #expect(workspace.selected?.memo == "")
        workspace.undoEdit(); #expect(workspace.project.events.isEmpty)
    }

    @Test func textHistoryBoundaryDoesNotFallThroughIntoProjectUndoAndNoOpPreservesRedo() throws {
        let box = TextTargetBox()
        let workspace = Workspace(services: services(box)); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.inputDigit(7, at: 100)
        let id = try #require(workspace.selectedID)
        let before = workspace.project
        box.target = NativeTextUndoTarget(nil)
        workspace.performUndo(); workspace.performRedo()
        #expect(workspace.project == before && workspace.selectedID == id)
        box.target = nil
        workspace.updateSelected { $0.memo = "redo" }; workspace.undoEdit()
        workspace.beginMemoEditing(eventID: id); workspace.setMemo("", eventID: id); workspace.endMemoEditing(eventID: id)
        #expect(workspace.canRedo)
        workspace.redoEdit(); #expect(workspace.selected?.memo == "redo")
    }

    @Test func actualMemoAndNumericFieldsRetainNativeClipboardUndoBesideBulkSelection() throws {
        let box = TextTargetBox()
        let workspace = Workspace(services: services(box)); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20, events: [
            TabEvent(time: 2, lane: .left, string: 3, fret: 7),
            TabEvent(time: 2.5, lane: .left, string: 4, memo: "keep")])
        #expect(workspace.selectRange(lane: .left, from: 1, to: 3))
        let memoHost = try HostedInspector(workspace); defer { memoHost.close() }
        let editor = memoHost.editor
        #expect(memoHost.window.makeFirstResponder(editor))
        box.target = NativeTextUndoTarget(editor.history, editor: editor)
        let pasteboard = NSPasteboard(name: .init("RoughScore-native-clipboard-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("native memo", forType: .string)
        let selected = workspace.selectedIDs
        #expect(!workspace.copySelection(to: pasteboard) && !workspace.pasteSelection(from: pasteboard))
        #expect(pasteboard.string(forType: .string) == "native memo")
        editor.history.beginUndoGrouping()
        #expect(editor.readSelection(from: pasteboard, type: .string))
        editor.history.endUndoGrouping(); memoHost.settle()
        #expect(workspace.selected?.memo == editor.string && editor.string.contains("native memo"))
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == String(editor.string.prefix(6)))
        workspace.performUndo(); memoHost.settle()
        #expect(!editor.string.contains("native memo") && workspace.selectedIDs == selected)
        workspace.performRedo(); memoHost.settle(); #expect(editor.string.contains("native memo"))
        #expect(workspace.project.events.count == 2)
        box.target = nil
        let actual = try #require(workspace.selected)
        let numeric = NotePointerTests.Host(PositionTimeField(workspace: workspace, event: actual), height: 60)
        defer { numeric.close() }
        let field = try #require(numeric.descendants().compactMap { $0 as? NSTextField }.first)
        #expect(numeric.window.makeFirstResponder(field))
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        let manager = try #require(fieldEditor.undoManager)
        manager.groupsByEvent = false; manager.removeAllActions()
        box.target = NativeTextUndoTarget(manager, editor: fieldEditor)
        let before = workspace.project
        let original = fieldEditor.string
        fieldEditor.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        pasteboard.clearContents(); pasteboard.setString("3.125", forType: .string)
        manager.beginUndoGrouping()
        #expect(fieldEditor.readSelection(from: pasteboard, type: .string))
        manager.endUndoGrouping()
        #expect(fieldEditor.string == "3.125" && workspace.project == before)
        #expect(!workspace.pasteSelection(from: pasteboard))
        workspace.performUndo(); #expect(fieldEditor.string == original && workspace.project == before)
        workspace.performRedo(); #expect(fieldEditor.string == "3.125" && workspace.project == before)
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(fieldEditor.writeSelection(to: pasteboard, types: fieldEditor.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "3.125")
        // Restore the original field value before closing; this test never submits a note edit.
        workspace.performUndo(); box.target = nil
    }

    @Test func inspectorStringAndActiveStringUndoTogetherAndFineEntryDoesNotOverwriteNeighbor() throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(4); workspace.inputDigit(7, at: 100)
        let original = try #require(workspace.selected)
        workspace.updateSelected { $0.string = 1 }
        #expect(workspace.activeString == 1)
        workspace.seekForEditing(6); workspace.inputDigit(0, at: 101)
        #expect(workspace.selected?.string == 1)
        workspace.undoEdit(); workspace.undoEdit()
        #expect(workspace.selected?.id == original.id && workspace.selected?.string == 6 && workspace.activeString == 6)
        workspace.seekForEditing(8); workspace.markUnknown()
        workspace.nudgeSelectedTime(by: 0.01); workspace.inputDigit(1, at: 102); workspace.inputDigit(2, at: 102.1)
        #expect(workspace.project.events.contains { $0.time == 8 && $0.fret == nil })
        #expect(workspace.selected?.time == 8.01 && workspace.selected?.fret == 12)
    }

    @Test func explicitEnterIntervalMovesCursorWithoutInferringRhythm() throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(2); workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        #expect(workspace.setEntryInterval(0.123))
        workspace.advanceEntry()
        #expect(workspace.selectedID == nil && workspace.cursor == 2.123 && workspace.project.events.count == 1)
        workspace.inputDigit(0, at: 101)
        #expect(workspace.project.events.count == 2 && workspace.selected?.time == 2.123)
        #expect(workspace.project.events.allSatisfy { $0.length == nil })
        #expect(!workspace.setEntryInterval(.nan) && !workspace.setEntryInterval(0))
    }
}
