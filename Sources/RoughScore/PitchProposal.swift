import Foundation
import RoughScoreCore

/// One review row from either pitch engine. Transient; only an explicit accept writes TAB.
struct PitchProposal: Equatable, Sendable {
    enum Source: Sendable { case mono, basicPitch }
    /// Basic Pitch rows at or above this mean activation count as qualified for "모두 수락";
    /// weaker rows (often overtones) can still be accepted one by one.
    static let basicPitchAcceptAllAmplitude = 0.5

    let onset: Double
    /// Nearest semitone; nil when the pitch is unknown.
    let midi: Int?
    let qualified: Bool
    let source: Source
    /// Basic Pitch mean note activation; not a calibrated probability.
    let amplitude: Double?

    init(_ proposal: MonophonicTranscriber.Proposal) {
        onset = proposal.onset; midi = proposal.midi.map { Int($0.rounded()) }
        qualified = proposal.qualified; source = .mono; amplitude = nil
    }

    init(_ candidate: PolyNoteCandidate) {
        onset = candidate.onset; midi = candidate.midi
        qualified = candidate.amplitude >= Self.basicPitchAcceptAllAmplitude; source = .basicPitch
        amplitude = candidate.amplitude
    }

    var label: String {
        switch source {
        case .mono: qualified ? "규칙 통과" : "불확실"
        case .basicPitch: "강도 " + String(format: "%.2f", amplitude ?? 0)
        }
    }
}
