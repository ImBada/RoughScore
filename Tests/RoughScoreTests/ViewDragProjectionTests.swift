import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct ViewDragProjectionTests {
    @Test(arguments: [0.000125, 0.0005, 0.000625, 0.001, 20.0], [false, true])
    func actualProjectionPreservesVerticalAndNoOpTime(duration: Double, vertical: Bool) throws {
        for score in [false, true] {
            var services = WorkspaceServices.isolatedCache()
            services.rememberProject = { _ in }; services.lastProject = { nil }; services.chooseSaveDestination = { _ in nil }
            let workspace = Workspace(services: services); defer { workspace.shutdown() }
            let time = duration < 0.002 ? duration / 2 : duration - 0.0005
            let note = TabEvent(time: time, lane: .left, string: 5, memo: "exact time")
            workspace.project = ScoreProject(duration: duration, events: [note])
            workspace.windowStart = 0; workspace.windowLength = duration; workspace.select(note)
            let before = workspace.project
            let row = try #require(workspace.scoreLayout.systems.last)
            let target = try #require(score
                ? TimeBounds.scoreDragTime(note.time, system: row, translation: 0, width: 1000)
                : TimeBounds.timelineDragTime(note.time, start: workspace.windowStart, end: workspace.windowEnd, translation: 0, width: 1000))
            #expect(target == note.time)
            workspace.beginPositionDrag(note)
            workspace.previewMagneticPosition(time: target, string: vertical ? 6 : note.string,
                screenX: 500, anchors: [], shift: false)
            workspace.commitPositionDrag()
            #expect(workspace.project.events[0].time == note.time)
            #expect(workspace.project.events[0].id == note.id && workspace.project.events[0].memo == note.memo)
            #expect(workspace.project.events[0].fret == nil && workspace.project.events[0].length == nil)
            if vertical {
                #expect(workspace.selected?.string == 6 && workspace.canUndo)
                workspace.undoEdit(); #expect(workspace.project == before && !workspace.canUndo)
            } else {
                #expect(workspace.project == before && !workspace.canUndo)
            }
        }
    }

    @Test func horizontalProjectionUsesTheActualTinyWindowAndExclusiveEdges() throws {
        let duration = 1.0 / 8000
        let row = try #require(ScoreLayout(duration: duration).systems.first)
        let mid = duration / 2
        #expect(TimeBounds.timelineDragTime(mid, start: 0, end: duration, translation: 100, width: 1000) == mid + duration * 0.1)
        for score in [false, true] {
            let target = try #require(score
                ? TimeBounds.scoreDragTime(mid, system: row, translation: 10000, width: 1000)
                : TimeBounds.timelineDragTime(mid, start: 0, end: duration, translation: 10000, width: 1000))
            #expect(target >= 0 && target < duration)
            #expect(target == duration.nextDown)
        }
        #expect(TimeBounds.timelineDragTime(mid, start: 0, end: duration, translation: .nan, width: 1000) == nil)
        #expect(TimeBounds.scoreDragTime(mid, system: row, translation: 1, width: 0) == nil)
    }
}
