import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

struct TimeBoundsTests {
    @Test func preservesValidContinuousTimesIncludingTheFinalMillisecond() {
        for (time, duration) in [(19.9995, 20.0), (1.213456789, 20.0), (0.0000625, 1.0 / 8000)] {
            #expect(TimeBounds.clamp(time, duration: duration) == time)
        }
        for duration in [1.0 / 8000, 0.0005, 0.001, 20] {
            let bounded = TimeBounds.clamp(duration, duration: duration)!
            #expect(bounded >= 0 && bounded < duration)
            #expect(TimeBounds.clamp(-1, duration: duration) == 0)
        }
    }
    @Test func rejectsInvalidInputsRatherThanManufacturingTime() {
        for time in [Double.nan, .infinity, -.infinity] {
            #expect(TimeBounds.clamp(time, duration: 20) == nil)
        }
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(TimeBounds.clamp(1, duration: duration) == nil)
        }
    }
}

@MainActor
struct PositionFieldCommandTests {
    private func fixture() -> (Workspace, TabEvent) {
        var services = WorkspaceServices.isolatedCache()
        services.rememberProject = { _ in }; services.lastProject = { nil }
        services.chooseSaveDestination = { _ in nil }
        let workspace = Workspace(services: services)
        let note = TabEvent(time: 1.213456789, lane: .left, string: 5, memo: "unknown pitch")
        workspace.project = ScoreProject(duration: 20, events: [note])
        workspace.select(note)
        return (workspace, note)
    }

    @Test func roundedDisplayAndStaleOrInvalidFieldCommandsPreserveExactDataAndRedo() {
        let (workspace, note) = fixture(); defer { workspace.shutdown() }
        workspace.updateSelected { $0.memo = "redo" }; workspace.undoEdit()
        let before = workspace.project
        #expect(!workspace.applyPositionTimeInput("1.213", displayed: "1.213", eventID: note.id))
        #expect(!workspace.applyPositionTimeInput("NaN", displayed: "1.213", eventID: note.id))
        #expect(!workspace.applyPositionTimeInput("3", displayed: "1.213", eventID: UUID()))
        for time in [Double.nan, .infinity, -.infinity] { workspace.updateSelected { $0.time = time }; workspace.seek(time) }
        workspace.seekForEditing(.nan, lane: .right)
        workspace.select(TabEvent(time: 9, lane: .right, string: 1))
        var stale = note; stale.time = 9; stale.string = 1
        workspace.select(stale)
        workspace.updateSelected { $0.string = 7 }
        workspace.updateSelected { $0.fret = 25 }
        workspace.updateSelected { $0.id = UUID() }
        #expect(workspace.project == before && workspace.selectedID == note.id)
        #expect(workspace.cursor == note.time && workspace.lane == note.lane && workspace.activeString == note.string)
        #expect(!workspace.canUndo && workspace.canRedo)
        workspace.redoEdit(); #expect(workspace.selected?.memo == "redo")
    }

    @Test func explicitPositionFieldPreservesSubMillisecondPrecisionAndUndoesOnce() {
        let (workspace, note) = fixture(); defer { workspace.shutdown() }
        #expect(workspace.applyPositionTimeInput("19,9995", displayed: "1.213457", eventID: note.id))
        #expect(workspace.selected?.time == 19.9995 && workspace.selected?.id == note.id)
        #expect(workspace.selected?.fret == nil && workspace.selected?.length == nil && workspace.selected?.memo == note.memo)
        workspace.undoEdit(); #expect(workspace.project.events == [note] && !workspace.canUndo)
        workspace.redoEdit(); #expect(workspace.selected?.time == 19.9995)
        #expect((try? workspace.project.validated()) == workspace.project)
    }
}
