import RoughScoreCore
import Testing
@testable import RoughScore

struct ScoreLayoutTests {
    @Test func threeMinuteSongWrapsAcrossPagesWithoutGaps() {
        let layout = ScoreLayout(duration: 180, bars: stride(from: 0.0, to: 180, by: 2).map { $0 })
        #expect(layout.usesDetectedBars)
        #expect(layout.systems.count == 23)
        #expect(layout.pageCount == 6)
        let measures = layout.systems.flatMap(\.measures)
        #expect(measures.count == 90)
        #expect(measures.first?.start == 0)
        #expect(measures.last?.end == 180)
        for pair in zip(measures, measures.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        #expect(layout.rows(on: 5).last?.measures.count == 2)
        #expect(layout.page(at: 31.999) == 0)
        #expect(layout.page(at: 32) == 1)
        #expect(layout.page(at: 179.999) == 5)
    }

    @Test func timeBlocksDoNotInventBarsOrDiscardPartialEnd() {
        let layout = ScoreLayout(duration: 181.25, measuresPerSystem: 8)
        #expect(!layout.usesDetectedBars)
        #expect(layout.systems.flatMap(\.measures).allSatisfy { $0.number == nil })
        #expect(layout.systems.last?.end == 181.25)
        #expect(layout.systems.last?.measures.last?.start == 180)
        #expect(ScoreLayout(duration: 0.5).systems.count == 1)
    }

    @Test func variableTempoMapsBothWaysWithoutQuantizingNotes() throws {
        let layout = ScoreLayout(duration: 9, bars: [0, 1.8, 4.1, 6.5])
        let row = try #require(layout.systems.first)
        #expect(abs(row.fraction(at: 4.1) - 0.5) < 0.00001)
        for time in [0.0, 1.123, 1.8, 3.256, 4.1, 6.7, 8.999] {
            #expect(abs(row.time(at: row.fraction(at: time)) - time) < 0.00001)
        }
        #expect(row.time(at: 1) == 9)
    }

    @Test func leadInAndDuplicateBoundariesKeepCorrectBarNumbers() {
        let layout = ScoreLayout(duration: 7, bars: [4, 1, 1, .nan, -1, 7, 20])
        let measures = layout.systems.flatMap(\.measures)
        #expect(measures.map(\.start) == [0, 1, 4])
        #expect(measures.map(\.number) == [nil, 1, 2])
        #expect(ScoreLayout(duration: 0).systems.isEmpty)
    }

    @MainActor @Test func browsingAndEditingPreserveSparseEvents() {
        let workspace = Workspace(services: .isolatedCache())
        workspace.project = ScoreProject(duration: 180, events: [TabEvent(time: 170.123, lane: .right, string: 2)])
        let event = workspace.project.events[0]
        workspace.browseScorePage(3)
        #expect(!workspace.followScore)
        #expect(workspace.cursor == 2)
        workspace.select(event)
        #expect(workspace.lane == .right)
        #expect(workspace.displayedScorePage == 5)
        #expect(workspace.cursor == 170.123)
        #expect(workspace.windowStart <= event.time && workspace.windowEnd > event.time)
        workspace.showBothLanes = true
        workspace.followScoreCursor()
        #expect(workspace.displayedScorePage == 10)
        let row = workspace.scoreLayout.rows(on: workspace.displayedScorePage)[0]
        workspace.editSystem(row)
        #expect(!workspace.scoreView)
        #expect(workspace.windowStart == row.start)
        #expect(workspace.windowEnd == row.end)
        #expect(workspace.project.events == [event])
        #expect(!workspace.dirty)
    }

    @MainActor @Test func changingDensityKeepsThePageBeingRead() {
        let workspace = Workspace(services: .isolatedCache())
        workspace.project = ScoreProject(duration: 180)
        workspace.browseScorePage(3)
        let previous = workspace.scoreLayout
        workspace.measuresPerSystem = 8
        workspace.reflowScore(from: previous)
        #expect(workspace.scoreLayout.rows(on: workspace.displayedScorePage).first?.start == 64)
        #expect(workspace.cursor == 2)
        let single = workspace.scoreLayout
        workspace.showBothLanes = true
        workspace.reflowScore(from: single)
        #expect(workspace.scoreLayout.rows(on: workspace.displayedScorePage).first?.start == 64)
    }
}
