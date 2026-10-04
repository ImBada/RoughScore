import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor
@Suite(.serialized)
struct StemWorkspaceTests {
    private func services(capture: StemCapture? = nil) -> WorkspaceServices {
        var services = WorkspaceServices.live
        services.lastProject = { nil }; services.rememberProject = { _ in }; services.chooseSaveDestination = { _ in nil }
        let make = services.makePlayer
        services.makePlayer = { url in
            let p = try #require(make(url) as? AudioEnginePlayer)
            p.graph.engine.mainMixerNode.outputVolume = 0
            capture?.players[url] = p
            return p
        }
        return services
    }
    private func fixture(duration: Double = 3, padding: Double = 0, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-stem-test-" + UUID().uuidString + ".caf")
        let rate = 44100.0, frames = Int((duration + padding) * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(channels) {
            buffer.floatChannelData![c].initialize(repeating: 0, count: frames)
            let attack = Int((0.75 + padding + Double(c) * 0.08) * rate)
            if attack < frames {
                buffer.floatChannelData![c][attack] = c == 0 ? 0.9 : -0.7
                for i in 1..<min(10000, frames - attack) {
                    buffer.floatChannelData![c][attack + i] = Float(0.22 * sin(2 * .pi * 220 * Double(i) / rate) * exp(-Double(i) / 1800))
                }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer); file.close()
        return url
    }
    private func events() -> [TabEvent] {
        [TabEvent(time: 0.713001, lane: .left, string: 6, memo: "unknown · 한글\nline"),
         TabEvent(time: 1.213004, lane: .right, string: 2, fret: 12, length: .eighth, tentative: true, memo: "manual"),
         TabEvent(time: 1.213004, lane: .right, string: 2, fret: 0, memo: "coincident")]
    }

    @Test func realAttachSixChoicesSaveReopenPreserveEveryManualFieldAndTuning() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        let save = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".roughscore")
        defer { for url in [original, stem, save] { try? FileManager.default.removeItem(at: url) } }
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        let notes = events(); w.project.events = notes; w.project.tuningDefinition = TuningDefinition(openMIDIPitches: [64,59,55,50,45,38], capo: 2)
        let tuning = w.project.tuningDefinition
        w.select(notes[1]); w.toggleSelection(notes[2]); let selected = w.selectedIDs
        #expect(w.save(to: save)); let originalDuration = w.project.duration
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        #expect(w.project.events == notes && w.project.duration == originalDuration && w.selectedIDs == selected)
        #expect(w.dirty && w.project.tuningDefinition == tuning)
        for role in [AudioAsset.Role.importedGuitarStem, .original] {
            #expect(w.switchAsset(role))
            for channel in ListeningSource.allCases { w.switchSource(channel); #expect(w.project.events == notes) }
        }
        #expect(w.save(to: save) && !w.dirty)
        let disk = try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: save)).validated()
        #expect(disk.events == notes && disk.tuningDefinition == tuning && disk.stemAsset?.originalTimeOffset == -0.25)
        let reopened = Workspace(services: services()); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: save)?.value == true)
        #expect(reopened.project == disk && !reopened.dirty && reopened.switchAsset(.importedGuitarStem))
        #expect(reopened.project.events == notes && reopened.prepared?.isMono == false)
        reopened.detachStem()
        #expect(reopened.project.events == notes && reopened.project.duration == originalDuration)
        #expect(FileManager.default.fileExists(atPath: original.path) && FileManager.default.fileExists(atPath: stem.path))
    }

    @Test func realPaddedImpulseWaveformsAnalysisAndPitchCandidatesUseOriginalSeconds() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        var service = services()
        // This analyzer observes the ACTUAL selected audition file, not a synthetic summary timestamp.
        service.analyze = { url, duration in
            let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buffer)
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let attack = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
            let time = Double(attack) / f.processingFormat.sampleRate
            return AnalysisSummary(beats: [time], bars: [time], sections: [TimeSpan(start: time, end: min(duration, time + 0.5))])
        }
        let w = Workspace(services: service); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); let notes = w.project.events
        #expect(await w.attachStem(at: stem)?.value == true && w.switchAsset(.importedGuitarStem))
        #expect(WaveformEnvelope.peak(w.prepared!.leftPeaks, duration: w.project.duration, from: 0.745, to: 0.755) == 0)
        #expect(await w.setStemOffset(-0.25)?.value == true && w.switchAsset(.importedGuitarStem))
        let a = try #require(w.prepared)
        #expect(WaveformEnvelope.peak(a.leftPeaks, duration: w.project.duration, from: 0.745, to: 0.755) > 0.8)
        #expect(WaveformEnvelope.peak(a.rightPeaks, duration: w.project.duration, from: 0.825, to: 0.835) > 0.6)
        w.switchSource(.left); await w.analyze()?.value
        #expect(abs(try #require(w.summary?.bars.first) - 0.75) < 1 / 44100)
        #expect(w.summary?.provenance?.assetID == w.project.stemAsset?.id)
        await w.proposePitches(from: 0.5, to: 1.5)?.value
        #expect(abs(try #require(w.pitchProposals.first?.onset) - 0.75) < 0.02)
        #expect(w.project.events == notes)
        // Offset is one undo transaction; note UUIDs, selection and saved metadata remain independent.
        w.undoEdit()
        #expect(w.project.stemAsset?.originalTimeOffset == 0 && w.project.events == notes)
        w.redoEdit()
        #expect(w.project.stemAsset?.originalTimeOffset == -0.25 && w.project.events == notes)
    }

    @Test func sixActualNativeGroupsAndFrameClocksAtAllThreeRates() async throws {
        let original = try fixture(duration: 5), stem = try fixture(duration: 2, padding: 0.25)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        let capture = StemCapture(), w = Workspace(services: services(capture: capture)); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        let duration = w.project.duration
        for rate: Float in [0.5, 0.75, 1] {
            w.rate = rate; #expect(w.switchAsset(.original)); w.seek(0.5); w.togglePlayback()
            try await Task.sleep(for: .milliseconds(90))
            for role in [AudioAsset.Role.original, .importedGuitarStem, .original, .importedGuitarStem] {
                let before = w.cursor
                #expect(w.switchAsset(role))
                for channel in ListeningSource.allCases {
                    w.switchSource(channel); w.tick()
                    let p = try #require(capture.players[w.prepared!.url(for: channel)])
                    #expect(w.playing && w.cursor >= before && w.cursor < duration)
                    try await Task.sleep(for: .milliseconds(35))
                    let clock = try #require(p.graph.inputClockSnapshot())
                    #expect(clock.playerFrames.count == 3)
                    #expect(clock.playerFrames.values.max()! - clock.playerFrames.values.min()! <= 1)
                    #expect(abs(p.currentTime - w.cursor) < 0.1)
                    #expect(p.graph.nativeGains[channel] == 1)
                    print("Stem native role=\(role) channel=\(channel) rate=\(rate) originalTime=\(p.currentTime) frames=\(clock.playerFrames)")
                }
            }
            w.seek(4); w.tick() // Beyond short stem EOF: actual padded silent file keeps the original clock.
            #expect(w.playing && w.cursor >= 4 && w.project.duration == duration)
            w.togglePlayback(); #expect(!w.playing && w.cursor >= 4)
            w.looping = true; w.loopStart = 0.5; w.loopEnd = 0.6; w.seek(0.5); w.togglePlayback()
            try await Task.sleep(for: .milliseconds(260)); w.tick()
            #expect(w.playing && w.cursor >= 0.5 && w.cursor < 0.7)
            w.togglePlayback(); w.looping = false
        }
        #expect(capture.players.count == 6)
    }

    @Test(arguments: [0.25, -0.25, 5.0, -5.0])
    func croppedMonoAndEmptyWindowsHaveExplicitSilenceAndPreserveOriginalBounds(offset: Double) async throws {
        let original = try fixture(), stem = try fixture(duration: 1, channels: 1)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); let notes = w.project.events
        #expect(await w.attachStem(at: stem, offset: offset)?.value == true && w.switchAsset(.importedGuitarStem))
        let audio = try #require(w.prepared), mapping = try #require(audio.mapping)
        #expect(audio.isMono && w.stemConnection.contains("모노") && w.stemConnection.contains("복제"))
        #expect(audio.leftPeaks == audio.rightPeaks && audio.duration == 3 && w.project.events == notes)
        let file = try AVAudioFile(forReading: audio.url(for: .stereo))
        #expect(file.length == 132300 && file.processingFormat.channelCount == 2)
        if abs(offset) > 3 { #expect(mapping.validOriginalWindow.start == mapping.validOriginalWindow.end && audio.leftPeaks.allSatisfy { $0 == 0 }) }
        else { #expect(WaveformEnvelope.peak(audio.leftPeaks, duration: 3, from: 0.745 + offset, to: 0.755 + offset) > 0.8) }
        #expect(w.project.duration == 3 && w.project.events.allSatisfy { $0.time < 3 })
    }

    @Test func missingAndCorruptStemLeaveOriginalTabAndRepairInvalidateOnlyStemProvenance() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        let save = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".roughscore")
        defer { for u in [original, stem, save] { try? FileManager.default.removeItem(at: u) } }
        var service = services(); service.analyze = { _, _ in AnalysisSummary(beats: [0.75], bars: [0.75]) }
        let w = Workspace(services: service); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); await w.analyze()?.value
        let originalSummary = w.summary
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true && w.switchAsset(.importedGuitarStem))
        await w.analyze()?.value; #expect(w.save(to: save))
        let snapshot = w.project, bytes = try Data(contentsOf: stem)
        try FileManager.default.removeItem(at: stem)
        let reopened = Workspace(services: services()); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: save)?.value == true)
        #expect(reopened.project.events == snapshot.events && reopened.prepared != nil && !reopened.switchAsset(.importedGuitarStem))
        #expect(reopened.stemConnection.contains("다시 연결") && reopened.project.analyses["stereo"] == originalSummary)
        reopened.select(reopened.project.events[0]); reopened.updateSelected { $0.memo = "offline stem repair" }
        try bytes.write(to: stem)
        #expect(await reopened.attachStem(at: stem, offset: -0.25)?.value == true)
        #expect(reopened.project.analyses.count == snapshot.analyses.count)
        try Data("corrupt replacement".utf8).write(to: stem)
        #expect(reopened.save(to: save))
        let corrupt = Workspace(services: services()); defer { corrupt.shutdown() }
        #expect(await corrupt.loadProject(at: save)?.value == true)
        #expect(corrupt.prepared != nil && corrupt.project.events == reopened.project.events)
        #expect(corrupt.project.stemAsset?.identity == nil && corrupt.project.analyses.count == 1)
        #expect(corrupt.project.analyses["stereo"] == originalSummary)
    }
}

@MainActor private final class StemCapture { var players: [URL: AudioEnginePlayer] = [:] }
