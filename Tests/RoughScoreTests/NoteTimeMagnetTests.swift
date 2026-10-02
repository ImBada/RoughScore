import Foundation
import RoughScoreCore
import Testing

struct NoteTimeMagnetTests {
    @Test func nearestVisibleHorizontalPositionWins() {
        let far = anchor(time: 2, x: 107)
        let near = anchor(time: 3, x: 97)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [far, near]) == near)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [near, far]) == near)
    }

    @Test func positionsOutsideTheRadiusRemainFree() {
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [anchor(time: 2, x: 110.001)]) == nil)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: []) == nil)
    }

    @Test func captureBoundaryIsInclusiveAndZeroRadiusRequiresExactAlignment() {
        let edge = anchor(time: 2, x: 110)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [edge]) == edge)
        #expect(NoteTimeMagnet.nearest(to: 110, anchors: [edge], radius: 0) == edge)
        #expect(NoteTimeMagnet.nearest(to: 109.999, anchors: [edge], radius: 0) == nil)
    }

    @Test func equalDistancePrefersEarlierTimeRegardlessOfAnchorOrder() {
        let early = anchor(time: 1, x: 105)
        let late = anchor(time: 2, x: 95)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [late, early]) == early)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [early, late]) == early)
    }

    @Test func equalTimeAndDistancePrefersTheSameIDRegardlessOfAnchorOrder() {
        let first = NoteMagnetAnchor(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, time: 1, x: 95)
        let second = NoteMagnetAnchor(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, time: 1, x: 105)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [second, first]) == first)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: [first, second]) == first)
    }

    @Test func invalidPointerOrRadiusCannotCapture() {
        let valid = anchor(time: 1, x: 100)
        for x in [Double.nan, .infinity, -.infinity] {
            #expect(NoteTimeMagnet.nearest(to: x, anchors: [valid]) == nil)
        }
        for radius in [-1.0, Double.nan, .infinity, -.infinity] {
            #expect(NoteTimeMagnet.nearest(to: 100, anchors: [valid], radius: radius) == nil)
        }
    }

    @Test func invalidAnchorsAreIgnoredWithoutHidingValidNotes() {
        let valid = anchor(time: 0, x: 107)
        let invalid = [anchor(time: -1, x: 100), anchor(time: .nan, x: 100),
                       anchor(time: .infinity, x: 100), anchor(time: 1, x: .nan),
                       anchor(time: 1, x: .infinity), anchor(time: 1, x: -.infinity)]
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: invalid) == nil)
        #expect(NoteTimeMagnet.nearest(to: 100, anchors: invalid + [valid]) == valid)
    }

    @Test func variableTempoUsesRenderedDistanceRatherThanTimeDistance() throws {
        let row = try #require(ScoreLayout(duration: 10, bars: [0, 1]).systems.first)
        let width = 400.0
        let timeNearest = anchor(time: 0.96, x: row.fraction(at: 0.96) * width)
        let visuallyNearest = anchor(time: 1.18, x: row.fraction(at: 1.18) * width)
        #expect(abs(timeNearest.time - 1) < abs(visuallyNearest.time - 1))
        #expect(NoteTimeMagnet.nearest(to: row.fraction(at: 1) * width,
                                     anchors: [timeNearest, visuallyNearest]) == visuallyNearest)
    }

    @Test func pageFitKeepsTheCaptureRadiusInOnScreenPoints() {
        let naturalPointer = 100.0
        let naturalAnchor = 120.0
        let scale = 0.5
        let fullSize = anchor(time: 1, x: naturalAnchor)
        let fitted = anchor(time: 1, x: naturalAnchor * scale)
        let beyondFittedRadius = anchor(time: 2, x: 122 * scale)
        #expect(NoteTimeMagnet.nearest(to: naturalPointer, anchors: [fullSize]) == nil)
        #expect(NoteTimeMagnet.nearest(to: naturalPointer * scale, anchors: [fitted]) == fitted)
        #expect(NoteTimeMagnet.nearest(to: naturalPointer * scale, anchors: [beyondFittedRadius]) == nil)
    }

    private func anchor(time: Double, x: Double) -> NoteMagnetAnchor {
        NoteMagnetAnchor(id: UUID(), time: time, x: x)
    }
}
