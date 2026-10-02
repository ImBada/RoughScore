import Foundation
import AVFoundation
import CryptoKit

/// Compiled together with MonophonicTranscriber.swift by the adjacent shell script.
@main
struct NativeMonoEvaluation {
    struct CLIError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    struct Fixture {
        let id: String, lane: String, origin: Double, url: URL
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("native-mono: \(error)\n".utf8))
            exit(2)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") {
            print("""
            Usage: run-native-mono-evaluation.sh --fixture ID left|right TIME_ORIGIN WAV_OR_CAF_PATH [--fixture ...] [--output JSON_PATH]
                   run-native-mono-evaluation.sh --benchmark [--output JSON_PATH]
            Explicit fixture paths only; mono uses its only channel, stereo selects L/R independently.
            For the PR25 evaluator use origin 0: references are local to each derived WAV.
            --benchmark generates a 30 s / 48 kHz harmonic-pluck buffer; it reads no audio.
            Output refuses to overwrite an input. Experimental advisory DSP, no trained weights.
            """)
            return
        }
        var fixtures = [Fixture](), output: URL?, benchmark = false, index = 0
        while index < args.count {
            switch args[index] {
            case "--fixture":
                guard index + 4 < args.count, ["left", "right"].contains(args[index + 2]),
                      let origin = Double(args[index + 3]), origin.isFinite, origin >= 0 else {
                    throw CLIError("--fixture needs ID left|right finite nonnegative origin path")
                }
                let url = URL(fileURLWithPath: args[index + 4]).standardizedFileURL.resolvingSymlinksInPath()
                guard ["wav", "caf"].contains(url.pathExtension.lowercased()) else { throw CLIError("explicit WAV/CAF only") }
                let id = args[index + 1]
                guard !id.isEmpty, !fixtures.contains(where: { $0.id == id }) else { throw CLIError("case IDs must be unique/nonempty") }
                fixtures.append(Fixture(id: id, lane: args[index + 2], origin: origin, url: url))
                index += 5
            case "--output":
                guard index + 1 < args.count, output == nil else { throw CLIError("--output needs one path") }
                output = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
                index += 2
            case "--benchmark": benchmark = true; index += 1
            default: throw CLIError("unknown argument \(args[index])")
            }
        }
        guard benchmark != !fixtures.isEmpty else { throw CLIError("choose fixtures or benchmark exclusively") }
        guard !fixtures.contains(where: { $0.url == output }) else { throw CLIError("output must not overwrite input") }
        let document: [String: Any]
        if benchmark {
            document = try runBenchmark()
        } else {
            let dsp = MonophonicTranscriber()
            var cases = [[String: Any]]()
            for fixture in fixtures {
                let inputHash = try digest(fixture.url)
                let audio = try AVAudioFile(forReading: fixture.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let format = audio.processingFormat
                guard (8_000...192_000).contains(format.sampleRate), audio.length > 0,
                      Double(audio.length) / format.sampleRate <= 60, (1...2).contains(format.channelCount),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length)) else {
                    throw CLIError("fixture must be nonempty mono/stereo, <=60 s, 8...192 kHz")
                }
                try audio.read(into: buffer)
                guard AVAudioFramePosition(buffer.frameLength) == audio.length, let channels = buffer.floatChannelData else {
                    throw CLIError("incomplete PCM decoding")
                }
                let channel = fixture.lane == "right" && format.channelCount == 2 ? 1 : 0
                let samples = Array(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
                let start = Date()
                let result = try dsp.analyze(samples: samples, sampleRate: format.sampleRate, timeOrigin: fixture.origin)
                let elapsed = Date().timeIntervalSince(start)
                guard try digest(fixture.url) == inputHash else { throw CLIError("fixture changed during inference") }
                let notes: [[String: Any]] = result.proposals.map { proposal in
                    ["onset": proposal.onset, "onset_is_region_boundary": proposal.onsetIsRegionBoundary, "end": proposal.audioEnd,
                     "midi": proposal.midi.map { Int($0.rounded()) } as Any? ?? NSNull(),
                     "measured_midi": proposal.midi as Any? ?? NSNull(),
                     "frequency_hz": proposal.frequencyHz as Any? ?? NSNull(),
                     "cents_from_nearest_semitone": proposal.centsFromNearestSemitone as Any? ?? NSNull(),
                     "lane": fixture.lane, "qualified": proposal.qualified, "periodicity": proposal.periodicity,
                     "unknown_reason": proposal.unknownReason?.rawValue as Any? ?? NSNull(),
                     "reaches_region_end": proposal.reachesRegionEnd]
                }
                cases.append(["id": fixture.id, "input_sha256": inputHash, "notes": notes,
                              "input_path": fixture.url.path, "time_origin": fixture.origin,
                              "sample_rate": format.sampleRate, "selected_channel_index": channel,
                              "elapsed_seconds": elapsed, "audio_end_semantics": "observed amplitude support; not annotated offset or rhythm"])
            }
            let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/RoughScoreCore/MonophonicTranscriber.swift")
            document = ["schema_version": 1,
                        "engine": ["id": "roughscore-native-mono", "version": MonophonicTranscriber.version,
                                   "source_sha256": try digest(core), "cli_source_sha256": try digest(URL(fileURLWithPath: #filePath)),
                                   "qualified_rule": MonophonicTranscriber.qualifiedRule,
                                   "settings": ["minimum_rms": dsp.settings.minimumRMS, "attack_ratio": dsp.settings.attackRatio,
                                                "onset_block_seconds": 0.004, "refractory_seconds": 0.08,
                                                "pitch_range_hz": [65, 1400], "yin_threshold": 0.10,
                                                "pitch_frame_seconds": 0.05, "post_attack_delays_seconds": [0.020, 0.040, 0.060]],
                                   "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "model_weights": "none", "scope": "experimental clean monophonic only"], "cases": cases]
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) + Data([10])
        if let output { try data.write(to: output, options: .atomic) }
        else { FileHandle.standardOutput.write(data) }
    }

    static func runBenchmark() throws -> [String: Any] {
        let rate = 48_000.0, duration = 30.0
        var samples = [Float](repeating: 0, count: Int(rate * duration))
        let pitches = [40.0, 45, 52, 59, 64, 76, 88]
        for note in 0..<60 {
            let midi = pitches[note % pitches.count], frequency = 440 * pow(2, (midi - 69) / 12)
            let first = Int((Double(note) * 0.5 + 0.1) * rate)
            for j in 0..<Int(0.38 * rate) {
                let t = Double(j) / rate, attack = min(1, t / 0.003)
                var value = 0.0
                for harmonic in 1...7 {
                    let strength = harmonic == 1 ? 0.25 : (harmonic == 2 ? 1 : 0.8 / Double(harmonic))
                    value += strength * exp(-t * (3 + Double(harmonic))) * sin(2 * .pi * frequency * Double(harmonic) * t + Double(harmonic) * 0.37)
                }
                samples[first + j] = Float(0.5 * attack * value)
            }
        }
        let start = Date()
        let result = try MonophonicTranscriber().analyze(samples: samples, sampleRate: rate)
        let elapsed = Date().timeIntervalSince(start)
        let notes = result.proposals.filter(\.qualified)
        let correct = notes.enumerated().filter { i, note in
            i < 60 && abs(note.onset - (Double(i) * 0.5 + 0.1)) <= 0.03 && abs((note.midi ?? -1000) - pitches[i % pitches.count]) <= 1
        }.count
        var lastProgress = 0.0, pitchChecks = 0
        var cancelRequestedAt: Date?, cancellationObserved = false
        let cancellationStart = Date()
        do {
            _ = try MonophonicTranscriber().analyze(samples: samples, sampleRate: rate,
                isCancelled: {
                    if lastProgress >= 0.5 { pitchChecks += 1 }
                    if pitchChecks == 12 { cancelRequestedAt = Date(); return true }
                    return false
                }, progress: { lastProgress = $0 })
        } catch MonophonicTranscriber.AnalysisError.cancelled {
            cancellationObserved = true
        }
        let cancellationLatency = cancelRequestedAt.map { Date().timeIntervalSince($0) }
        return ["schema_version": 1, "benchmark": "generated analytic harmonic plucks; no real-guitar accuracy claim",
                "engine_version": MonophonicTranscriber.version, "seconds": duration, "sample_rate": rate,
                "input_float_bytes": samples.count * MemoryLayout<Float>.size, "elapsed_analysis_seconds": elapsed,
                "expected_notes": 60, "proposals": result.proposals.count, "qualified_notes": notes.count,
                "qualified_correct_within_30ms_and_1_semitone": correct,
                "cancellation": ["observed_throw": cancellationObserved, "returned_partial_result": false,
                                 "checkpoints_into_pitch_stage": pitchChecks, "last_progress": lastProgress,
                                 "seconds_from_request_to_throw": cancellationLatency as Any? ?? NSNull(),
                                 "elapsed_cancelled_analysis_seconds": Date().timeIntervalSince(cancellationStart)],
                "host": ProcessInfo.processInfo.operatingSystemVersionString,
                "cpu_count": ProcessInfo.processInfo.processorCount,
                "memory_measurement": "Use /usr/bin/time -l on this executable after compilation for peak process RSS including generated buffer/runtime."]
    }
}
