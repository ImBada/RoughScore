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
        let stereoFile = try AVAudioFile(forReading: a.url(for: .stereo), commonFormat: .pcmFormatFloat32, interleaved: false)
        let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereoFile.processingFormat, frameCapacity: AVAudioFrameCount(stereoFile.length))!
        try stereoFile.read(into: stereoBuffer)
        #expect(stereoFile.processingFormat.channelCount == 2)
        #expect(abs(stereoBuffer.floatChannelData![0][33075] - 0.9) < 0.0001)
        #expect(abs(stereoBuffer.floatChannelData![1][36603] + 0.7) < 0.0001)
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
                    let deviceBefore = p.deviceCurrentTime
                    w.tick()
                    let live = p.currentTime, deviceAfter = p.deviceCurrentTime
                    #expect(live >= w.cursor - 0.02 && live <= w.cursor + max(0, deviceAfter - deviceBefore) * Double(rate) + 0.02)
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

    @Test func nativePendingStartPauseSeekAndOriginalEOFDoNotRestartAnExpiredClock() async throws {
        let original = try fixture(duration: 1.5), stem = try fixture(duration: 1, padding: 0.25)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        for rate: Float in [0.5, 0.75, 1] {
            w.rate = rate; #expect(w.switchAsset(.original)); w.seek(0.5); w.togglePlayback()
            #expect(w.switchAsset(.importedGuitarStem) && w.playing && w.cursor >= 0.5)
            w.togglePlayback(); #expect(!w.playing && w.cursor >= 0.5)
            w.seek(0.7); #expect(w.switchAsset(.original) && !w.playing && w.cursor == 0.7)
            w.seek(1.49); w.togglePlayback()
            try await Task.sleep(for: .milliseconds(240))
            #expect(w.switchAsset(.importedGuitarStem) && !w.playing)
            #expect(w.cursor >= 1.49 && w.cursor < 1.5 && w.project.duration == 1.5)
        }
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
    @Test func cancelLateAttachDetachAndProjectLoadKeepCurrentProjectAndCleanOwnedStages() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25), replacement = try fixture(duration: 2)
        let save = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".roughscore")
        defer { for u in [original, stem, replacement, save] { try? FileManager.default.removeItem(at: u) } }
        let gate = StemGate(), capture = PreparedStemCapture()
        var service = services()
        service.prepare = { url, progress in
            let result = try await AudioPreparation.prepare(url, progress: progress)
            await capture.record(result)
            if url == replacement { await gate.wait() }
            return result
        }
        let w = Workspace(services: service); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); w.select(w.project.events[1]); w.updateSelected { $0.memo = "undo survives" }
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true && w.save(to: save))
        let before = w.project, selected = w.selectedID
        w.seek(0.5); w.togglePlayback()
        let cancelled = try #require(w.attachStem(at: replacement))
        await gate.started(); w.cancelLoading()
        let late = try #require(await capture.latest)
        #expect(w.project == before && w.selectedID == selected && !w.dirty && w.playing && w.canUndo)
        // Detach while a cancellation-ignoring service is still returning cannot revive that stem.
        w.detachStem(); let detached = w.project
        await gate.finish(); #expect(!(await cancelled.value))
        #expect(w.project == detached && w.project.stemAsset == nil && w.prepared != nil && w.playing)
        #expect(!FileManager.default.fileExists(atPath: late.directory.path))
        w.togglePlayback(); w.undoEdit(); #expect(w.selected?.memo != "undo survives")
        #expect(w.project.events.map(\.id) == before.events.map(\.id))
        // Cancel a stored-project load after its original has staged but while its stem waits.
        let loadGate = StemGate(), loadCapture = PreparedStemCapture()
        var loadServices = services()
        loadServices.prepare = { url, progress in
            let result = try await AudioPreparation.prepare(url, progress: progress); await loadCapture.record(result)
            if url == stem { await loadGate.wait() }
            return result
        }
        let target = Workspace(services: loadServices); defer { target.shutdown() }
        let targetBefore = target.project
        let load = try #require(target.loadProject(at: save)); await loadGate.started(); target.cancelLoading()
        await loadGate.finish(); #expect(!(await load.value))
        #expect(target.project == targetBefore && target.prepared == nil)
        let stages = await loadCapture.all
        #expect(stages.count == 2 && stages.allSatisfy { !FileManager.default.fileExists(atPath: $0.directory.path) })
    }

    @Test func realPreparePlayAndHashFailureRollbackLeavesOriginalNativeGraphAndBaseline() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        let save = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".roughscore")
        defer { for u in [original, stem, save] { try? FileManager.default.removeItem(at: u) } }
        let control = StemFailureControl()
        var service = services(); let make = service.makePlayer, prepare = service.prepareTransport
        service.prepareTransport = { audio in
            try prepare(audio)
            if audio.original == stem { control.directory = audio.directory }
        }
        service.makePlayer = { url in StemFailurePort(native: try make(url), control: control, url: url) }
        let w = Workspace(services: service); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); #expect(w.save(to: save)); let baseline = w.project
        w.seek(0.5); w.togglePlayback(); control.prepareFails = true
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == false)
        #expect(w.project == baseline && !w.dirty && w.playing && w.assetRole == .original)
        #expect(!FileManager.default.fileExists(atPath: try #require(control.directory).path))
        control.prepareFails = false
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        control.playFails = true; let attached = w.project
        #expect(!w.switchAsset(.importedGuitarStem) && w.assetRole == .original && w.playing && w.project == attached)
        w.tick(); #expect(w.cursor >= 0.5)
        control.playFails = false; #expect(w.switchAsset(.importedGuitarStem)); w.togglePlayback()
        let bytes = try Data(contentsOf: stem)
        let factory = service.prepareTransport
        service.prepareTransport = { audio in
            try factory(audio)
            if audio.original == stem { try Data("replacement after real preparation".utf8).write(to: stem) }
        }
        let fenced = Workspace(services: service); defer { fenced.shutdown() }
        #expect(await fenced.loadAudio(at: original)?.value == true)
        let before = fenced.project
        #expect(await fenced.attachStem(at: stem)?.value == false && fenced.project == before && fenced.prepared != nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(control.directory).path))
        try bytes.write(to: stem)
    }

    @Test func actualNativeStemButtonsOffsetDraftApplyUndoAndDetach() async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); let before = w.project.events
        let host = NotePointerTests.Host(StemControls(workspace: w), height: 300, width: 420); defer { host.close() }
        #expect(await w.attachStem(at: stem)?.value == true); host.settle()
        func button(_ id: String) throws -> NSButton {
            try #require(host.descendants().compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id })
        }
        #expect(try button("stem-attach").title == "스템 다시 연결…")
        try button("stem-audition").performClick(nil); host.settle()
        #expect(w.assetRole == .importedGuitarStem && w.project.events == before)
        try button("stem-original").performClick(nil); host.settle()
        #expect(w.assetRole == .original && w.project.events == before)
        let field = try #require(host.descendants().compactMap { $0 as? NSTextField }.first { $0.placeholderString == "offset seconds" })
        func enter(_ text: String) throws {
            #expect(host.window.makeFirstResponder(field))
            let editor = try #require(host.window.firstResponder as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            #expect(host.window.makeFirstResponder(nil)); host.settle()
        }
        for text in ["NaN", "inf", "86401", ""] {
            try enter(text); #expect(try !button("stem-offset-apply").isEnabled)
            #expect(w.project.stemAsset?.originalTimeOffset == 0 && w.project.events == before)
        }
        try enter("-0.250"); #expect(try button("stem-offset-apply").isEnabled)
        try button("stem-offset-apply").performClick(nil)
        await w.awaitLoading(); host.settle()
        #expect(w.project.stemAsset?.originalTimeOffset == -0.25 && w.project.events == before)
        w.undoEdit(); host.settle(); #expect(w.project.stemAsset?.originalTimeOffset == 0)
        w.redoEdit(); host.settle(); #expect(w.project.stemAsset?.originalTimeOffset == -0.25)
        try button("stem-detach").performClick(nil); host.settle()
        #expect(w.project.stemAsset == nil && w.project.events == before && w.prepared != nil)
        #expect(!host.window.isVisible && FileManager.default.fileExists(atPath: stem.path))
    }

    @Test(arguments: [false, true])
    func actualHiddenNativeScoreAndTimelinePreserveBulkSelectionTuningAndUndoAfterStem(score: Bool) async throws {
        let original = try fixture(), stem = try fixture(padding: 0.25)
        defer { for u in [original, stem] { try? FileManager.default.removeItem(at: u) } }
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = events(); w.windowLength = 3
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true && w.switchAsset(.importedGuitarStem))
        w.lane = .right
        let row = try #require(w.scoreLayout.systems.first)
        let host = score ? NotePointerTests.Host(ScoreStaff(workspace: w, row: row, lane: .right, measured: false, displayScale: 1), height: 123)
                         : NotePointerTests.Host(TabCanvas(workspace: w))
        defer { host.close() }
        let coincident = try #require(host.controls().first { ($0.accessibilityLabel() ?? "").contains("2개 음") })
        try host.click(coincident, flags: .command); try host.click(coincident, flags: .command)
        let ids = w.selectedIDs, before = w.project
        #expect(ids.count == 2)
        #expect(w.switchAsset(.original) && w.selectedIDs == ids)
        #expect(w.offsetSelection(time: 0.1) && w.project.events[0] == before.events[0])
        w.undoEdit(); #expect(w.project == before && w.selectedIDs == ids)
        #expect(w.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 0)); let tuned = w.project
        #expect(w.switchAsset(.importedGuitarStem) && w.project == tuned && w.selectedIDs == ids)
        w.undoEdit(); #expect(w.project == before && w.selectedIDs == ids)
        #expect(host.window.isVisible == false) // Disposable host only; no user's physical UI.
    }

}

