import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct EditorWorkflowTests {
    @Test func typedFretsKeepTheClickedNoteSelected() throws {
        let workspace = emptyWorkspace()
        workspace.addEvent(time: 2, string: 6)
        let selectedID = try #require(workspace.selectedID)

        workspace.inputDigit(1, at: 100)
        workspace.inputDigit(2, at: 100.1)

        #expect(workspace.project.events.count == 1)
        #expect(workspace.selectedID == selectedID)
        #expect(workspace.selected?.fret == 12)
        #expect(workspace.selected?.string == 6)
        #expect(workspace.selected?.time == 2)
    }

    @Test func creatingAndTypingANoteUndoTogether() throws {
        let workspace = emptyWorkspace()
        let otherLane = TabEvent(time: 3, lane: .right, string: 2, fret: 7)
        workspace.project.events = [otherLane]
        workspace.addEvent(time: 2, string: 6)
        let noteID = try #require(workspace.selectedID)
        workspace.inputDigit(1, at: 100)
        workspace.inputDigit(2, at: 100.1)
        #expect(workspace.canUndo)

        workspace.undoEdit()
        #expect(workspace.project.events == [otherLane])
        #expect(!workspace.canUndo)
        #expect(workspace.canRedo)

        workspace.redoEdit()
        #expect(workspace.project.events.first { $0.id == noteID }?.fret == 12)
        #expect(workspace.project.events.first { $0.id == otherLane.id } == otherLane)
        #expect(workspace.canUndo)
        #expect(!workspace.canRedo)
    }

    @Test func twoDigitsReplacingAnExistingFretUndoTogether() {
        let workspace = emptyWorkspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 7)
        workspace.project.events = [note]
        workspace.select(note)
        workspace.inputDigit(1, at: 100)
        workspace.inputDigit(2, at: 100.1)
        #expect(workspace.selected?.fret == 12)

        workspace.undoEdit()
        #expect(workspace.project.events == [note])
        #expect(!workspace.canUndo)

        workspace.redoEdit()
        #expect(workspace.project.events.count == 1)
        #expect(workspace.project.events.first?.id == note.id)
        #expect(workspace.project.events.first?.fret == 12)
    }

    @Test func selectingAnotherNoteStartsAReplacement() {
        let workspace = emptyWorkspace()
        let first = TabEvent(time: 2, lane: .left, string: 5, fret: 7)
        let second = TabEvent(time: 3, lane: .left, string: 4, fret: 8)
        workspace.project.events = [first, second]
        workspace.select(first)
        workspace.inputDigit(1, at: 100)
        workspace.select(second)
        workspace.inputDigit(2, at: 100.1)

        #expect(workspace.selectedID == second.id)
        #expect(workspace.selected?.fret == 2)
        #expect(workspace.project.events.first { $0.id == first.id }?.fret == 1)
    }

    @Test func deletingAndUndoingRestoresTheSameNote() {
        let workspace = emptyWorkspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 12, tentative: true, memo: "확인")
        let otherLane = TabEvent(time: 2, lane: .right, string: 2, fret: 7)
        workspace.project.events = [note, otherLane]
        workspace.select(note)
        workspace.deleteSelected()
        #expect(workspace.project.events == [otherLane])

        workspace.undoEdit()
        #expect(workspace.project.events == [note, otherLane])
        workspace.redoEdit()
        #expect(workspace.project.events == [otherLane])
    }

    @Test func readingAndNavigatingDoNotCreateUndoHistory() {
        let workspace = emptyWorkspace()
        let first = TabEvent(time: 1, lane: .left, string: 6, fret: 0)
        let second = TabEvent(time: 2, lane: .left, string: 5, fret: 2)
        let third = TabEvent(time: 6, lane: .left, string: 4, fret: 2)
        let otherLane = TabEvent(time: 3, lane: .right, string: 2, fret: 7)
        let events = [third, otherLane, first, second]
        workspace.project.events = events
        workspace.select(second)
        workspace.selectAdjacentEvent()
        #expect(workspace.selectedID == third.id)
        workspace.selectAdjacentEvent(backwards: true)
        #expect(workspace.selectedID == second.id)
        workspace.seekForEditing(10)

        #expect(workspace.selectedID == nil)
        #expect(workspace.project.events == events)
        #expect(!workspace.canUndo)
        #expect(!workspace.canRedo)
    }

    @Test func nudgesStayInsideTheSongAndSixStrings() throws {
        let workspace = emptyWorkspace()
        let note = TabEvent(time: 2, lane: .left, string: 1, fret: 12)
        let otherLane = TabEvent(time: 3, lane: .right, string: 2, fret: 7)
        workspace.project.events = [note, otherLane]
        workspace.select(note)

        workspace.moveSelectedString(by: -1)
        #expect(workspace.selected?.string == 1)
        workspace.moveSelectedString(by: 20)
        #expect(workspace.selected?.string == 6)
        workspace.nudgeSelectedTime(by: 100)
        let lastTime = try #require(workspace.selected?.time)
        #expect(lastTime >= 0)
        #expect(lastTime < workspace.project.duration)
        workspace.nudgeSelectedTime(by: -100)
        #expect(workspace.selected?.time == 0)
        #expect(workspace.project.events.first { $0.id == otherLane.id } == otherLane)
        #expect(try workspace.project.validated() == workspace.project)
    }

    @Test func waveformSeekingClearsSelectionAndEscapesAnOldLoop() {
        let workspace = emptyWorkspace()
        #expect(!workspace.looping)
        workspace.addEvent(time: 2, string: 6)
        workspace.setLoop(from: 1, to: 4)
        workspace.seekForEditing(3)
        #expect(workspace.selectedID == nil)
        #expect(workspace.looping)
        #expect(workspace.cursor == 3)

        workspace.seekForEditing(10, lane: .right)
        #expect(workspace.cursor == 10)
        #expect(workspace.lane == .right)
        #expect(!workspace.looping)
    }

    @Test func loopRangesAreOrderedAndClampedToTheSong() {
        let workspace = emptyWorkspace()
        workspace.setLoop(from: 15, to: 5)
        #expect(workspace.loopStart == 5)
        #expect(workspace.loopEnd == 15)
        #expect(workspace.looping)

        workspace.setLoop(from: 40, to: -2)
        #expect(workspace.loopStart == 0)
        #expect(workspace.loopEnd == workspace.project.duration)
        #expect(workspace.looping)
        #expect(!workspace.canUndo)
    }

    @Test func scoreAnalysisSuppliesSnapWhileListeningToAnUnanalyzedChannel() {
        let workspace = emptyWorkspace()
        workspace.project.analyses = ["stereo": AnalysisSummary(beats: [0, 1, 2], bars: [0, 2])]
        workspace.source = .left
        workspace.snapToBeat = true
        workspace.addEvent(time: 1.08, string: 6)

        #expect(workspace.summary == nil)
        #expect(workspace.selected?.time == 1)
    }

    private func emptyWorkspace() -> Workspace {
        let workspace = Workspace()
        workspace.project = ScoreProject(title: "빠른 입력 테스트", duration: 20)
        return workspace
    }

    @Test func waveformClickAndTypingCreatesAtTheActiveString() {
        let workspace = emptyWorkspace()
        let original = TabEvent(time: 2, lane: .left, string: 6, fret: 7)
        workspace.project.events = [original]
        workspace.seekForEditing(4.5, lane: .right)
        workspace.moveSelectedString(by: -4)
        workspace.inputDigit(0, at: 100)
        #expect(workspace.selected?.time == 4.5)
        #expect(workspace.selected?.string == 2)
        #expect(workspace.selected?.lane == .right)
        #expect(workspace.selected?.fret == 0)
        workspace.undoEdit()
        #expect(workspace.project.events == [original])
    }

    @Test func rejectingFret25DoesNotWriteAnInvalidProject() {
        let workspace = emptyWorkspace()
        let original = TabEvent(time: 2, lane: .left, string: 6, fret: 7)
        workspace.project.events = [original]
        workspace.select(original)
        workspace.inputDigit(2, at: 100)
        workspace.inputDigit(5, at: 100.1)
        #expect(workspace.selected?.fret == 2)
        workspace.undoEdit()
        #expect(workspace.project.events == [original])
    }

    @Test func undoingInputKeepsAnalysisThatFinishedLater() {
        let workspace = emptyWorkspace()
        workspace.addEvent(time: 2, string: 6)
        workspace.inputDigit(7, at: 100)
        let summary = AnalysisSummary(bpm: 120, beats: [0, 1, 2], bars: [0, 2])
        workspace.project.analyses["stereo"] = summary
        workspace.undoEdit()
        #expect(workspace.project.events.isEmpty)
        #expect(workspace.project.analyses["stereo"] == summary)
    }

    @Test func undoingStringMovementRestoresTheNextInputString() {
        let workspace = emptyWorkspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 7)
        workspace.project.events = [note]
        workspace.select(note)
        workspace.moveSelectedString(by: -1)
        #expect(workspace.activeString == 4)
        workspace.undoEdit()
        #expect(workspace.selected?.string == 5)
        #expect(workspace.activeString == 5)
    }

    @Test func channelSelectionKeepsEditingAndListeningTogether() {
        let workspace = emptyWorkspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 7)
        workspace.project.events = [note]
        workspace.select(note)
        workspace.switchSource(.right)
        #expect(workspace.lane == .right)
        #expect(workspace.selectedID == nil)
        workspace.switchSource(.stereo)
        #expect(workspace.lane == .right)
        #expect(workspace.project.events == [note])
        #expect(!workspace.canUndo)
    }
}
