import Accelerate
import Foundation

/// A simultaneous-note candidate from a polyphonic pitch model, for review only.
/// It never replaces confirmed TAB, and `amplitude` is not a calibrated probability.
public struct PolyNoteCandidate: Sendable, Equatable {
    /// Seconds on the original recording, never rounded or quantized.
    public let onset: Double
    public let end: Double
    public let midi: Int
    /// Mean model note activation (0...1) between onset and end.
    public let amplitude: Double
    /// Contour peak offset from `midi` in semitones (1/3 semitone steps), one value per model
    /// frame (about 11.6 ms) from the onset. Notes sounding together share one contour, so a
    /// chord tone can pull this; treat it as a bend/slide hint only.
    public let pitchBend: [Double]

    public init(onset: Double, end: Double, midi: Int, amplitude: Double, pitchBend: [Double]) {
        self.onset = onset
        self.end = end
        self.midi = midi
        self.amplitude = amplitude
        self.pitchBend = pitchBend
    }
}

/// Port of Basic Pitch's default note decoding (`output_to_notes_polyphonic` and
/// `get_pitch_bends`, spotify/basic-pitch v0.4.0). Pure; no model or audio here.
public enum BasicPitchDecoder {
    public static let noteBins = 88
    public static let contourBins = 264
    public static let lowestMIDI = 21

    public struct Settings: Sendable, Equatable {
        public var onsetThreshold: Float
        public var frameThreshold: Float
        /// Notes must be longer than this many frames (Basic Pitch's 127.7 ms default).
        public var minimumNoteFrames: Int
        public var inferOnsets: Bool
        public var melodiaTrick: Bool
        public init(onsetThreshold: Float = 0.5, frameThreshold: Float = 0.3, minimumNoteFrames: Int = 11,
                    inferOnsets: Bool = true, melodiaTrick: Bool = true) {
            self.onsetThreshold = onsetThreshold
            self.frameThreshold = frameThreshold
            self.minimumNoteFrames = minimumNoteFrames
            self.inferOnsets = inferOnsets
            self.melodiaTrick = melodiaTrick
        }
    }

    /// Row-major `[frame][bin]` model outputs and the original time of every frame.
    public struct Activations: Sendable {
        public var note: [Float] = []
        public var onset: [Float] = []
        public var contour: [Float] = []
        public var frameTimes: [Double] = []
        public init() {}
    }

    /// Frames a note may stay below `frameThreshold` before it ends.
    static let energyTolerance = 11

    public static func decode(_ activations: Activations, settings: Settings = Settings(),
                              isCancelled: () -> Bool = { false }) throws -> [PolyNoteCandidate] {
        let n = activations.frameTimes.count, bins = noteBins
        precondition(activations.note.count == n * bins && activations.onset.count == n * bins
                     && activations.contour.count == n * contourBins)
        let frames = activations.note
        let threshold = settings.frameThreshold
        var onsets = activations.onset
        if settings.inferOnsets, n > 2 {
            // Add onsets where the note activation rises over both 1 and 2 frames,
            // rescaled to the largest predicted onset.
            var rise = [Float](repeating: 0, count: n * bins)
            for t in 2..<n {
                for f in 0..<bins {
                    let value = frames[t * bins + f]
                    rise[t * bins + f] = max(0, min(value - frames[(t - 1) * bins + f], value - frames[(t - 2) * bins + f]))
                }
            }
            let largestRise = vDSP.maximum(rise)
            if largestRise > 0 {
                let scale = vDSP.maximum(onsets) / largestRise
                for index in onsets.indices { onsets[index] = max(onsets[index], rise[index] * scale) }
            }
        }

        var remaining = frames
        func clear(_ t: Int, _ f: Int) {
            remaining[t * bins + f] = 0
            if f < bins - 1 { remaining[t * bins + f + 1] = 0 }
            if f > 0 { remaining[t * bins + f - 1] = 0 }
        }
        var notes: [(start: Int, end: Int, bin: Int)] = []
        // Strict local maxima in time above the onset threshold, latest first.
        var peaks: [(t: Int, f: Int)] = []
        if n > 2 {
            for t in 1..<(n - 1) {
                for f in 0..<bins {
                    let value = onsets[t * bins + f]
                    if value >= settings.onsetThreshold, value > onsets[(t - 1) * bins + f], value > onsets[(t + 1) * bins + f] {
                        peaks.append((t, f))
                    }
                }
            }
        }
        for (start, f) in peaks.reversed() {
            if isCancelled() { throw CancellationError() }
            var i = start + 1, below = 0
            while i < n - 1 && below < energyTolerance {
                below = remaining[i * bins + f] < threshold ? below + 1 : 0
                i += 1
            }
            i -= below
            if i - start <= settings.minimumNoteFrames { continue }
            for t in start..<i { clear(t, f) }
            notes.append((start, i, f))
        }

        // "Melodia trick": grow notes from the strongest leftover activation in both directions.
        while settings.melodiaTrick, !remaining.isEmpty {
            if isCancelled() { throw CancellationError() }
            let (peak, value) = vDSP.indexOfMaximum(remaining)
            guard value > threshold else { break }
            let middle = Int(peak) / bins, f = Int(peak) % bins
            remaining[Int(peak)] = 0
            var i = middle + 1, below = 0
            while i < n - 1 && below < energyTolerance {
                below = remaining[i * bins + f] < threshold ? below + 1 : 0
                clear(i, f)
                i += 1
            }
            let end = i - 1 - below
            i = middle - 1; below = 0
            while i > 0 && below < energyTolerance {
                below = remaining[i * bins + f] < threshold ? below + 1 : 0
                clear(i, f)
                i -= 1
            }
            let start = i + 1 + below
            if end - start <= settings.minimumNoteFrames { continue }
            notes.append((start, end, f))
        }

        return notes.map { note in
            let amplitude = (note.start..<note.end).reduce(0.0) { $0 + Double(frames[$1 * bins + note.bin]) }
                / Double(note.end - note.start)
            return PolyNoteCandidate(onset: activations.frameTimes[note.start], end: activations.frameTimes[note.end],
                                     midi: note.bin + lowestMIDI, amplitude: amplitude,
                                     pitchBend: pitchBend(activations.contour, bin: note.bin, frames: note.start..<note.end))
        }.sorted { ($0.onset, $0.midi) < ($1.onset, $1.midi) }
    }

    /// Gaussian-weighted (std 5 bins) contour argmax within +/-25 bins of the note, per frame.
    /// Contour bin 3f + 1 is the middle of semitone f (constants.py); the reference centres on
    /// 3f and so reports in-tune notes as +1/3 semitone. We centre on the middle bin.
    static func pitchBend(_ contour: [Float], bin: Int, frames: Range<Int>) -> [Double] {
        let center = 3 * bin + 1, tolerance = 25
        let bins = max(0, center - tolerance)...min(contourBins - 1, center + tolerance)
        return frames.map { t in
            // Ties (e.g. an all-zero row) keep the note's own bin.
            var best = center, bestValue = contour[t * contourBins + center]
            for c in bins {
                let offset = Float(c - center) / 5
                let value = contour[t * contourBins + c] * exp(-0.5 * offset * offset)
                if value > bestValue { best = c; bestValue = value }
            }
            return Double(best - center) / 3
        }
    }
}
