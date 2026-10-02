import Foundation

/// Experimental, offline clean-monophonic DSP. No trained model, musical rhythm,
/// fingering, lane assignment or confirmed TAB is created. Run off the UI actor.
public struct MonophonicTranscriber: Sendable {
    public static let version = "native-mono-1"
    public static let qualifiedRule = "At least two of three post-attack YIN frames pass the first-trough CMNDF <= 0.10 rule (periodicity >= 0.90), RMS >= minimumRMS and MIDI spread <= 0.35 semitones; geometric mean measured frequency is in 65...1400 Hz. This is a deterministic signal rule, not a probability or proof of monophony."

    public struct Settings: Sendable, Equatable {
        /// Normalized PCM amplitude; a sensitivity setting, not a noise estimator.
        public var minimumRMS: Double
        public var attackRatio: Double
        public init(minimumRMS: Double = 0.003, attackRatio: Double = 1.7) {
            self.minimumRMS = minimumRMS
            self.attackRatio = attackRatio
        }
    }

    public enum AnalysisError: Error, Equatable {
        case invalidSampleRate, invalidTimeOrigin, invalidRegion, regionTooLong
        case invalidSettings, nonfiniteSample(index: Int), cancelled
    }

    public enum UnknownReason: String, Sendable, Codable {
        case insufficientAudio, aperiodicOrUnstable
    }

    public struct Proposal: Sendable, Equatable {
        /// Seconds on the original recording, never rounded or quantized.
        public let onset: Double
        /// Activity already at the crop boundary has no recoverable earlier attack.
        public let onsetIsRegionBoundary: Bool
        /// Observed amplitude support, clipped at the next attack/region boundary;
        /// neither an annotated note offset nor a musical NoteLength.
        public let audioEnd: Double
        public let reachesRegionEnd: Bool
        public let frequencyHz: Double?
        /// Continuous MIDI derived from measured Hz, not an assigned semitone.
        public let midi: Double?
        public let centsFromNearestSemitone: Double?
        public let periodicity: Double
        public let qualified: Bool
        public let unknownReason: UnknownReason?
    }

    public struct Result: Sendable {
        public let proposals: [Proposal]
        public let analyzedOriginalRange: Range<Double>
        public let settings: Settings
        public let version: String
    }

    public let settings: Settings
    public init(settings: Settings = Settings()) { self.settings = settings }

