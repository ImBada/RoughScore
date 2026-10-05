import AppKit
import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
private struct DragFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-drag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func services() -> WorkspaceServices {
        var services = WorkspaceServices.isolatedCache()
        services.rememberProject = { _ in }; services.lastProject = { nil }
        services.chooseSaveDestination = { _ in nil }
        return services
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func document(_ project: ScoreProject, name: String = "project") throws -> URL {
        let url = root.appendingPathComponent(name + ".roughscore")
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
struct DragTransactionTests {
    @Test(arguments: ["up", "down", "left", "right", "tentative", "unknown", "tab", "redo", "delete", "digit", "inspector", "directTime", "seek", "lane", "source", "select"])
    func dragRejectsOtherMutationsAndKeepsOneUndo(command: String) throws {
        let f = try DragFixture(); defer { f.clean() }
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let note = TabEvent(time: 2.123456789, lane: .left, string: 5, fret: 7, memo: "keep")
        let right = TabEvent(time: 3.25, lane: .right, string: 2, memo: "other lane")
        let neighbor = TabEvent(time: 8, lane: .left, string: 1)
        workspace.project = ScoreProject(duration: 20, events: [note, right, neighbor])
        workspace.select(note); workspace.updateSelected { $0.memo = "redo branch" }; workspace.undoEdit()
        #expect(!workspace.canUndo && workspace.canRedo)
        let original = workspace.project
        workspace.beginPositionDrag(note); workspace.previewPositionDrag(time: 4.5, string: 3, snap: false)
        let preview = workspace.positionDrag, cursor = workspace.cursor
        switch command {
        case "up": workspace.moveSelectedString(by: -1)
        case "down": workspace.moveSelectedString(by: 1)
        case "left": workspace.nudgeSelectedTime(by: -0.05)
        case "right": workspace.nudgeSelectedTime(by: 0.01)
        case "tentative": workspace.toggleTentative()
        case "unknown": workspace.markUnknown()
        case "tab": workspace.selectAdjacentEvent()
        case "redo": workspace.redoEdit()
        case "delete": workspace.deleteSelected()
        case "digit": workspace.inputDigit(1, at: 100)
        case "inspector": workspace.updateSelected { $0.memo = "must not change" }
        case "seek": workspace.seekForEditing(9)
        case "lane": workspace.selectLane(.right)
        case "source": workspace.switchSource(.right)
        case "select": workspace.select(neighbor)
        default: workspace.moveSelectedPosition(to: 9)
        }
        #expect(workspace.project == original)
        #expect(workspace.selectedID == note.id && workspace.positionDrag == preview && workspace.cursor == cursor)
        #expect(!workspace.canUndo)
        workspace.cancelPositionDrag()
        #expect(workspace.canRedo) // The denied command did not clear the existing redo branch.
        workspace.redoEdit(); #expect(workspace.selected?.memo == "redo branch")
        workspace.undoEdit(); #expect(workspace.project == original)
        workspace.beginPositionDrag(note); workspace.previewPositionDrag(time: 4.5, string: 3, snap: false)
        workspace.commitPositionDrag()
        #expect(workspace.selected?.time == 4.5 && workspace.selected?.string == 3)
        workspace.undoEdit()
        #expect(workspace.project == original && !workspace.canUndo)
        workspace.redoEdit()
        #expect(workspace.selected?.id == note.id && workspace.selected?.length == nil)
        #expect(workspace.selected?.memo == "keep" && workspace.project.events[1] == right)
    }

    @Test func firstEscapeCancelsAndSecondEscapeDeselectsThroughKeyboardBridge() throws {
        let f = try DragFixture(); defer { f.clean() }
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let note = TabEvent(time: 2.123456789, lane: .left, string: 5, fret: 7)
        let target = TabEvent(time: 4, lane: .left, string: 2, memo: "anchor")
        workspace.project = ScoreProject(duration: 20, events: [note, target])
        workspace.select(note); workspace.updateSelected { $0.memo = "redo branch" }; workspace.undoEdit()
        #expect(workspace.save(to: f.root.appendingPathComponent("saved.roughscore")))
        let original = workspace.project
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.99, string: 1, screenX: 99,
            anchors: [NoteMagnetAnchor(id: target.id, time: target.time, x: 100)], shift: true)
        #expect(workspace.positionMagnetTargetID == target.id)
        let keyboard = TabKeyboardView(); keyboard.workspace = workspace
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        keyboard.keyDown(with: escape)
        #expect(workspace.positionDrag == nil && workspace.positionMagnetTargetID == nil)
        #expect(workspace.project == original && workspace.selectedID == note.id && workspace.activeString == note.string)
        #expect(!workspace.dirty && !workspace.canUndo && workspace.canRedo)
        keyboard.keyDown(with: escape)
        #expect(workspace.selectedID == nil && workspace.project == original)
        #expect(!workspace.dirty && !workspace.canUndo && workspace.canRedo)
        workspace.redoEdit(); #expect(workspace.project.events[0].memo == "redo branch")
    }

    @Test(arguments: [1.0 / 8000, 0.0005, 5.0 / 8000, 0.001, 20.0])
    func allTimeEditingPathsStayValidAndRoundTrip(duration: Double) async throws {
        let f = try DragFixture(); defer { f.clean() }
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let url = try f.document(ScoreProject(title: "short", duration: duration))
        #expect(await workspace.loadProject(at: url)?.value == true)
        workspace.seek(duration)
        #expect(workspace.cursor >= 0 && workspace.cursor < duration)
        workspace.addEvent(time: duration, string: 6); workspace.inputDigit(7, at: 100)
        #expect(workspace.selected!.time >= 0 && workspace.selected!.time < duration)
        _ = try workspace.project.validated()
        let id = try #require(workspace.selectedID)
        workspace.nudgeSelectedTime(by: -100)
        #expect(workspace.selected?.time == 0)
        workspace.moveSelectedPosition(to: duration * 2, string: 1)
        _ = try workspace.project.validated()
        workspace.beginPositionDrag(try #require(workspace.selected))
        workspace.previewPositionDrag(time: duration * 2, string: 100, snap: false)
        workspace.commitPositionDrag()
        _ = try workspace.project.validated()
        workspace.updateSelected { $0.time = duration * 2 } // Inspector command uses the same finite bound.
        _ = try workspace.project.validated()
        #expect(workspace.selected?.id == id && workspace.selected?.length == nil && workspace.selected?.fret == 7)
        #expect(workspace.save(to: url))
        let saved = workspace.project
        #expect(await workspace.loadProject(at: url)?.value == true)
        #expect(workspace.project == saved)
    }

    @Test(arguments: [1, 5, 8]) func actualOneFrameAudioEitherActivatesSafelyOrRejectsBeforeCommit(frames: Int) async throws {
        let f = try DragFixture(); defer { f.clean() }
        let original = f.root.appendingPathComponent("tiny.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: frames)
        try AVAudioFile(forWriting: original, settings: format.settings).write(from: buffer)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        let before = workspace.project
        let accepted = await workspace.loadAudio(at: original)?.value == true
        if accepted {
            #expect(workspace.project.duration == Double(frames) / 8000)
            workspace.seek(workspace.project.duration); workspace.inputDigit(0, at: 100)
            _ = try workspace.project.validated()
            let url = f.root.appendingPathComponent("tiny.roughscore")
            #expect(workspace.save(to: url))
            let saved = workspace.project
            #expect(await workspace.loadProject(at: url)?.value == true)
            #expect(workspace.project == saved)
        } else {
            #expect(workspace.project == before && workspace.prepared == nil && !workspace.busy && workspace.error != nil)
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}
