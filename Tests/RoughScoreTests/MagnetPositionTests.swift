import AppKit
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

@MainActor
struct MagnetPositionTests {
    @Test func ordinaryDragStaysFreeEvenWhenBeatSnapIsEnabled() {
        let (workspace, note, target, _) = fixture()
        workspace.snapToBeat = true
        workspace.project.analyses = ["stereo": AnalysisSummary(beats: [0, 1, 2, 3, 4])]
        let original = workspace.project
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 115,
                                          anchors: [anchor(target, x: 120)], shift: false)

        #expect(workspace.positionDrag?.time == 3.08)
        #expect(workspace.positionMagnetTargetID == nil)
        #expect(workspace.project == original)
        #expect(!workspace.canUndo)
        #expect(!workspace.dirty)
    }

    @Test func shiftAtTheCaptureBoundaryUsesTheExactOtherNoteTime() {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 110,
                                          anchors: [anchor(target, x: 120)], shift: true)

        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionMagnetTargetID == target.id)
        #expect(workspace.project.events.first { $0.id == note.id } == note)
    }

    @Test func holdingShiftBeyondTheRadiusKeepsTheRawPosition() {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 109.999,
                                          anchors: [anchor(target, x: 120)], shift: true)

        #expect(workspace.positionDrag?.time == 3.08)
        #expect(workspace.positionMagnetTargetID == nil)
    }

    @Test func selfAndOtherLaneCannotAttractTheDraggedNote() {
        let (workspace, note, target, otherLane) = fixture()
        workspace.beginPositionDrag(note)
        let excluded = [anchor(note, x: 100), anchor(otherLane, x: 101)]
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 100,
                                          anchors: excluded, shift: true)
        #expect(workspace.positionDrag?.time == 3.08)
        #expect(workspace.positionMagnetTargetID == nil)

        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 100,
                                          anchors: excluded + [anchor(target, x: 108)], shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionMagnetTargetID == target.id)
    }

    @Test func shiftAlignsTimeWhileAllowingTheStringToChange() {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.08, string: 1, screenX: 115,
                                          anchors: [anchor(target, x: 120)], shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionDrag?.string == 1)
        workspace.previewMagneticPosition(time: 3.08, string: 6, screenX: 115,
                                          anchors: [anchor(target, x: 120)], shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionDrag?.string == 6)
    }

    @Test func stationaryModifierChangesUseTheLatestRawPointerPosition() {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.083, string: 4, screenX: 114,
                                          anchors: [anchor(target, x: 120)], shift: false)
        workspace.updatePositionModifiers(shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionMagnetTargetID == target.id)
        workspace.updatePositionModifiers(shift: false)
        #expect(workspace.positionDrag?.time == 3.083)
        #expect(workspace.positionMagnetTargetID == nil)

        workspace.previewMagneticPosition(time: 4.234, string: 2, screenX: 116,
                                          anchors: [anchor(target, x: 120)], shift: false)
        workspace.updatePositionModifiers(shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionDrag?.string == 2)
        workspace.updatePositionModifiers(shift: false)
        #expect(workspace.positionDrag?.time == 4.234)
        #expect(workspace.positionDrag?.string == 2)
        #expect(workspace.positionMagnetTargetID == nil)
    }

    @Test func finalModifierStateCommitsOneUndoableMoveAndPreservesMetadata() throws {
        for finalShift in [false, true] {
            let (workspace, note, target, otherLane) = fixture()
            let original = workspace.project
            workspace.beginPositionDrag(note)
            workspace.previewMagneticPosition(time: 3.081, string: 1, screenX: 115,
                                              anchors: [anchor(target, x: 120)], shift: false)
            workspace.updatePositionModifiers(shift: true)
            workspace.updatePositionModifiers(shift: false)
            workspace.updatePositionModifiers(shift: finalShift)
            workspace.commitPositionDrag()

            var moved = note
            moved.time = finalShift ? target.time : 3.081
            moved.string = 1
            #expect(workspace.project.events == [moved, target, otherLane])
            #expect(workspace.selectedID == note.id)
            #expect(workspace.activeString == 1)
            #expect(workspace.positionDrag == nil)
            #expect(workspace.positionMagnetTargetID == nil)
            #expect(workspace.canUndo)
            #expect(workspace.dirty)
            #expect(try workspace.project.validated() == workspace.project)

            workspace.undoEdit()
            #expect(workspace.project == original)
            #expect(!workspace.canUndo)
            #expect(workspace.canRedo)
            workspace.redoEdit()
            #expect(workspace.project.events == [moved, target, otherLane])
        }
    }

    @Test func cancelClearsTheAttractionAndDiscardsAllPreviewState() {
        let (workspace, note, target, _) = fixture()
        let original = workspace.project
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.08, string: 1, screenX: 115,
                                          anchors: [anchor(target, x: 120)], shift: true)
        #expect(workspace.positionMagnetTargetID == target.id)
        workspace.cancelPositionDrag()
        workspace.updatePositionModifiers(shift: true)

        #expect(workspace.positionMagnetTargetID == nil)
        #expect(workspace.positionDrag == nil)
        #expect(workspace.project == original)
        #expect(!workspace.canUndo)
        #expect(!workspace.dirty)
    }

    @Test func unknownIDsCannotManufactureTargetsAndKnownIDsUseProjectTime() {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        let invented = NoteMagnetAnchor(id: UUID(), time: 10, x: 100)
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 100,
                                          anchors: [invented], shift: true)
        #expect(workspace.positionDrag?.time == 3.08)
        #expect(workspace.positionMagnetTargetID == nil)

        let inaccurate = NoteMagnetAnchor(id: target.id, time: 12.5, x: 105)
        workspace.previewMagneticPosition(time: 3.08, string: 4, screenX: 100,
                                          anchors: [invented, inaccurate], shift: true)
        #expect(workspace.positionDrag?.time == target.time)
        #expect(workspace.positionMagnetTargetID == target.id)
    }

    private func fixture() -> (Workspace, TabEvent, TabEvent, TabEvent) {
        let workspace = Workspace()
        let note = TabEvent(time: 2, lane: .left, string: 5, fret: 12,
                            length: .eighth, tentative: true, memo: "벤딩 · 확인")
        let target = TabEvent(time: 3.137, lane: .left, string: 4, fret: 7)
        let otherLane = TabEvent(time: 3.8, lane: .right, string: 2, fret: 8)
        workspace.project = ScoreProject(title: "마그넷 위치 테스트", duration: 20,
                                         events: [note, target, otherLane])
        return (workspace, note, target, otherLane)
    }

    @Test func keyboardModifierEventsUpdateAStationaryDrag() throws {
        let (workspace, note, target, _) = fixture()
        workspace.beginPositionDrag(note)
        workspace.previewMagneticPosition(time: 3.083, string: 4, screenX: 114,
                                          anchors: [anchor(target, x: 120)], shift: false)
        let bridge = TabKeyboardView()
        bridge.workspace = workspace
        let pressed = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift,
                                                   timestamp: 1, windowNumber: 0, context: nil, characters: "",
                                                   charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        bridge.flagsChanged(with: pressed)
        #expect(workspace.positionDrag?.time == target.time)
        let released = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                                                    timestamp: 2, windowNumber: 0, context: nil, characters: "",
                                                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        bridge.flagsChanged(with: released)
        #expect(workspace.positionDrag?.time == 3.083)
        #expect(workspace.positionMagnetTargetID == nil)
    }

    private func anchor(_ note: TabEvent, x: Double) -> NoteMagnetAnchor {
        NoteMagnetAnchor(id: note.id, time: note.time, x: x)
    }
}
