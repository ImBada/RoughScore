import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import SwiftUI
import Testing
@testable import RoughScore

@MainActor
@Suite(.serialized)
struct TuningIntegrationTests {
    private func services() -> WorkspaceServices {
        var value = WorkspaceServices.live
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

    /// Actual SwiftUI tuning fields hosted in a disposable hidden window; no visible GUI claim.
    @Test func nativeTuningFieldsKeepUncommittedMarkedTextAndProjectHistorySeparate() throws {
        _ = NSApplication.shared
        let workspace = Workspace(services: services()); defer { workspace.shutdown() }
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
        let canUndo = target.canUndo
        target.undo(); settle()
        #expect(workspace.project == baseline && workspace.canUndo)
        print("Hosted tuning field: marked text retained; native undo available=\(canUndo); uncommitted draft never edits TAB")
        print("Hosted buttons: \(descendants(host).compactMap { $0 as? NSButton }.map(\.title))")
    }
}
