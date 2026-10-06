import AVFoundation
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
    private func proposal(_ onset: Double, midi: Double?, qualified: Bool = true) -> PitchProposal {
        PitchProposal(MonophonicTranscriber.Proposal(onset: onset, onsetIsRegionBoundary: false, audioEnd: onset + 0.2,
            reachesRegionEnd: false, frequencyHz: midi.map { 440 * pow(2, ($0 - 69) / 12) }, midi: midi,
            centsFromNearestSemitone: midi.map { ($0 - $0.rounded()) * 100 }, periodicity: midi == nil ? 0.4 : 0.97,
            qualified: qualified, unknownReason: midi == nil ? .aperiodicOrUnstable : nil))
    }
    private func chordNote(_ onset: Double, _ midi: Int, amplitude: Double = 0.7) -> PitchProposal {
        PitchProposal(PolyNoteCandidate(onset: onset, end: onset + 1, midi: midi, amplitude: amplitude, pitchBend: []))
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

    @Test func basicPitchRowsShowAmplitudeAndAcceptAllUsesTheCutoff() {
        let w = workspace(); defer { w.shutdown() }
        let strong = chordNote(2.5, 45, amplitude: 0.62), weak = chordNote(2.5, 57, amplitude: 0.35)
        #expect(strong.source == .basicPitch && strong.midi == 45 && strong.onset == 2.5 && strong.qualified)
        #expect(strong.label == "강도 0.62" && !weak.qualified && weak.label == "강도 0.35")
        let mono = proposal(2, midi: 45.2)
        #expect(mono.source == .mono && mono.midi == 45 && mono.label == "규칙 통과")
        w.showProposals([strong, weak], lane: .left)
        #expect(w.acceptQualifiedProposals() == 1)
        let added = w.project.events.last!
        #expect(added.time == 2.5 && added.lane == .left && added.tentative && added.length == nil)
        #expect(added.fret.flatMap { w.project.soundingMIDI(string: added.string, fret: $0) } == 45)
        #expect(w.pitchProposals == [weak])
    }

    @Test func chordAcceptUsesDistinctStringsInOneUndoStep() {
        let w = workspace(); defer { w.shutdown() }
        let before = w.project
        // Resolved one at a time, B3 and D4 would both take string 2.
        func best(_ midi: Int) -> Int? {
            FingeringResolver.resolve(midi: midi, project: before, context: FingeringContext(lane: .left, time: 2)).candidates.first?.string
        }
        #expect(best(59) != nil && best(59) == best(62))
        w.showProposals([chordNote(2.0, 55), chordNote(2.004, 59), chordNote(2.010, 62)], lane: .left)
        #expect(w.acceptQualifiedProposals() == 3)
        let added = Array(w.project.events.suffix(3))
        #expect(Set(added.map(\.string)).count == 3)
        #expect(added.map { note in note.fret.flatMap { w.project.soundingMIDI(string: note.string, fret: $0) } } == [55, 59, 62])
        #expect(w.selectedIDs == Set(added.map(\.id)))
        w.undoEdit()
        #expect(w.project == before && !w.canUndo)

        // E2 and F2 both exist only on string 6: the second becomes `?` on another string.
        w.showProposals([chordNote(3, 40), chordNote(3, 41)], lane: .left)
        #expect(w.acceptQualifiedProposals() == 2)
        let pair = Array(w.project.events.suffix(2))
        #expect(pair[0].string == 6 && pair[0].fret == 0 && pair[1].fret == nil && pair[1].string != 6)
    }

    /// End to end on real stereo audio: each run reads only the selected channel.
    @Test func basicPitchRunsOnTheSelectedChannel() async throws {
        let rate = 44_100.0
        let left = BasicPitchTranscriberTests.plucks(rate: rate, duration: 2, [(48, 0.5), (52, 0.5), (55, 0.5)])
        let right = BasicPitchTranscriberTests.plucks(rate: rate, duration: 2, [(57, 0.8)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-poly-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
            buffer.frameLength = buffer.frameCapacity
            for (channel, samples) in [left, right].enumerated() {
                for (i, value) in samples.enumerated() { buffer.floatChannelData![channel][i] = value }
            }
            try file.write(from: buffer)
        }
        let w = Workspace(services: .isolatedCache()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: url)?.value == true)
        func found(_ midi: Int, at onset: Double) -> Bool {
            w.pitchProposals.contains { $0.midi == midi && abs($0.onset - onset) < 0.05 }
        }
        w.switchSource(.left)
        await w.proposeChords(from: 0, to: w.project.duration)?.value
        #expect(w.proposalLane == .left && w.pitchProposals.allSatisfy { $0.source == .basicPitch } && w.error == nil)
        #expect(found(48, at: 0.5) && found(52, at: 0.5) && found(55, at: 0.5) && !w.pitchProposals.contains { $0.midi == 57 })
        w.switchSource(.right)
        await w.proposeChords(from: 0, to: w.project.duration)?.value
        #expect(w.proposalLane == .right && found(57, at: 0.8))
        #expect(!w.pitchProposals.contains { [48, 52, 55].contains($0.midi) })
    }
}
