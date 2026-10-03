import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
private final class TextTargetBox { var target: NativeTextUndoTarget? }

@MainActor
struct FieldUndoTests {
    private func services(_ box: TextTargetBox = TextTargetBox()) -> WorkspaceServices {
        var value = WorkspaceServices.live
        value.rememberProject = { _ in }; value.lastProject = { nil }; value.chooseSaveDestination = { _ in nil }
        value.nativeTextUndo = { box.target }
        return value
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
