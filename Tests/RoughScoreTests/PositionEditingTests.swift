import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct PositionEditingTests {
    @Test func draggingPreviewsWithoutEditingOrMovingTheView() throws {
        let (workspace, note, otherLane) = fixture()
        parkViewAwayFromNote(workspace)
        workspace.lane = .right
        let originalProject = workspace.project

        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: 4.5, string: 3)
        workspace.previewPositionDrag(time: 8.25, string: 1)

        let preview = try #require(workspace.positionDrag)
        #expect(preview.time == 8.25)
        #expect(preview.string == 1)
        #expect(workspace.renderedEvent(note) == preview)
        #expect(workspace.renderedEvent(otherLane) == otherLane)
        #expect(workspace.project == originalProject)
        #expect(workspace.selectedID == note.id)
        #expect(workspace.lane == note.lane)
        #expect(!workspace.dirty)
        #expect(!workspace.canUndo)
        #expect(!workspace.canRedo)
        expectParkedView(workspace)
    }

    @Test func manyPreviewsCommitAsOneUndoableMove() throws {
        let (workspace, note, otherLane) = fixture()
        parkViewAwayFromNote(workspace)
        workspace.beginPositionDrag(note)
        for time in [3.1, 4.2, 5.3, 6.4] {
            workspace.previewPositionDrag(time: time, string: 2)
        }
        workspace.commitPositionDrag()

        var moved = note
        moved.time = 6.4
        moved.string = 2
        #expect(workspace.positionDrag == nil)
        #expect(workspace.project.events == [moved, otherLane])
        #expect(workspace.selectedID == note.id)
        #expect(workspace.lane == note.lane)
        #expect(workspace.dirty)
        #expect(workspace.canUndo)
        expectParkedView(workspace)
        #expect(try workspace.project.validated() == workspace.project)

        workspace.undoEdit()
        #expect(workspace.project.events == [note, otherLane])
        #expect(!workspace.canUndo)
        #expect(workspace.canRedo)

        workspace.redoEdit()
        #expect(workspace.project.events == [moved, otherLane])
        #expect(workspace.selectedID == note.id)
        #expect(workspace.canUndo)
        #expect(!workspace.canRedo)
    }

    @Test func cancellingDiscardsThePreviewWithoutEditing() {
        let (workspace, note, otherLane) = fixture()
        parkViewAwayFromNote(workspace)
        let originalProject = workspace.project
        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: 7, string: 1)
        workspace.cancelPositionDrag()

        #expect(workspace.positionDrag == nil)
        #expect(workspace.renderedEvent(note) == note)
        #expect(workspace.project == originalProject)
        #expect(workspace.project.events == [note, otherLane])
        #expect(workspace.selectedID == note.id)
        #expect(workspace.lane == note.lane)
        #expect(!workspace.dirty)
        #expect(!workspace.canUndo)
        #expect(!workspace.canRedo)
        expectParkedView(workspace)
    }

    @Test func dragAndDirectMovesClampToTheSongAndSixStrings() throws {
        let (workspace, note, otherLane) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: -100, string: -100, snap: false)
        #expect(workspace.positionDrag?.time == 0)
        #expect(workspace.positionDrag?.string == 1)
        workspace.previewPositionDrag(time: 100, string: 100, snap: false)
        #expect(workspace.positionDrag?.time == workspace.project.duration.nextDown)
        #expect(workspace.positionDrag?.string == 6)
        workspace.commitPositionDrag()
        #expect(workspace.selected?.time == workspace.project.duration.nextDown)
        #expect(workspace.selected?.string == 6)

        workspace.moveSelectedPosition(to: -100, string: -100)
        #expect(workspace.selected?.time == 0)
        #expect(workspace.selected?.string == 1)
        workspace.moveSelectedPosition(to: 100, string: 100)
        #expect(workspace.selected?.time == workspace.project.duration.nextDown)
        #expect(workspace.selected?.string == 6)
        #expect(workspace.project.events.first { $0.id == otherLane.id } == otherLane)
        #expect(try workspace.project.validated() == workspace.project)
    }

    @Test func dragSnapUsesTheScoreAnalysisAndCanBeBypassed() {
        let (workspace, note, _) = fixture()
        workspace.project.analyses = ["stereo": AnalysisSummary(beats: [0, 1, 2, 3, 4], bars: [0, 2])]
        workspace.source = .left
        workspace.snapToBeat = true
        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: 3.08, string: 4)

        #expect(workspace.summary == nil)
        #expect(workspace.positionDrag?.time == 3)
        #expect(workspace.selected?.time == note.time)

        workspace.previewPositionDrag(time: 3.08, string: 4, snap: false)
        #expect(workspace.positionDrag?.time == 3.08)
        workspace.commitPositionDrag()
        #expect(workspace.selected?.time == 3.08)
    }

    @Test func dragSnapRespectsTheDisabledToggle() {
        let (workspace, note, _) = fixture()
        workspace.project.analyses = ["stereo": AnalysisSummary(beats: [0, 1, 2, 3])]
        workspace.snapToBeat = false
        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: 3.08, string: 4)

        #expect(workspace.positionDrag?.time == 3.08)
        #expect(!workspace.dirty)
        #expect(!workspace.canUndo)
    }

    @Test func unchangedDragDoesNotCreateAnUndoOrDirtyTheProject() {
        let (workspace, note, _) = fixture()
        let originalProject = workspace.project
        workspace.beginPositionDrag(note)
        workspace.previewPositionDrag(time: 6, string: 2)
        workspace.previewPositionDrag(time: note.time, string: note.string)
        workspace.commitPositionDrag()

        #expect(workspace.positionDrag == nil)
        #expect(workspace.project == originalProject)
        #expect(!workspace.dirty)
        #expect(!workspace.canUndo)
        #expect(!workspace.canRedo)
    }

    @Test func directMovementKeepsSelectionAndViewAndAllowsTimeOnlyAdjustment() {
        let (workspace, note, otherLane) = fixture()
        workspace.select(note)
        parkViewAwayFromNote(workspace)
        workspace.moveSelectedPosition(to: 6.5, string: 3)
        workspace.moveSelectedPosition(to: 7.25)

        var moved = note
        moved.time = 7.25
        moved.string = 3
        #expect(workspace.project.events == [moved, otherLane])
        #expect(workspace.selectedID == note.id)
        #expect(workspace.lane == note.lane)
        expectParkedView(workspace)
    }

    private func fixture() -> (Workspace, TabEvent, TabEvent) {
        let workspace = Workspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 12,
                            length: .eighth, tentative: true, memo: "벤딩 · 확인")
        let otherLane = TabEvent(time: 3, lane: .right, string: 2, fret: 7)
        workspace.project = ScoreProject(title: "위치 편집 테스트", duration: 20, events: [note, otherLane])
        return (workspace, note, otherLane)
    }

    private func parkViewAwayFromNote(_ workspace: Workspace) {
        workspace.measuresPerSystem = 1
        workspace.cursor = 15
        workspace.windowStart = 12
        workspace.windowLength = 4
        workspace.scorePage = 2
        workspace.followScore = true
        workspace.loopStart = 14
        workspace.loopEnd = 16
        workspace.looping = true
    }

    private func expectParkedView(_ workspace: Workspace) {
        #expect(workspace.cursor == 15)
        #expect(workspace.windowStart == 12)
        #expect(workspace.windowLength == 4)
        #expect(workspace.scorePage == 2)
        #expect(workspace.followScore)
        #expect(workspace.loopStart == 14)
        #expect(workspace.loopEnd == 16)
        #expect(workspace.looping)
    }
}
