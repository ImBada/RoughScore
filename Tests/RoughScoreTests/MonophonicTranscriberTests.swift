import Foundation
import RoughScoreCore
import Testing

struct MonophonicTranscriberTests {
    /// Analytic decaying string partials, with a 3 ms attack and harmonic-specific
    /// decay/phase. Ground truth is the independently specified oscillator F0/onset.
    static func pluck(rate: Double, midi: Double, onset: Double = 0.2,
                      duration: Double = 0.8, missingFundamental: Bool = false,
                      amplitude: Double = 0.5) -> [Float] {
        let frequency = 440 * pow(2, (midi - 69) / 12)
        return (0..<Int(rate * duration)).map { index in
            let t = Double(index) / rate - onset
            guard t >= 0, t < 0.45 else { return 0 }
            let attack = min(1, t / 0.003)
            var value = 0.0
            for harmonic in 1...7 {
                if missingFundamental && harmonic == 1 { continue }
                // The second partial dominates: taking the spectral maximum
                // would be an octave wrong, even when the fundamental is present.
                let strength = harmonic == 1 ? 0.25 : (harmonic == 2 ? 1.0 : 0.8 / Double(harmonic))
                value += strength * exp(-t * (3 + Double(harmonic))) * sin(2 * .pi * frequency * Double(harmonic) * t + Double(harmonic) * 0.37)
            }
            return Float(amplitude * attack * value)
        }
    }

    @Test(arguments: [44_100.0, 48_000.0], [40.0, 45, 52, 59, 64, 76, 88])
    func isolatedPluckedHarmonics(rate: Double, midi: Double) throws {
        let result = try MonophonicTranscriber().analyze(samples: Self.pluck(rate: rate, midi: midi), sampleRate: rate)
        let notes = result.proposals.filter(\.qualified)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        let measured = try #require(note.midi)
        #expect(abs(measured - midi) <= 1, "measured MIDI \(measured), ground truth \(midi)")
        #expect(abs(note.onset - 0.2) <= 0.030)
        #expect(note.periodicity >= 0.85)
        #expect(note.unknownReason == nil)
        #expect(note.audioEnd > note.onset)
    }

    @Test(arguments: [40.0, 57, 76])
    func missingFundamentalUsesHarmonicPeriod(midi: Double) throws {
        let result = try MonophonicTranscriber().analyze(samples: Self.pluck(rate: 48_000, midi: midi, missingFundamental: true), sampleRate: 48_000)
        let note = try #require(result.proposals.filter { $0.qualified }.first)
        let measured = try #require(note.midi)
        #expect(abs(measured - midi) <= 1, "measured MIDI \(measured), ground truth \(midi)")
    }

    @Test func asymmetricChannelsAndSelectedOrigin() throws {
        let rate = 48_000.0
        let left = Self.pluck(rate: rate, midi: 40, onset: 1, duration: 1.8)
        let right = Self.pluck(rate: rate, midi: 57, onset: 1.15, duration: 1.8)
        let crop = Int(0.8 * rate)..<Int(1.8 * rate)
        let l = try MonophonicTranscriber().analyze(samples: left, sampleRate: rate, region: crop)
        // Equivalently pass a pre-cropped channel and its original origin.
        let r = try MonophonicTranscriber().analyze(samples: Array(right[crop]), sampleRate: rate, timeOrigin: 0.8)
        let ln = try #require(l.proposals.filter { $0.qualified }.first)
        let rn = try #require(r.proposals.filter { $0.qualified }.first)
        #expect(abs(ln.onset - 1.0) <= 0.030)
        #expect(abs(rn.onset - 1.15) <= 0.030)
        #expect(abs(try #require(ln.midi) - 40) <= 1)
        #expect(abs(try #require(rn.midi) - 57) <= 1)
        #expect(l.analyzedOriginalRange == 0.8..<1.8)
    }

    @Test func silenceEmptyAndVeryShortAreTransparent() throws {
        let dsp = MonophonicTranscriber()
        #expect(try dsp.analyze(samples: [Float](repeating: 0, count: 48_000), sampleRate: 48_000).proposals.isEmpty)
        #expect(try dsp.analyze(samples: [], sampleRate: 48_000).proposals.isEmpty)
        let short = try dsp.analyze(samples: Self.pluck(rate: 48_000, midi: 40, onset: 0, duration: 0.020), sampleRate: 48_000)
        #expect(!short.proposals.isEmpty)
        #expect(short.proposals.allSatisfy { !$0.qualified && $0.midi == nil && $0.frequencyHz == nil && $0.unknownReason == .insufficientAudio })
    }