@MainActor private final class StemCapture { var players: [URL: AudioEnginePlayer] = [:] }

private actor StemGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil } }
    func started() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}
private actor PreparedStemCapture {
    private(set) var all: [PreparedAudio] = []
    var latest: PreparedAudio? { all.last }
    func record(_ audio: PreparedAudio) { all.append(audio) }
}
@MainActor private final class StemFailureControl {
    var directory: URL?
    var prepareFails = false
    var playFails = false
}
@MainActor private final class StemFailurePort: AudioPlayerTransport {
    let native: any AudioPlayerTransport
    let control: StemFailureControl
    let url: URL
    init(native: any AudioPlayerTransport, control: StemFailureControl, url: URL) { self.native = native; self.control = control; self.url = url }
    var fails: Bool { url.deletingLastPathComponent().path == control.directory?.path }
    var currentTime: TimeInterval { get { native.currentTime } set { native.currentTime = newValue } }
    var rate: Float { get { native.rate } set { native.rate = newValue } }
    var volume: Float { get { native.volume } set { native.volume = newValue } }
    var enableRate: Bool { get { native.enableRate } set { native.enableRate = newValue } }
    var isPlaying: Bool { native.isPlaying }
    var deviceCurrentTime: TimeInterval { native.deviceCurrentTime }
    var sharedClockID: UUID? { native.sharedClockID }
    func prepareToPlay() -> Bool { !(fails && control.prepareFails) && native.prepareToPlay() }
    func play() -> Bool { !(fails && control.playFails) && native.play() }
    func play(atTime time: TimeInterval) -> Bool { !(fails && control.playFails) && native.play(atTime: time) }
    func pause() { native.pause() }
    func stop() { native.stop() }
}
