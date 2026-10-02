import RoughScoreCore
import Testing

struct WaveformEnvelopeTests {
    @Test func rangeRetainsBriefAttacksBetweenDisplaySamples() {
        let peaks: [Float] = [0, 0, 0, -0.9, 0, 0, 0, 0]
        #expect(WaveformEnvelope.peak(peaks, duration: 8, from: 2.1, to: 5.9) == 0.9)
        #expect(WaveformEnvelope.peak(peaks, duration: 8, from: 0, to: 3) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 8, from: 4, to: 8) == 0)
    }

    @Test func halfOpenRangesExcludeAttacksAtTheEndBoundary() {
        let peaks: [Float] = [0.2, 0.8, 0.4, 1]
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 0, to: 1) == 0.2)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 1, to: 2) == 0.8)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 0.9, to: 1.1) == 0.8)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 3.5, to: 4) == 1)
    }

    @Test func rangesClampToAudioAndRejectInvalidInputs() {
        let peaks: [Float] = [0.2, 0, 0, 0.7]
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: -3, to: 0.5) == 0.2)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 3.5, to: 20) == 0.7)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: -3, to: -1) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 4, to: 5) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 2, to: 2) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 3, to: 1) == 0)
        #expect(WaveformEnvelope.peak([], duration: 4, from: 0, to: 4) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 0, from: 0, to: 4) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: .infinity, from: 0, to: 4) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: .nan, from: 0, to: 4) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: .nan, to: 4) == 0)
        #expect(WaveformEnvelope.peak(peaks, duration: 4, from: 0, to: .infinity) == 0)
    }

    @Test func variableTempoWaveformAndTabShareTheSamePosition() throws {
        let row = try #require(ScoreLayout(duration: 5, bars: [0, 1, 4, 4.5]).systems.first)
        let event = TabEvent(time: 2.5, lane: .left, string: 1)
        let fraction = row.fraction(at: event.time)
        #expect(abs(fraction - 0.375) < 0.00001)

        var peaks = [Float](repeating: 0, count: 500)
        peaks[250] = 0.9 // A short attack 2.5 seconds into the audio.
        let start = row.time(at: fraction - 0.01)
        let end = row.time(at: fraction + 0.01)
        #expect(WaveformEnvelope.peak(peaks, duration: 5, from: start, to: end) == 0.9)
        #expect(WaveformEnvelope.peak(peaks, duration: 5,
                                     from: row.time(at: fraction + 0.02),
                                     to: row.time(at: fraction + 0.03)) == 0)
        // The equal-width bars stretch the long middle measure; a linear whole-row
        // time axis would place this attack at a different TAB position.
        let linearStart = (fraction - 0.01) * 5
        let linearEnd = (fraction + 0.01) * 5
        #expect(abs(start - linearStart) > 0.4)
        #expect(WaveformEnvelope.peak(peaks, duration: 5, from: linearStart, to: linearEnd) == 0)
    }

    @Test func malformedPeakSamplesDoNotContaminateTheEnvelope() {
        #expect(WaveformEnvelope.peak([.nan, .infinity, -0.6], duration: 3, from: 0, to: 3) == 0.6)
    }
}
