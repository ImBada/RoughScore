import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

private actor PitchEstimateGate {
    private var continuation: CheckedContinuation<DetectedPitch?, any Error>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func estimate() async throws -> DetectedPitch? {
        try await withCheckedThrowingContinuation {
            continuation = $0; startedWaiter?.resume(); startedWaiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish(failing: Bool = false) {
        if failing { continuation?.resume(throwing: AudioIssue.unsupported) }
        else { continuation?.resume(returning: DetectedPitch(frequencyHz: 329.63, midi: 64)) }
        continuation = nil
    }
}

@MainActor private final class TuningTextTargetBox { var target: NativeTextUndoTarget? }

@MainActor
@Suite(.serialized)
struct TuningIntegrationTests {
    private func services() -> WorkspaceServices {
        var value = WorkspaceServices.isolatedCache()
        value.rememberProject = { _ in }; value.lastProject = { nil }; value.chooseSaveDestination = { _ in nil }
        value.nativeTextUndo = { nil }
        return value
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-tuning-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func customCapoAtomicValidationSaveReopenAndUndoPreserveAllManualData() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("custom.roughscore")
        let manual = TabEvent(time: 2.123456789, lane: .right, string: 6, fret: 0, length: nil, tentative: true, memo: "keep\nexact")
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(title: "numeric", duration: 20, events: [manual])
        #expect(workspace.save(to: url))
        let baseline = workspace.project, bytes = try Data(contentsOf: url)
        for invalid in [([], 0), ([64, 59, 55, 50, 45, 38], -1), ([64, 59, 55, 50, 45, 38], 25),
                        ([128, 59, 55, 50, 45, 38], 0), ([127, 59, 55, 50, 45, 38], 2)] {
            #expect(!workspace.setTuning(openMIDIPitches: invalid.0, capo: invalid.1))
            #expect(workspace.project == baseline && !workspace.dirty && !workspace.canUndo)
            #expect(try Data(contentsOf: url) == bytes)
        }
        let custom = [67, 60, 56, 49, 43, 38]
        #expect(workspace.setTuning(openMIDIPitches: custom, capo: 2))
        #expect(workspace.project.events == [manual] && workspace.selectedID == nil)
        #expect(workspace.project.soundingMIDI(string: 6, fret: 0) == 40)
        #expect(workspace.project.tuningDisplay.contains("Custom · capo 2") && workspace.project.stringLabel(6) == "E2")
        #expect(try workspace.exportedText().contains("capo 2") && workspace.exportedText().contains("D2 (38)"))
        workspace.undoEdit(); #expect(workspace.project == baseline && !workspace.dirty && !workspace.canUndo)
        workspace.redoEdit(); let changed = workspace.project
        #expect(workspace.setTuning(openMIDIPitches: custom, capo: 2))
        workspace.undoEdit(); #expect(workspace.project == baseline && !workspace.canUndo)
        workspace.redoEdit(); #expect(workspace.project == changed)
        await workspace.awaitAutosave()
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) == changed)
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == changed && !workspace.dirty && !workspace.canUndo)
    }

    @Test(arguments: [false, true]) func legacyStandardAndUnresolvedLabelsSurviveOfflineReopen(nonstandard: Bool) async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.roughscore")
        let note = TabEvent(time: 1.123, lane: .left, string: 6, fret: 0, memo: "v1")
        var project = ScoreProject(duration: 20, events: [note])
        if nonstandard { project.tuning[5] = "D" }
        try JSONEncoder().encode(project).write(to: url)
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == project && workspace.project.tuningDefinition == nil && !workspace.dirty)
        workspace.select(note)
        if nonstandard {
            #expect(workspace.project.soundingMIDI(string: 6, fret: 0) == nil)
            #expect(workspace.fingerings(midi: 40, eventID: note.id) == .unresolvedTuning)
            #expect(try workspace.exportedText().contains("Unresolved legacy"))
            #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
            #expect(workspace.project.events == [note] && workspace.project.soundingMIDI(string: 6, fret: 0) == 40)
            workspace.undoEdit(); #expect(workspace.project == project && !workspace.dirty)
        } else {
            #expect(workspace.project.soundingMIDI(string: 6, fret: 0) == 40)
            #expect(workspace.project.tuningDisplay.contains("Standard · capo 0"))
        }
    }

    @Test func choicesUndoOnceRejectStaleAndOtherLanePermutationsNeverChangeRanking() throws {
        let note = TabEvent(time: 2.123456789, lane: .left, string: 1, fret: nil, length: nil, tentative: true, memo: "unchanged")
        let prior = TabEvent(time: 1, lane: .left, string: 4, fret: 13)
        let next = TabEvent(time: 3, lane: .left, string: 4, fret: 15)
        let opposite = TabEvent(time: 2, lane: .right, string: 6, fret: 24)
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20, events: [note, prior, next, opposite])
        workspace.select(note)
        let resolution = workspace.fingerings(midi: 64, eventID: note.id)
        #expect(resolution.candidates.map { "\($0.string)/\($0.fret)" } == ["4/14", "3/9", "5/19", "2/5", "6/24", "1/0"])
        #expect(workspace.fingerings(midi: 64, preferredFret: 5, eventID: note.id).candidates.first?.string == 2)
        workspace.select(opposite); workspace.updateSelected { $0.fret = 0; $0.time = 10 }
        workspace.select(note)
        #expect(workspace.fingerings(midi: 64, eventID: note.id) == resolution)
        workspace.project.events.reverse()
        #expect(workspace.fingerings(midi: 64, eventID: note.id) == resolution)
        let baseline = workspace.project
        #expect(!workspace.chooseFingering(midi: 64, string: 1, fret: 1, eventID: note.id))
        #expect(workspace.chooseFingering(midi: 64, string: 4, fret: 14, eventID: note.id))
        let chosen = try #require(workspace.selected)
        #expect(chosen.id == note.id && chosen.time == note.time && chosen.lane == note.lane)
        #expect(chosen.memo == note.memo && chosen.length == nil && chosen.tentative == note.tentative)
        #expect(workspace.activeString == 4 && workspace.project.soundingMIDI(string: chosen.string, fret: chosen.fret!) == 64)
        #expect(workspace.chooseFingering(midi: 64, string: 4, fret: 14, eventID: note.id))
        workspace.undoEdit(); #expect(workspace.project == baseline && workspace.activeString == 1)
        #expect(workspace.canRedo)
        #expect(!workspace.chooseFingering(midi: 200, string: 4, fret: 14, eventID: note.id))
        #expect(workspace.canRedo && workspace.project == baseline)
        workspace.select(opposite)
        #expect(!workspace.chooseFingering(midi: 64, string: 4, fret: 14, eventID: note.id))
        #expect(workspace.project == baseline)
        workspace.select(note)
        #expect(workspace.fingerings(midi: 0, eventID: note.id).candidates.isEmpty)
        #expect(workspace.fingerings(midi: -1, eventID: note.id) == .invalidPitch)
        #expect(workspace.fingerings(midi: 64, preferredFret: 25, eventID: note.id) == .invalidPreference)
    }

    @Test func generatedDemoDetectedPitchDisplayAndExportAgreeWithCapo() async throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        let note = TabEvent(time: 0.2, lane: .left, string: 6, fret: 0, memo: "Drop D capo two")
        workspace.project = ScoreProject(duration: 2, events: [note])
        #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
        let url = try AudioPreparation.createDemo(project: workspace.project)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreparation.prepare(url)
        workspace.prepared = prepared
        workspace.select(note)
        let before = workspace.project
        #expect(await workspace.detectSelectedPitch()?.value != nil)
        let estimate = try #require(workspace.detectedPitch)
        #expect(estimate.nearestMIDI == 40 && abs(estimate.frequencyHz - 82.4069) < 1)
        #expect(workspace.project == before && workspace.project.stringLabel(6) == "E2")
        #expect(workspace.fingerings(midi: 40, eventID: note.id).candidates.map { "\($0.string)/\($0.fret)" } == ["6/0"])
        #expect(try workspace.exportedText().contains("Drop D tuning") && workspace.exportedText().contains("capo 2"))
        workspace.clearSelection(); #expect(workspace.detectedPitch == nil && workspace.project == before)
        #expect(DetectedPitch(frequencyHz: .nan, midi: 64).nearestMIDI == nil)
    }

    @Test func lateDetectionCannotPublishAfterSelectionTuningLoadOrShutdown() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = TabEvent(time: 0.2, lane: .left, string: 1)
        let other = TabEvent(time: 0.4, lane: .right, string: 6)
        for action in 0..<4 {
            let gate = PitchEstimateGate()
            var service = services(); service.detectPitch = { _, _ in try await gate.estimate() }
            let workspace = Workspace(services: service); defer { workspace.shutdown() }
            workspace.project = ScoreProject(duration: 2, events: [note, other])
            let url = try AudioPreparation.createDemo(project: workspace.project)
            defer { try? FileManager.default.removeItem(at: url) }
            workspace.prepared = try await AudioPreparation.prepare(url)
            workspace.select(note)
            let task = try #require(workspace.detectSelectedPitch())
            await gate.started()
            switch action {
            case 0: workspace.select(other)
            case 1: #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
            case 2:
                let document = directory.appendingPathComponent("replacement.roughscore")
                try JSONEncoder().encode(ScoreProject(duration: 20)).write(to: document)
                #expect(await workspace.loadProject(at: document)?.value == true)
            default: workspace.shutdown()
            }
            let before = workspace.project
            await gate.finish(); await task.value
            #expect(workspace.detectedPitch == nil && !workspace.detectingPitch && workspace.pitchDetectionMessage.isEmpty)
            #expect(workspace.project == before)
        }
    }

    @Test func tuningHistoryCoexistsWithBulkSelectionCursorAndOneStepBatchUndo() throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        let notes = [TabEvent(time: 2, lane: .left, string: 6, fret: 0), TabEvent(time: 3, lane: .left, string: 5, fret: 2)]
        workspace.project = ScoreProject(duration: 20, events: notes)
        workspace.select(notes[0]); workspace.toggleSelection(notes[1])
        workspace.placeSelectionCursor(10)
        let selection = workspace.selectedIDs
        #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
        #expect(workspace.selectedIDs == selection && workspace.cursor == 10 && workspace.project.events == notes)
        #expect(workspace.offsetSelection(time: 1, strings: -1))
        let tuned = workspace.project.tuningDefinition
        workspace.undoEdit()
        #expect(workspace.project.events == notes && workspace.project.tuningDefinition == tuned && workspace.selectedIDs == selection)
        workspace.undoEdit()
        #expect(workspace.project.tuningDefinition == nil && workspace.project.events == notes && workspace.cursor == 10)
        workspace.redoEdit(); workspace.redoEdit()
        #expect(workspace.project.tuningDefinition == tuned && workspace.selectedIDs == selection)
        #expect(workspace.project.events.map(\.time) == [3, 4])
    }

    /// The service deliberately ignores cancellation; both completion paths must own their context.
    @Test(arguments: ["seek", "jump", "pasteCursor", "sourceLeft", "sourceRight", "lane", "tuning",
                      "selection", "shutdown", "cursorRoundTrip", "sourceRoundTrip", "edit",
                      "seekSame", "seekInvalid", "sourceSame", "sourceFailure", "laneSame",
                      "tuningSame", "tuningInvalid", "status"], [false, true])
    func pendingPitchOwnsAcceptedContextAndPreservesRejectedRequests(action: String, failing: Bool) async throws {
        let gate = PitchEstimateGate()
        var service = services()
        service.detectPitch = { _, _ in try await gate.estimate() }
        service.makePlayer = { audio, source in
            let url = audio.url(for: source)
            if action == "sourceFailure" { throw AudioIssue.playbackFailed }
            return try AVAudioPlayer(contentsOf: url)
        }
        let workspace = Workspace(services: service); defer { workspace.shutdown() }
        let note = TabEvent(time: 0.2, lane: .left, string: 1, fret: 0, length: nil, tentative: true, memo: "keep\t\nexact")
        workspace.project = ScoreProject(duration: 2, events: [note])
        if action == "tuningSame" { #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.standard.openMIDIPitches, capo: 0)) }
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(workspace.save(to: directory.appendingPathComponent("baseline.roughscore")))
        let url = try AudioPreparation.createDemo(project: workspace.project)
        defer { try? FileManager.default.removeItem(at: url) }
        workspace.prepared = try await AudioPreparation.prepare(url)
        workspace.select(note)
        let baseline = workspace.project, hadUndo = workspace.canUndo
        let task = try #require(workspace.detectSelectedPitch())
        await gate.started()
        let shouldReject = ["seek", "jump", "pasteCursor", "sourceLeft", "sourceRight", "lane", "tuning",
                            "selection", "shutdown", "cursorRoundTrip", "sourceRoundTrip", "edit"].contains(action)
        switch action {
        case "seek": workspace.seek(1.5)
        case "jump": workspace.jumpToScoreTime(1.5)
        case "pasteCursor": workspace.placeSelectionCursor(1.5)
        case "sourceLeft": workspace.switchSource(.left)
        case "sourceRight": workspace.switchSource(.right)
        case "lane": workspace.selectLane(.right)
        case "tuning": #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
        case "selection": workspace.clearSelection()
        case "shutdown": workspace.shutdown()
        case "cursorRoundTrip": workspace.seek(1.5); workspace.seek(note.time)
        case "sourceRoundTrip": workspace.switchSource(.left); workspace.switchSource(.stereo)
        case "edit": workspace.updateSelected { $0.time = 0.7 }
        case "seekSame": workspace.seek(note.time)
        case "seekInvalid": workspace.seek(.nan)
        case "sourceSame": workspace.switchSource(.stereo)
        case "sourceFailure": workspace.switchSource(.left); #expect(workspace.source == .stereo && workspace.error != nil)
        case "laneSame": workspace.selectLane(.left)
        case "tuningSame": #expect(workspace.setTuning(openMIDIPitches: TuningDefinition.standard.openMIDIPitches, capo: 0))
        case "tuningInvalid": #expect(!workspace.setTuning(openMIDIPitches: TuningDefinition.standard.openMIDIPitches, capo: 25))
        default: workspace.status = "unrelated status"
        }
        let beforeCompletion = workspace.project
        if !["tuning", "edit"].contains(action) {
            #expect(workspace.project == baseline && workspace.canUndo == hadUndo && !workspace.dirty)
        }
        if ["seek", "jump", "pasteCursor", "sourceLeft"].contains(action) { #expect(workspace.selectedID == note.id) }
        await gate.finish(failing: failing); await task.value
        #expect(workspace.project == beforeCompletion && !workspace.detectingPitch)
        if shouldReject {
            #expect(workspace.detectedPitch == nil && workspace.pitchDetectionMessage.isEmpty)
        } else if failing {
            #expect(workspace.detectedPitch == nil && workspace.pitchDetectionMessage == "음고 추정 불가 · 직접 MIDI 입력 가능")
        } else {
            #expect(workspace.detectedPitch?.nearestMIDI == 64 && !workspace.pitchDetectionMessage.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func staleCompletionCannotPublishOrFinishANewerPitchRequest(failing: Bool) async throws {
        let first = PitchEstimateGate(), second = PitchEstimateGate()
        var service = services()
        service.detectPitch = { _, time in try await (time < 0.5 ? first : second).estimate() }
        let workspace = Workspace(services: service); defer { workspace.shutdown() }
        let note = TabEvent(time: 0.2, lane: .left, string: 1, fret: 0, memo: "keep")
        workspace.project = ScoreProject(duration: 2, events: [note])
        let url = try AudioPreparation.createDemo(project: workspace.project)
        defer { try? FileManager.default.removeItem(at: url) }
        workspace.prepared = try await AudioPreparation.prepare(url)
        workspace.select(note)
        let oldTask = try #require(workspace.detectSelectedPitch()); await first.started()
        workspace.seek(1.5); workspace.updateSelected { $0.time = 0.6 }
        let newTask = try #require(workspace.detectSelectedPitch()); await second.started()
        let baseline = workspace.project
        await first.finish(failing: failing); await oldTask.value
        #expect(workspace.detectingPitch && workspace.detectedPitch == nil && workspace.pitchDetectionMessage.isEmpty)
        #expect(workspace.project == baseline && workspace.selectedID == note.id)
        await second.finish(); await newTask.value
        #expect(!workspace.detectingPitch && workspace.detectedPitch?.nearestMIDI == 64)
        #expect(workspace.project == baseline && workspace.selectedID == note.id)
    }

    /// Generated media through actual native player ports: the accepted handover samples the live clock.
    @Test(arguments: ["tick", "sourceLeft"], [false, true])
    func pendingPitchRejectsActualPlaybackClockChanges(action: String, failing: Bool) async throws {
        let gate = PitchEstimateGate()
        var service = services()
        service.detectPitch = { _, _ in try await gate.estimate() }
        service.prepareTransport = { _ in }
        service.makePlayer = { try AVAudioPlayer(contentsOf: $0.url(for: $1)) }
        let workspace = Workspace(services: service); defer { workspace.shutdown() }
        let note = TabEvent(time: 0.2, lane: .left, string: 1, fret: 0)
        let url = try AudioPreparation.createDemo(project: ScoreProject(duration: 3, events: [note]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await workspace.loadAudio(at: url)?.value == true)
        workspace.project.events = [note]; workspace.select(note)
        let baseline = workspace.project, dirty = workspace.dirty, hadUndo = workspace.canUndo
        workspace.togglePlayback(); #expect(workspace.playing)
        let task = try #require(workspace.detectSelectedPitch()); await gate.started()
        try await Task.sleep(for: .milliseconds(80))
        if action == "tick" { workspace.tick() } else { workspace.switchSource(.left) }
        #expect(workspace.cursor > note.time && workspace.selectedID == note.id && workspace.playing)
        if action == "sourceLeft" { #expect(workspace.source == .left && workspace.lane == .left) }
        await gate.finish(failing: failing); await task.value
        #expect(workspace.detectedPitch == nil && workspace.pitchDetectionMessage.isEmpty && !workspace.detectingPitch)
        #expect(workspace.project == baseline && workspace.canUndo == hadUndo && workspace.dirty == dirty)
    }

    @Test func nativeApplyRequiresWholeValidDraftAndKeepsUndoRedoDraftLocal() throws {
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = TabEvent(time: 0.2, lane: .left, string: 6, fret: 0, memo: "unchanged")
        workspace.project = ScoreProject(duration: 2, events: [note])
        workspace.project.tuning[5] = "D" // Six unresolved drafts must stay blank, without octave guesses.
        #expect(workspace.save(to: directory.appendingPathComponent("legacy.roughscore")))
        let baseline = workspace.project
        let host = NotePointerTests.Host(TuningEditor(workspace: workspace), height: 650)
        defer { host.close() }
        func applyButton() throws -> NSButton {
            try #require(host.descendants().compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "tuning-apply" })
        }
        let fields = host.descendants().compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "open MIDI" }
        let capoField = try #require(host.descendants().compactMap { $0 as? NSTextField }.first { $0.placeholderString == "0–24" })
        #expect(fields.count == 6 && fields.allSatisfy { $0.stringValue.isEmpty })
        func enter(_ field: NSTextField, _ value: String) throws {
            #expect(host.window.makeFirstResponder(field))
            let editor = try #require(host.window.firstResponder as? NSTextView)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            #expect(host.window.makeFirstResponder(nil)); host.settle()
        }
        func reject() throws {
            #expect(try !applyButton().isEnabled, "MIDI draft \(fields.map(\.stringValue)), capo \(capoField.stringValue)")
            try applyButton().performClick(nil); host.settle()
            #expect(workspace.project == baseline && !workspace.canUndo && !workspace.canRedo && !workspace.dirty)
        }
        try reject()
        for (field, value) in zip(fields, TuningDefinition.dropD.openMIDIPitches) { try enter(field, String(value)) }
        #expect(try applyButton().isEnabled)
        for value in ["25", "-1", "", "two", String(Int.max)] { try enter(capoField, value); try reject() }
        try enter(capoField, "2")
        for value in ["", "C4", "-1", "128", "127", String(Int.max)] { try enter(fields[0], value); try reject() }
        try enter(fields[0], " 67 ")
        #expect(try applyButton().isEnabled)
        let expected = TuningDefinition(openMIDIPitches: [67, 59, 55, 50, 45, 38], capo: 2)
        try applyButton().performClick(nil); host.settle()
        #expect(workspace.project.resolvedTuning == expected && workspace.project.events == [note] && workspace.dirty)
        let applied = workspace.project
        try applyButton().performClick(nil); host.settle() // Valid no-op adds no history.
        workspace.undoEdit(); host.settle()
        #expect(workspace.project == baseline && !workspace.canUndo && workspace.canRedo && !workspace.dirty)
        #expect(fields[0].stringValue == " 67 " && capoField.stringValue == "2")
        #expect(try applyButton().isEnabled)
        workspace.redoEdit(); host.settle()
        #expect(workspace.project == applied && workspace.project.events == [note])
        #expect(fields[0].stringValue == " 67 " && capoField.stringValue == "2")
    }

    @Test func actualHostedTuningPresetCapoRejectApplyAndCandidateButtons() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
        let note = TabEvent(time: 2.123456789, lane: .right, string: 1, fret: 0, length: nil, tentative: true, memo: "native choice")
        workspace.project = ScoreProject(duration: 20, events: [note])
        #expect(workspace.save(to: directory.appendingPathComponent("native.roughscore")))
        workspace.select(note)
        let baseline = workspace.project
        let tuning = NotePointerTests.Host(TuningEditor(workspace: workspace), height: 550)
        defer { tuning.close() }
        func button(_ host: NotePointerTests.Host, _ id: String) throws -> NSButton {
            try #require(host.descendants().compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id })
        }
        try button(tuning, "tuning-drop-d").performClick(nil); tuning.settle()
        #expect(workspace.project == baseline && !workspace.dirty && !workspace.canUndo)
        let capoField = try #require(tuning.descendants().compactMap { $0 as? NSTextField }.first { $0.placeholderString == "0–24" })
        func enterCapo(_ value: String) throws {
            #expect(tuning.window.makeFirstResponder(capoField))
            let editor = try #require(tuning.window.firstResponder as? NSTextView)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            #expect(tuning.window.makeFirstResponder(nil)); tuning.settle()
        }
        try enterCapo("25")
        #expect(try !button(tuning, "tuning-apply").isEnabled)
        try button(tuning, "tuning-apply").performClick(nil); tuning.settle()
        #expect(workspace.project == baseline && !workspace.dirty && !workspace.canUndo)
        try enterCapo("2")
        #expect(try button(tuning, "tuning-apply").isEnabled)
        try button(tuning, "tuning-apply").performClick(nil); tuning.settle()
        #expect(workspace.project.resolvedTuning == TuningDefinition(openMIDIPitches: TuningDefinition.dropD.openMIDIPitches, capo: 2))
        #expect(workspace.project.events == [note] && workspace.selectedID == note.id && workspace.dirty)
        workspace.undoEdit(); #expect(workspace.project == baseline && !workspace.dirty && !workspace.canUndo)

        let pitch = NotePointerTests.Host(PitchAlternatives(workspace: workspace, event: note), height: 480)
        defer { pitch.close() }
        try button(pitch, "fingering-disclosure").performClick(nil); pitch.settle()
        let positions = pitch.descendants().compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("fingering-choice-") == true }
        #expect(positions.count == 6 && workspace.project == baseline && !workspace.canUndo)
        try button(pitch, "fingering-choice-2").performClick(nil); pitch.settle()
        var chosen = note; chosen.string = 2; chosen.fret = 5
        #expect(workspace.project.events == [chosen] && workspace.selectedID == note.id)
        try button(pitch, "fingering-choice-2").performClick(nil); pitch.settle()
        workspace.undoEdit(); pitch.settle()
        #expect(workspace.project == baseline && !workspace.canUndo && !workspace.dirty)
        print("Hosted native tuning: Drop D draft, invalid capo 25 atomic rejection, capo 2 application and one-step undo; six standard MIDI64 buttons, 2/5 explicit choice and one-step undo")
    }

    /// Actual SwiftUI tuning fields hosted in a disposable hidden window; no visible GUI claim.
    @Test func nativeTuningFieldsKeepUncommittedMarkedTextAndProjectHistorySeparate() throws {
        _ = NSApplication.shared
        let box = TuningTextTargetBox()
        var service = services(); service.nativeTextUndo = { box.target }
        let workspace = Workspace(services: service); defer { workspace.shutdown() }
        workspace.project = ScoreProject(duration: 20)
        workspace.seekForEditing(2); workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.8)
        #expect(workspace.selected?.fret == 12 && workspace.selected?.length == nil)
        let host = NSHostingView(rootView: TuningEditor(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() }
        settle()
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        let baseline = workspace.project
        editor.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let marked = editor.markedRange(), caret = editor.selectedRange()
        workspace.status = "unrelated update"; settle()
        #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == caret)
        #expect(workspace.project == baseline)
        let target = NativeTextUndoTarget(editor.undoManager, editor: editor)
        box.target = target
        let canUndo = target.canUndo
        workspace.performUndo(); settle()
        #expect(workspace.project == baseline && workspace.canUndo)
        print("Hosted tuning field: marked text retained; native undo available=\(canUndo); uncommitted draft never edits TAB")
    }
}
