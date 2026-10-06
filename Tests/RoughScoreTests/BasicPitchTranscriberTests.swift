import Foundation
@testable import RoughScore
import RoughScoreCore
import Testing

struct BasicPitchTranscriberTests {
    /// Decaying harmonic plucks with a 3 ms attack; ground truth is the oscillator MIDI/onset.
    static func plucks(rate: Double, duration: Double, _ notes: [(midi: Double, onset: Double)]) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(rate * duration))
        for note in notes {
            let frequency = 440 * pow(2, (note.midi - 69) / 12)
            for index in Int(note.onset * rate)..<samples.count {
                let t = Double(index) / rate - note.onset
                var value = 0.0
                for harmonic in 1...6 {
                    value += exp(-t * (2 + Double(harmonic))) / Double(harmonic)
                        * sin(2 * .pi * frequency * Double(harmonic) * t + Double(harmonic) * 0.37)
                }
                samples[index] += Float(0.25 * min(1, t / 0.003) * value)
            }
        }
        return samples
    }

    static func match(_ notes: [PolyNoteCandidate], midi: Int, onset: Double) -> PolyNoteCandidate? {
        notes.first { abs($0.midi - midi) <= 1 && abs($0.onset - onset) <= 0.050 }
    }

    /// L and R are separate calls on one channel each; each crop keeps original seconds.
    @Test(arguments: [44_100.0, 48_000.0])
    func channelCropsKeepOriginalTime(rate: Double) throws {
        let left = Self.plucks(rate: rate, duration: 2.2, [(40, 1.0)])
        let right = Self.plucks(rate: rate, duration: 2.2, [(57, 1.15)])
        let crop = Int(0.8 * rate)..<left.count
        let engine = BasicPitchTranscriber()
        let l = try engine.transcribe(samples: Array(left[crop]), sampleRate: rate, timeOrigin: 0.8)
        let r = try engine.transcribe(samples: Array(right[crop]), sampleRate: rate, timeOrigin: 0.8)
        let ln = try #require(Self.match(l, midi: 40, onset: 1.0), "\(l)")
        let rn = try #require(Self.match(r, midi: 57, onset: 1.15), "\(r)")
        #expect(ln.end > ln.onset && rn.end > rn.onset)
        #expect(ln.amplitude > 0 && ln.amplitude <= 1)
        #expect(ln.pitchBend.filter { $0 == 0 }.count * 2 > ln.pitchBend.count)  // in tune for most frames
        #expect(l.allSatisfy { $0.onset >= 0.8 } && r.allSatisfy { $0.onset >= 0.8 })
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func chordProducesSimultaneousNotes(rate: Double) throws {
        let chord = [(48.0, 0.5), (52.0, 0.5), (55.0, 0.5)]
        let notes = try BasicPitchTranscriber().transcribe(samples: Self.plucks(rate: rate, duration: 1.6, chord), sampleRate: rate)
        for (midi, onset) in chord {
            #expect(Self.match(notes, midi: Int(midi), onset: onset) != nil, "missing \(midi) in \(notes)")
        }
    }

    @Test func silenceAndEmptyInputHaveNoNotes() throws {
        let engine = BasicPitchTranscriber()
        #expect(try engine.transcribe(samples: [Float](repeating: 0, count: 48_000), sampleRate: 48_000).isEmpty)
        #expect(try engine.transcribe(samples: [], sampleRate: 44_100).isEmpty)
    }

    @Test func cancellationStopsBetweenWindowsAndInvalidInputThrows() throws {
        var checks = 0
        #expect(throws: CancellationError.self) {
            try BasicPitchTranscriber().transcribe(samples: Self.plucks(rate: 22_050, duration: 6, [(45, 0.2)]), sampleRate: 22_050,
                                                   isCancelled: { checks += 1; return checks > 2 })
        }
        #expect(checks == 3)
        let engine = BasicPitchTranscriber()
        #expect(throws: BasicPitchTranscriber.TranscriptionError.invalidSampleRate) { try engine.transcribe(samples: [0], sampleRate: .nan) }
        #expect(throws: BasicPitchTranscriber.TranscriptionError.invalidTimeOrigin) { try engine.transcribe(samples: [0], sampleRate: 8_000, timeOrigin: -1) }
        #expect(throws: BasicPitchTranscriber.TranscriptionError.regionTooLong) {
            try engine.transcribe(samples: [Float](repeating: 0, count: 8_000 * 61), sampleRate: 8_000)
        }
        #expect(throws: BasicPitchTranscriber.TranscriptionError.nonfiniteSample) { try engine.transcribe(samples: [0, .nan], sampleRate: 8_000) }
    }

    /// The decoder alone: an onset-led note, a too-short blip and an onset-less sustain (melodia).
    @Test func decoderFollowsBasicPitchRules() throws {
        let frames = 80, bins = BasicPitchDecoder.noteBins
        var activations = BasicPitchDecoder.Activations()
        activations.note = [Float](repeating: 0, count: frames * bins)
        activations.onset = activations.note
        activations.contour = [Float](repeating: 0, count: frames * BasicPitchDecoder.contourBins)
        activations.frameTimes = (0..<frames).map { 10 + Double($0) * 0.01 }
        func set(_ bin: Int, _ range: Range<Int>, onsetAt: Int?) {
            for t in range { activations.note[t * bins + bin] = 0.8 }
            if let onsetAt { activations.onset[onsetAt * bins + bin] = 0.9 }
        }
        set(19, 10..<40, onsetAt: 10)   // MIDI 40
        set(31, 50..<55, onsetAt: 50)   // too short
        set(43, 20..<60, onsetAt: nil)  // MIDI 64, no onset peak
        activations.contour[20 * BasicPitchDecoder.contourBins + 3 * 19 + 2] = 1  // +1/3 semitone at frame 20
        let plain = BasicPitchDecoder.Settings(inferOnsets: false)
        let notes = try BasicPitchDecoder.decode(activations, settings: plain)
        #expect(notes.map(\.midi) == [40, 64])
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
        // Onset-led notes end at the first quiet frame; melodia notes at the last active one.
        #expect(close(notes[0].onset, 10.10) && close(notes[0].end, 10.40) && close(notes[0].amplitude, 0.8))
        #expect(notes[0].pitchBend.count == 30 && close(notes[0].pitchBend[10], 1.0 / 3) && notes[0].pitchBend[0] == 0)
        #expect(close(notes[1].onset, 10.20) && close(notes[1].end, 10.59))
        let withoutMelodia = try BasicPitchDecoder.decode(activations, settings: .init(inferOnsets: false, melodiaTrick: false))
        #expect(withoutMelodia.map(\.midi) == [40])
    }
}
