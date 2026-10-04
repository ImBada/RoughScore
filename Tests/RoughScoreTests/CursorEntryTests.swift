import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct CursorEntryTests {
    @Test func waveformUnknownThenArrowAndTwoDigitsCreatesSeparateSparseNotes() {
        let workspace = Workspace(services: .isolatedCache()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(4.5, lane: .right)
        workspace.moveSelectedString(by: -1)
        workspace.markUnknown()
        #expect(workspace.project.events.count == 1)
        #expect(workspace.selectedID == nil)
        workspace.nudgeSelectedTime(by: 0.05)
        workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        #expect(workspace.project.events.count == 2)
        #expect(workspace.project.events.first?.time == 4.5 && workspace.project.events.first?.fret == nil)
        #expect(workspace.selected?.time == 4.55 && workspace.selected?.fret == 12)
        #expect(workspace.project.events.allSatisfy { $0.lane == .right && $0.string == 5 && $0.length == nil })
        workspace.undoEdit()
        #expect(workspace.project.events.count == 1 && workspace.project.events.first?.fret == nil)
    }

    @Test func noSelectionArrowMovesCursorWithFiniteExclusiveBounds() {
        let workspace = Workspace(services: .isolatedCache()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(5)
        workspace.nudgeSelectedTime(by: -0.01)
        #expect(workspace.cursor == 4.99 && workspace.project.events.isEmpty)
        workspace.nudgeSelectedTime(by: -100); #expect(workspace.cursor == 0)
        workspace.nudgeSelectedTime(by: 100); #expect(workspace.cursor >= 0 && workspace.cursor < 20)
        #expect(!workspace.canUndo)
    }
}