    @Test func invalidInputsThrowInsteadOfSuccessfulInference() throws {
        let dsp = MonophonicTranscriber()
        for rate in [0.0, -48_000, .nan, .infinity, 1, 200_000] {
            #expect(throws: MonophonicTranscriber.AnalysisError.invalidSampleRate) { try dsp.analyze(samples: [], sampleRate: rate) }
        }
        for origin in [-1.0, .nan, .infinity, Double.greatestFiniteMagnitude] {
            #expect(throws: MonophonicTranscriber.AnalysisError.invalidTimeOrigin) { try dsp.analyze(samples: [], sampleRate: 48_000, timeOrigin: origin) }
        }
        #expect(throws: MonophonicTranscriber.AnalysisError.invalidRegion) { try dsp.analyze(samples: [0], sampleRate: 48_000, region: -1..<1) }
        #expect(throws: MonophonicTranscriber.AnalysisError.invalidRegion) { try dsp.analyze(samples: [0], sampleRate: 48_000, region: 0..<2) }
        #expect(throws: MonophonicTranscriber.AnalysisError.regionTooLong) { try dsp.analyze(samples: [Float](repeating: 0, count: 8_000 * 61), sampleRate: 8_000) }
        #expect(throws: MonophonicTranscriber.AnalysisError.invalidSettings) { try MonophonicTranscriber(settings: .init(minimumRMS: .nan)).analyze(samples: [], sampleRate: 48_000) }
        for bad: Float in [.nan, .infinity, -.infinity] {
            #expect(throws: MonophonicTranscriber.AnalysisError.nonfiniteSample(index: 1)) { try dsp.analyze(samples: [0, bad], sampleRate: 48_000) }
        }
        // Samples outside a requested region are deliberately not analyzed.
        #expect(try dsp.analyze(samples: [.nan, 0], sampleRate: 48_000, region: 1..<2).proposals.isEmpty)
    }

    @Test func signedAmplitudesDoNotChangePitch() throws {
        let samples = Self.pluck(rate: 44_100, midi: 45, amplitude: -0.3)
        let note = try #require(try MonophonicTranscriber().analyze(samples: samples, sampleRate: 44_100).proposals.filter { $0.qualified }.first)
        #expect(abs(try #require(note.midi) - 45) <= 1)
    }

    @Test func twoReattacksRemainSeparate() throws {
        let first = Self.pluck(rate: 48_000, midi: 52, onset: 0.1, duration: 1.2)
        let second = Self.pluck(rate: 48_000, midi: 64, onset: 0.7, duration: 1.2)
        let notes = try MonophonicTranscriber().analyze(samples: zip(first, second).map(+), sampleRate: 48_000).proposals.filter(\.qualified)
        #expect(notes.count == 2)
        #expect(notes.map(\.onset).enumerated().allSatisfy { abs($0.element - [0.1, 0.7][$0.offset]) <= 0.03 })
    }

    @Test func progressAndCancellationAreCooperativeWithoutPartialResult() throws {
        let samples = Self.pluck(rate: 48_000, midi: 40)
        var updates = [Double]()
        _ = try MonophonicTranscriber().analyze(samples: samples, sampleRate: 48_000, progress: { updates.append($0) })
        #expect(updates.first == 0 && updates.last == 1)
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $0 <= $1 })
        for stopAt in [0.01, 0.40, 0.51] {
            var latest = 0.0, checksAfterRequest = 0
            #expect(throws: MonophonicTranscriber.AnalysisError.cancelled) {
                try MonophonicTranscriber().analyze(samples: samples, sampleRate: 48_000, isCancelled: {
                    if latest >= stopAt { checksAfterRequest += 1; return true }; return false
                }, progress: { latest = $0 })
            }
            #expect(checksAfterRequest == 1)
            #expect(latest < 1)
        }
        // Mid-estimator cancellation (after preprocessing) is checked per lag.
        var checkpointCount = 0, inPitch = false
        #expect(throws: MonophonicTranscriber.AnalysisError.cancelled) {
            try MonophonicTranscriber().analyze(samples: samples, sampleRate: 48_000,
                isCancelled: { if inPitch { checkpointCount += 1 }; return checkpointCount == 12 },
                progress: { if $0 >= 0.5 { inPitch = true } })
        }
        #expect(checkpointCount == 12)
    }

    @Test func aperiodicAttackRemainsUnknown() throws {
        var state: UInt64 = 42
        let noise: [Float] = (0..<24_000).map { i in
            state = state &* 6364136223846793005 &+ 1
            return i < 4_800 ? 0 : Float(Double(state >> 32) / Double(UInt32.max) - 0.5) * 0.2
        }
        let result = try MonophonicTranscriber().analyze(samples: noise, sampleRate: 48_000)
        #expect(!result.proposals.isEmpty)
        #expect(result.proposals.allSatisfy { !$0.qualified && $0.midi == nil })
    }
}