    /// `timeOrigin` is the original time of samples[0]. `region` is a half-open
    /// sample-index range in that buffer. Call separately for L and R; no mixing.
    /// Empty/short valid regions succeed (attacks may have explicitly unknown pitch).
    /// Invalid input and cancellation throw; no partial/stale result is returned.
    /// Progress is synchronous, monotonic 0...1, and reaches 1 only on success.
    /// Cancellation is checked every <=4 ms input block and every YIN lag.
    /// Only the selected samples are inspected. Regions are limited to 60 seconds,
    /// rates to 8...192 kHz; arbitrary finite signed PCM amplitudes are supported.
    public func analyze(samples: [Float], sampleRate: Double, timeOrigin: Double = 0,
                        region: Range<Int>? = nil,
                        isCancelled: () -> Bool = { false },
                        progress: (Double) -> Void = { _ in }) throws -> Result {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw AnalysisError.invalidSampleRate
        }
        guard timeOrigin.isFinite, timeOrigin >= 0 else { throw AnalysisError.invalidTimeOrigin }
        guard settings.minimumRMS.isFinite, settings.minimumRMS > 0,
              settings.attackRatio.isFinite, settings.attackRatio > 1 else { throw AnalysisError.invalidSettings }
        let selected = region ?? 0..<samples.count
        guard selected.lowerBound >= 0, selected.upperBound <= samples.count else { throw AnalysisError.invalidRegion }
        let duration = Double(selected.count) / sampleRate
        guard duration <= 60 else { throw AnalysisError.regionTooLong }
        let origin = timeOrigin + Double(selected.lowerBound) / sampleRate
        let endTime = origin + duration
        // At very large timestamps sub-sample precision is unrepresentable.
        guard origin.isFinite, endTime.isFinite, origin.ulp <= 1 / sampleRate else {
            throw AnalysisError.invalidTimeOrigin
        }
        func checkpoint() throws { if isCancelled() { throw AnalysisError.cancelled } }
        try checkpoint()
        progress(0)
        let blockSize = max(1, Int(sampleRate * 0.004))
        let stride = max(1, Int(sampleRate / 16_000))
        let pitchRate = sampleRate / Double(stride)
        var envelope = [Double]()
        var reduced = [Double]()
        envelope.reserveCapacity((selected.count + blockSize - 1) / blockSize)
        reduced.reserveCapacity(selected.count / stride)
        var previousInput = 0.0, highpassed = 0.0, sum = 0.0, sumCount = 0
        // One-pole DC blocker plus boxcar before decimation. This inexpensive
        // prefilter is not a steep anti-alias filter: bright/noisy audio is limited.
        let pole = exp(-2 * .pi * 20 / sampleRate)
        var cursor = selected.lowerBound
        while cursor < selected.upperBound {
            try checkpoint()
            let upper = min(cursor + blockSize, selected.upperBound)
            var energy = 0.0
            for index in cursor..<upper {
                let value = Double(samples[index])
                guard value.isFinite else { throw AnalysisError.nonfiniteSample(index: index) }
                highpassed = value - previousInput + pole * highpassed
                previousInput = value
                energy += highpassed * highpassed
                sum += highpassed
                sumCount += 1
                if sumCount == stride {
                    reduced.append(sum / Double(stride))
                    sum = 0; sumCount = 0
                }
            }
            envelope.append(sqrt(energy / Double(upper - cursor)))
            cursor = upper
            progress(0.35 * Double(cursor - selected.lowerBound) / Double(selected.count))
        }
        let blockSeconds = Double(blockSize) / sampleRate
        var attacks = [Int]()
        // A local rise with an absolute floor and 80 ms refractory period.
        // Search back to the beginning of the rising edge, rather than its peak.
        for i in envelope.indices {
            try checkpoint()
            let value = envelope[i]
            let baselineStart = max(0, i - 5)
            let baseline = i == 0 ? 0 : envelope[baselineStart..<i].reduce(0, +) / Double(i - baselineStart)
            let preceding = i == 0 ? 0 : envelope[i - 1]
            if value >= settings.minimumRMS, value > baseline * settings.attackRatio,
               value > preceding * 1.12 {
                var attack = i
                while attack > max(0, i - 3), envelope[attack - 1] > settings.minimumRMS * 0.5,
                      envelope[attack - 1] < envelope[attack] * 0.8 { attack -= 1 }
                if attacks.last.map({ Double(attack - $0) * blockSeconds >= 0.08 }) ?? true {
                    attacks.append(attack)
                }
            }
            progress(0.35 + 0.15 * Double(i + 1) / Double(max(1, envelope.count)))
        }
        var proposals = [Proposal]()
        for (number, attack) in attacks.enumerated() {
            try checkpoint()
            let onsetRelative = Double(attack) * blockSeconds
            let nextAttack = number + 1 < attacks.count ? attacks[number + 1] : envelope.count
            let availableEnd = min(duration, Double(nextAttack) * blockSeconds)
            var estimates = [(hz: Double, score: Double)]()
            // Avoid the broadband pluck transient; require agreement across frames.
            let frameLength = Int(pitchRate * 0.050)
            for delay in [0.020, 0.040, 0.060] {
                let start = Int((onsetRelative + delay) * pitchRate)
                if onsetRelative + delay + 0.050 <= availableEnd,
                   start + frameLength <= reduced.count,
                   let estimate = try pitch(reduced, start: start, count: frameLength,
                                            rate: pitchRate, checkpoint: checkpoint) {
                    estimates.append(estimate)
                }
            }
            let ordered = estimates.sorted { $0.hz < $1.hz }
            // A transient-corrupted frame must not veto two agreeing frames.
            // Choose the closest adjacent pair; deterministic tie goes to lower Hz.
            var consensus = [(hz: Double, score: Double)]()
            var bestSpread = Double.infinity
            if ordered.count >= 2 {
                for i in 1..<ordered.count {
                    let spread = 12 * log2(ordered[i].hz / ordered[i - 1].hz)
                    if spread < bestSpread {
                        bestSpread = spread
                        consensus = [ordered[i - 1], ordered[i]]
                    }
                }
            }
            let qualified = consensus.count == 2 && bestSpread <= 0.35
            let hz = qualified ? sqrt(consensus[0].hz * consensus[1].hz) : nil
            let midi = hz.map { 69 + 12 * log2($0 / 440) }
            var endBlock = attack + 1
            let peak = envelope[attack..<min(nextAttack, attack + 8)].max() ?? 0
            let supportFloor = max(settings.minimumRMS, peak * 0.1)
            while endBlock < nextAttack {
                try checkpoint()
                // Two quiet blocks avoid ending at a waveform beat/local dip.
                if envelope[endBlock] < supportFloor,
                   endBlock + 1 < nextAttack, envelope[endBlock + 1] < supportFloor { break }
                endBlock += 1
            }
            let supportEnd = min(availableEnd, Double(endBlock) * blockSeconds)
            proposals.append(Proposal(onset: origin + onsetRelative, onsetIsRegionBoundary: attack == 0,
                audioEnd: origin + supportEnd, reachesRegionEnd: endBlock >= envelope.count,
                frequencyHz: hz, midi: midi, centsFromNearestSemitone: midi.map { ($0 - $0.rounded()) * 100 },
                periodicity: (qualified ? consensus : ordered).map(\.score).min() ?? 0, qualified: qualified,
                unknownReason: qualified ? nil : (availableEnd - onsetRelative < 0.090 ? .insufficientAudio : .aperiodicOrUnstable)))
            progress(0.5 + 0.45 * Double(number + 1) / Double(attacks.count))
        }
        try checkpoint()
        progress(1)
        return Result(proposals: proposals, analyzedOriginalRange: origin..<endTime,
                      settings: settings, version: Self.version)
    }

    /// YIN steps 2–5: fixed-window squared difference, cumulative-mean
    /// normalization, first threshold trough, parabolic sub-sample refinement.
    private func pitch(_ samples: [Double], start: Int, count: Int, rate: Double,
                       checkpoint: () throws -> Void) throws -> (hz: Double, score: Double)? {
        let maximumLag = Int(ceil(rate / 65))
        let minimumLag = max(2, Int(floor(rate / 1400)))
        let window = count - maximumLag - 1
        guard window > maximumLag else { return nil }
        let rms = sqrt(samples[start..<start + window].reduce(0) { $0 + $1 * $1 } / Double(window))
        guard rms >= settings.minimumRMS else { return nil }
        var normalized = [Double](repeating: 1, count: maximumLag + 1)
        var cumulative = 0.0
        for lag in 1...maximumLag {
            try checkpoint()
            var difference = 0.0
            for j in 0..<window {
                let delta = samples[start + j] - samples[start + j + lag]
                difference += delta * delta
            }
            cumulative += difference
            normalized[lag] = cumulative > 0 ? difference * Double(lag) / cumulative : 1
        }
        var lag = minimumLag
        while lag < maximumLag {
            if normalized[lag] <= 0.10 {
                while lag + 1 < maximumLag, normalized[lag + 1] < normalized[lag] { lag += 1 }
                let left = normalized[lag - 1], center = normalized[lag], right = normalized[lag + 1]
                let denominator = left - 2 * center + right
                let correction = denominator > 0 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
                let hz = rate / (Double(lag) + correction)
                guard (65...1400).contains(hz), hz.isFinite else { return nil }
                return (hz, max(0, min(1, 1 - center)))
            }
            lag += 1
        }
        return nil
    }
}
