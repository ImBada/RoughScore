import Foundation
import RoughScoreCore
import Testing

struct ProjectTests {
    @Test func sparseEventsRoundTripWithoutInventingRhythm() throws {
        let project = ScoreProject(title: "리프 메모", duration: 10, events: [
            TabEvent(time: 1.213, lane: .left, string: 6),
            TabEvent(time: 5.98, lane: .right, string: 2, fret: 8, length: .eighth, tentative: true)
        ])
        let decoded = try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(project)).validated()
        #expect(decoded == project)
        #expect(decoded.events.count == 2)
        #expect(decoded.events[0].fret == nil)
        #expect(decoded.events[0].length == nil)
    }

    @Test func invalidFretsStringsAndTimesAreRejected() throws {
        for event in [TabEvent(time: -1, lane: .left, string: 1), TabEvent(time: 10, lane: .left, string: 1),
                      TabEvent(time: .nan, lane: .left, string: 1), TabEvent(time: 1, lane: .left, string: 7),
                      TabEvent(time: 1, lane: .left, string: 1, fret: 25)] {
            #expect(throws: ProjectError.self) { try ScoreProject(duration: 10, events: [event]).validated() }
        }
    }

    @Test func duplicateIDsAndBrokenAnalysisAreRejected() {
        let event = TabEvent(time: 1, lane: .left, string: 1)
        #expect(throws: ProjectError.self) { try ScoreProject(events: [event, event]).validated() }
        #expect(throws: ProjectError.self) {
            try ScoreProject(analyses: ["left": AnalysisSummary(bpm: .infinity)]).validated()
        }
        #expect(throws: ProjectError.self) {
            try ScoreProject(analyses: ["right": AnalysisSummary(sections: [TimeSpan(start: 5, end: 4)])]).validated()
        }
    }

    @Test func snapOnlyMovesNearbyEventsAndKeepsFreeTiming() {
        #expect(TabMath.snap(1.08, beats: [0, 1, 2], enabled: true) == 1)
        #expect(TabMath.snap(1.3, beats: [0, 1, 2], enabled: true) == 1.3)
        #expect(TabMath.snap(1.08, beats: [0, 1, 2], enabled: false) == 1.08)
        #expect(TabMath.snap(1.08, beats: [], enabled: true) == 1.08)
    }

    @Test func samePitchCanHaveSeveralFingerings() {
        #expect(TabMath.midi(string: 1, fret: 0) == TabMath.midi(string: 2, fret: 5))
        #expect(TabMath.midi(string: 6, fret: 0) == 40)
        #expect(TabMath.midi(string: 0, fret: 0) == nil)
    }
}
