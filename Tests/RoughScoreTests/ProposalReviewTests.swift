import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@MainActor
@Suite(.serialized)
struct ProposalReviewTests {
    private func workspace() -> Workspace {
        var services = WorkspaceServices.isolatedCache()
        services.rememberProject = { _ in }; services.lastProject = { nil }; services.chooseSaveDestination = { _ in nil }
        let workspace = Workspace(services: services)
        workspace.project = ScoreProject(duration: 16, events: [
            TabEvent(time: 1.0, lane: .left, string: 6, fret: 0),
            TabEvent(time: 1.0, lane: .right, string: 5, fret: 0)])
        return workspace
    }
    private func proposal(_ onset: Double, midi: Double?, qualified: Bool = true) -> MonophonicTranscriber.Proposal {
        .init(onset: onset, onsetIsRegionBoundary: false, audioEnd: onset + 0.2, reachesRegionEnd: false,
              frequencyHz: midi.map { 440 * pow(2, ($0 - 69) / 12) }, midi: midi,
              centsFromNearestSemitone: midi.map { ($0 - $0.rounded()) * 100 }, periodicity: midi == nil ? 0.4 : 0.97,
              qualified: qualified, unknownReason: midi == nil ? .aperiodicOrUnstable : nil)
    }

    @Test func acceptInsertsTentativeNoteAtExactOnsetAndUndoesInOneStep() {
        let w = workspace(); defer { w.shutdown() }
        let before = w.project
        let a2 = proposal(2.123456789, midi: 45.2), unknown = proposal(3.5, midi: nil, qualified: false)
        w.showProposals([a2, unknown], lane: .right)
        #expect(w.acceptProposals([a2]) == 1)
        let added = w.project.events.last!
        #expect(added.time == 2.123456789 && added.lane == .right && added.string == 5 && added.fret == 0)
        #expect(added.length == nil && added.tentative && w.selectedID == added.id)
        #expect(w.pitchProposals == [unknown])
        #expect(Array(w.project.events.prefix(2)) == before.events)
        w.undoEdit()
        #expect(w.project == before && !w.canUndo)

        // Unknown pitch becomes `?` on the active string, never an invented fret.
        #expect(w.acceptProposals([unknown]) == 1)
        let mark = w.project.events.last!
        #expect(mark.fret == nil && mark.string == w.activeString && mark.lane == .right && mark.time == 3.5)
        #expect(w.pitchProposals.isEmpty)
    }

    @Test func acceptAllQualifiedIsOneUndoStep() {
        let w = workspace(); defer { w.shutdown() }
        let before = w.project
        let unsure = proposal(4, midi: 52, qualified: false)
        w.showProposals([proposal(2, midi: 40), unsure, proposal(6, midi: 64)], lane: .left)
        #expect(w.acceptQualifiedProposals() == 2)
        #expect(w.project.events.count == before.events.count + 2)
        #expect(w.project.events.suffix(2).map(\.time) == [2, 6])
        #expect(w.project.events.suffix(2).allSatisfy { $0.lane == .left && $0.tentative && $0.length == nil })
        #expect(w.pitchProposals == [unsure])
        w.undoEdit()
        #expect(w.project == before && !w.canUndo)
    }

    @Test func rejectLeavesProjectUnchanged() {
        let w = workspace(); defer { w.shutdown() }
        let before = w.project
        let p = proposal(2, midi: 40)
        w.showProposals([p], lane: .left)
        w.rejectProposal(p)
        #expect(w.pitchProposals.isEmpty && w.project == before && !w.canUndo)
    }

    @Test func existingSamePitchNoteWithin30msIsSkipped() {
        let w = workspace(); defer { w.shutdown() }
        let before = w.project
        // E2 already at 1.0 in L; A2 at 1.0 exists only in R, so it is new in L.
        let duplicate = proposal(1.02, midi: 40), otherPitch = proposal(1.01, midi: 45), later = proposal(1.05, midi: 40)
        w.showProposals([duplicate, otherPitch, later], lane: .left)
        #expect(w.acceptProposals([duplicate]) == 0)
        #expect(w.project == before && !w.canUndo && w.pitchProposals == [otherPitch, later])
        #expect(w.acceptQualifiedProposals() == 2)
        #expect(w.project.events.suffix(2).map(\.time) == [1.01, 1.05])
        w.undoEdit()
        #expect(w.project == before)
    }
}
