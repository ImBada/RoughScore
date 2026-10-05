import AppKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import RoughScore
@testable import RoughScoreCore

private actor PackagePrepareGate {
    var continuation: CheckedContinuation<PreparedAudio, any Error>?
    var waiter: CheckedContinuation<Void, Never>?
    func prepare() async throws -> PreparedAudio {
        try await withCheckedThrowingContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ audio: PreparedAudio) { continuation?.resume(returning: audio); continuation = nil }
}

@MainActor
@Suite(.serialized)
struct NativeProjectPackageTests {
    private func root() throws -> URL {
        let parent = ProcessInfo.processInfo.environment["ROUGH_SCORE_CACHE_EVIDENCE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = parent.resolvingSymlinksInPath().appendingPathComponent("RoughScore-issue14-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func services() -> WorkspaceServices {
        var services = WorkspaceServices.isolatedCache()
        services.lastProject = { nil }; services.rememberProject = { _ in }; services.initialProject = { nil }
        services.chooseSaveDestination = { _ in nil }
        return services
    }
    private func disk(_ url: URL) throws -> ScoreProject { try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) }
    private func pcm(_ url: URL) throws -> String {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var hash = SHA256()
        for channel in 0..<Int(file.processingFormat.channelCount) {
            hash.update(data: Data(bytes: buffer.floatChannelData![channel], count: Int(buffer.frameLength) * 4))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test func saveAsAndCopyKeepDifferentDurableBaselinesAutosaveHistoryAndSelection() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.roughscore"), new = root.appendingPathComponent("new.roughscore"), copy = root.appendingPathComponent("copy.roughscore")
        let w = Workspace(services: services()); defer { w.shutdown() }
        w.project = ScoreProject(title: "notes", duration: 20)
        #expect(w.saveAs(to: old)); let baseline = w.project
        w.addEvent(time: 1.123456789012, string: 6); w.setMemo("한글\nmanual", eventID: w.selectedID!)
        let edited = w.project, selected = w.selectedIDs, state = w.saveState
        #expect(w.saveCopy(to: copy))
        #expect(w.project == edited && w.selectedIDs == selected && w.dirty && w.canUndo)
        #expect(w.activeProjectURL == old && w.saveState == state)
        #expect(try disk(copy) == edited)
        #expect(try disk(old) == baseline)
        w.undoEdit(); #expect(w.dirty); w.undoEdit(); #expect(!w.dirty && w.project == baseline)
        w.redoEdit(); w.redoEdit(); #expect(w.project == edited)
        await w.awaitAutosave()
        #expect(!w.dirty)
        #expect(try disk(old) == edited)
        #expect(try disk(copy) == edited)
        w.addEvent(time: 2.123456789012, string: 2); let newer = w.project
        #expect(w.saveAs(to: new) && w.activeProjectURL == new && !w.dirty && w.canUndo)
        #expect(try disk(new) == newer)
        #expect(try disk(old) == edited)
        w.addEvent(time: 3.123456789012, string: 4); await w.awaitAutosave()
        #expect(try disk(new) == w.project)
        #expect(try disk(old) == edited)
    }

    @Test func panelIntentFormatsCancellationAndReentryAreInjectable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var requests: [ProjectSaveRequest] = [], chosen: URL?
        var s = services(); s.chooseSaveDestination = { requests.append($0); return chosen }
        let w = Workspace(services: s); defer { w.shutdown() }
        w.project = ScoreProject(title: "panel", duration: 4); w.addEvent(time: 1, string: 6)
        w.saveCopy(format: .collected)
        #expect(requests.last?.action == .saveCopy && requests.last?.format == .collected && w.saveState == .unsaved)
        w.saveAs(format: .linked); #expect(w.saveState == .cancelled && !w.hasSaveLocation)
        chosen = root.appendingPathComponent("panel.roughscorepkg"); w.saveAs(format: .collected)
        #expect(requests.last?.action == .saveAs && requests.last?.format == .collected)
        #expect(w.currentPackageURL == chosen && !w.dirty)
        w.addEvent(time: 2, string: 1); let dirty = w.project
        chosen = root.appendingPathComponent("copy.roughscorepkg"); w.saveCopy(format: .collected)
        #expect(w.project == dirty && w.dirty && w.currentPackageURL != chosen)
        await w.awaitAutosave(); #expect(try PortableProjectPackage.read(at: w.currentPackageURL!).project == dirty)
    }

    @Test func copyFailuresExistingDestinationsAndReentrantWriterDoNotPublishOrAdvanceState() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.roughscore"), denied = root.appendingPathComponent("denied.roughscore")
        var failing = false, owner: Workspace?
        var s = services()
        s.writeProject = { data, url in
            if failing {
                #expect(owner?.saveAs(to: denied) == false)
                try data.write(to: url, options: .atomic)
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        }
        let w = Workspace(services: s); owner = w; defer { w.shutdown(); owner = nil }
        w.project = ScoreProject(title: "original", duration: 5); #expect(w.saveAs(to: old))
        w.addEvent(time: 1, string: 1); let edited = w.project, state = w.saveState
        failing = true
        #expect(!w.saveCopy(to: denied) && w.project == edited && w.dirty && w.saveState == state && w.activeProjectURL == old)
        #expect(!FileManager.default.fileExists(atPath: denied.path))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".roughscore-json-") }))
        failing = false
        let bytes = Data("foreign".utf8); try bytes.write(to: denied)
        #expect(!w.saveCopy(to: denied) && !w.saveAs(to: denied))
        #expect(try Data(contentsOf: denied) == bytes && w.project == edited && w.activeProjectURL == old)
        await w.awaitAutosave(); #expect(try disk(old) == edited)
        #expect(!w.dirty)
    }

    @Test func lateLinkedCollisionAndRevisionChangeProtectOldSession() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("collision.roughscore"), foreign = Data("late foreign".utf8)
        var s = services(); s.writeProject = { data, stage in
            try data.write(to: stage, options: .atomic); try foreign.write(to: target)
        }
        let w = Workspace(services: s); defer { w.shutdown() }
        #expect(!w.saveAs(to: target) && !w.hasSaveLocation && w.dirty)
        #expect(try Data(contentsOf: target) == foreign)
        let other = root.appendingPathComponent("revision.roughscore")
        var owner: Workspace?
        s.writeProject = { data, stage in
            try data.write(to: stage, options: .atomic); owner?.addEvent(time: 1, string: 2)
        }
        let reentrant = Workspace(services: s); owner = reentrant; defer { reentrant.shutdown(); owner = nil }
        #expect(!reentrant.saveAs(to: other) && !reentrant.hasSaveLocation && reentrant.dirty && reentrant.canUndo)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func notesOnlyPackageOrdinarySaveAutosaveAndCommandLineOpen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.roughscorepkg")
        let w = Workspace(services: services()); defer { w.shutdown() }
        w.project = ScoreProject(title: "notes only", duration: 10, events: StemReviewHarness().notes())
        #expect(w.saveAs(to: url, format: .collected) && !w.dirty)
        let bytes = try Data(contentsOf: url.appendingPathComponent("project.json"))
        w.addEvent(time: 4, string: 2); w.save()
        #expect(!w.dirty && w.currentPackageURL == url && w.activeProjectURL == url)
        #expect(try Data(contentsOf: url.appendingPathComponent("project.json")) != bytes)
        w.addEvent(time: 5, string: 4); await w.awaitAutosave()
        #expect(try PortableProjectPackage.read(at: url).project == w.project)
        var s = services(); s.initialProject = { url }
        let opened = Workspace(services: s, awaitsStartup: true); defer { opened.shutdown() }
        #expect(await opened.start()?.value == true)
        #expect(opened.project == w.project && !opened.dirty && opened.prepared == nil && opened.currentPackageURL == url)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".roughscore-") }))
    }

    @Test func nativeMovedPackageKeepsSixPCMChoicesAndCommonHostClock() async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let original = try h.fixture("portable-original", duration: 12, rate: 44_100)
        let stem = try h.fixture("portable-stem", duration: 12, padding: 0.25, rate: 48_000)
        let oldParent = h.evidence.appendingPathComponent("OLD-parent"), newParent = h.evidence.appendingPathComponent("renamed-parent")
        try FileManager.default.createDirectory(at: oldParent, withIntermediateDirectories: false)
        let destination = oldParent.appendingPathComponent("portable.roughscorepkg")
        let w = Workspace(services: h.services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        w.project.events = h.notes(); w.project.tuningDefinition = TuningDefinition(openMIDIPitches: [64,59,55,50,45,38], capo: 2)
        let notes = w.project.events, tuning = w.project.tuningDefinition
        w.select(notes[1]); let selection = w.selectedIDs
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        var before: [String: String] = [:], peaks: [String: [Float]] = [:]
        for role in [AudioAsset.Role.original, .importedGuitarStem] {
            #expect(w.switchAsset(role)); let audio = try #require(w.prepared)
            peaks[role.rawValue] = audio.leftPeaks
            for channel in ListeningSource.allCases { before[role.rawValue + channel.rawValue] = try pcm(audio.url(for: channel)) }
            #expect(try pcm(audio.left) != pcm(audio.right))
        }
        #expect(w.saveAs(to: destination, format: .collected))
        #expect(w.project.events == notes && w.project.tuningDefinition == tuning && w.selectedIDs == selection)
        #expect(w.project.assets?.allSatisfy { $0.reference.kind == .contained } == true && w.project.audioPath == nil)
        #expect(w.project.originalAsset?.identity?.sampleRate == 44_100 && w.project.stemAsset?.identity?.sampleRate == 48_000)
        w.shutdown()
        try FileManager.default.moveItem(at: oldParent, to: newParent)
        // Exclusively owned, generated fixtures. Make every old source pathname unavailable.
        for url in [original.deletingLastPathComponent(), stem.deletingLastPathComponent()] { try FileManager.default.removeItem(at: url) }
        #expect(!FileManager.default.fileExists(atPath: original.path) && !FileManager.default.fileExists(atPath: stem.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let moved = newParent.appendingPathComponent("portable.roughscorepkg")
        let capture = StemReviewCapture(), opened = Workspace(services: h.services(capture)); defer { opened.shutdown() }
        #expect(await opened.loadProject(at: moved)?.value == true && !opened.dirty)
        #expect(opened.currentPackageURL == moved && opened.project.events == notes && opened.project.tuningDefinition == tuning)
        for role in [AudioAsset.Role.original, .importedGuitarStem] {
            #expect(opened.switchAsset(role)); let audio = try #require(opened.prepared)
            #expect(audio.original.resolvingSymlinksInPath().path.hasPrefix(moved.resolvingSymlinksInPath().path + "/Media/"))
            #expect(audio.leftPeaks == peaks[role.rawValue])
            for channel in ListeningSource.allCases { #expect(try pcm(audio.url(for: channel)) == before[role.rawValue + channel.rawValue]) }
        }
        var rows: [[String: Any]] = []
        for rate: Float in [0.5, 0.75, 1] {
            opened.rate = rate; #expect(opened.switchAsset(.original)); opened.switchSource(.stereo); opened.seek(1.7); opened.togglePlayback()
            try await Task.sleep(for: .milliseconds(350))
            for role in [AudioAsset.Role.importedGuitarStem, .original, .importedGuitarStem, .original] {
                let old = try #require(capture.players[opened.prepared!.url(for: opened.source)])
                let beforeClock = try #require(old.graph.inputClockSnapshot()), oldPosition = try #require(beforeClock.positions[opened.source])
                #expect(opened.switchAsset(role))
                try await Task.sleep(for: .milliseconds(120))
                let active = try #require(capture.players[opened.prepared!.url(for: opened.source)])
                let after = try #require(active.graph.inputClockSnapshot()), newPosition = try #require(after.positions[opened.source])
                let elapsed = AVAudioTime.seconds(forHostTime: after.hostTime) - AVAudioTime.seconds(forHostTime: beforeClock.hostTime)
                let error = newPosition - (oldPosition + elapsed * Double(rate))
                #expect(abs(error) <= 0.015, "Moved native package common-host-time error: \(error)s")
                rows.append(["rate": rate, "role": role.rawValue, "errorSeconds": error])
                for channel in ListeningSource.allCases {
                    opened.switchSource(channel); try await Task.sleep(for: .milliseconds(35))
                    let player = try #require(capture.players[opened.prepared!.url(for: channel)])
                    let clock = try #require(player.graph.inputClockSnapshot())
                    #expect(clock.playerFrames.count == 3 && clock.playerFrames.values.max()! - clock.playerFrames.values.min()! <= 1)
                    #expect(player.graph.nativeGains[channel] == 1 && opened.playing)
                }
            }
            opened.togglePlayback()
        }
        #expect(capture.players.count == 6 && opened.project.events == notes)
        try h.record("issue14-moved-native-clock", rows)
        // Offset prepares using contained sourceRoot and preserves the exact note UUIDs.
        #expect(await opened.setStemOffset(-0.5)?.value == true)
        #expect(opened.project.stemAsset?.reference.kind == .contained && opened.project.events == notes)
        opened.save(); #expect(!opened.dirty)
        opened.undoEdit(); #expect(opened.project.stemAsset?.originalTimeOffset == -0.25 && opened.dirty)
        opened.redoEdit(); #expect(opened.project.stemAsset?.originalTimeOffset == -0.5 && !opened.dirty)
        opened.detachStem(); opened.save()
        #expect(opened.project.stemAsset == nil && opened.project.events == notes && !opened.dirty)
        #expect(try PortableProjectPackage.read(at: moved).project == opened.project)
    }

    @Test func packageToLinkedExportsExternalReferencesAndDemoSurvivesShutdown() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("demo.roughscorepkg"), linked = root.appendingPathComponent("demo.roughscore")
        let w = Workspace(services: services()); defer { w.shutdown() }
        #expect(await w.loadDemo()?.value == true)
        let notes = w.project.events
        #expect(w.saveAs(to: package, format: .collected) && w.currentPackageURL == package)
        #expect(w.saveCopy(to: linked) && w.currentPackageURL == package)
        let linkedProject = try disk(linked)
        #expect(linkedProject.assets?.allSatisfy { $0.reference.kind == .external } == true && linkedProject.audioPath != nil && linkedProject.events == notes)
        w.shutdown()
        let opened = Workspace(services: services()); defer { opened.shutdown() }
        #expect(await opened.loadProject(at: linked)?.value == true && opened.prepared != nil && opened.project.events == notes)
        let demoCopy = root.appendingPathComponent("standalone.roughscore")
        let demo = Workspace(services: services()); defer { demo.shutdown() }
        #expect(await demo.loadDemo()?.value == true && demo.saveCopy(to: demoCopy))
        #expect(!demo.hasSaveLocation && demo.isDemo)
        let copied = try disk(demoCopy); demo.shutdown()
        #expect(FileManager.default.fileExists(atPath: copied.audioPath!))
        #expect(await opened.loadProject(at: demoCopy)?.value == true && opened.prepared != nil)
    }

    @Test func cancelledIgnoringPrepareAndIdenticalPackageABAReleaseOnlyStagedResources() async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let audio = try h.fixture("late", duration: 3), package = h.evidence.appendingPathComponent("late.roughscorepkg")
        let initial = Workspace(services: h.services()); defer { initial.shutdown() }
        #expect(await initial.loadAudio(at: audio)?.value == true)
        #expect(initial.saveCopy(to: package, format: .collected))
        let ready = try await AudioPreparation.prepare(try PortableProjectPackage.read(at: package).resolve(assetID: initial.project.originalAsset!.id))
        let gate = PackagePrepareGate(); var s = services(); s.prepare = { _, _ in try await gate.prepare() }
        let w = Workspace(services: s); defer { w.shutdown() }
        let retained = w.project
        let load = try #require(w.loadProject(at: package)); await gate.started(); w.cancelLoading()
        await gate.finish(ready); #expect(!(await load.value))
        #expect(w.project == retained && w.currentPackageURL == nil && !w.hasSaveLocation && !w.canUndo)
        let gate2 = PackagePrepareGate(); s.prepare = { _, _ in try await gate2.prepare() }
        let aba = Workspace(services: s); defer { aba.shutdown() }
        let abaRetained = aba.project
        let load2 = try #require(aba.loadProject(at: package)); await gate2.started()
        let moved = h.evidence.appendingPathComponent("retired.roughscorepkg")
        try FileManager.default.moveItem(at: package, to: moved)
        try FileManager.default.copyItem(at: moved, to: package) // Same JSON/media, different directory identity.
        let prepared = try await AudioPreparation.prepare(try PortableProjectPackage.read(at: package).resolve(assetID: initial.project.originalAsset!.id))
        await gate2.finish(prepared); #expect(!(await load2.value))
        #expect(aba.currentPackageURL == nil && aba.project == abaRetained && !aba.hasSaveLocation)
    }

    @Test func originalAndStemIdentityChangesAtAsyncBoundariesNeverActivateAPackage() async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let original = try h.fixture("identity", duration: 3), stem = try h.fixture("identity-stem", duration: 3, padding: 0.25)
        let package = h.evidence.appendingPathComponent("identity.roughscorepkg")
        let w = Workspace(services: h.services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true)
        #expect(await w.attachStem(at: stem, offset: -0.25)?.value == true)
        #expect(w.saveCopy(to: package, format: .collected))
        var s = h.services(); let prepare = s.prepare
        s.prepare = { url, progress in
            let result = try await prepare(url, progress)
            if url.resolvingSymlinksInPath().path.hasPrefix(package.resolvingSymlinksInPath().path) {
                var data = try Data(contentsOf: url); data[data.count - 4] ^= 1; try data.write(to: url)
            }
            return result
        }
        let opened = Workspace(services: s); defer { opened.shutdown() }
        #expect(await opened.loadProject(at: package)?.value == false && opened.currentPackageURL == nil)
        #expect(opened.prepared == nil && !opened.hasSaveLocation && !opened.canUndo)
    }

    @Test func missingPackageMediaAndMissingCollectionKeepCurrentDocument() async throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let original = try h.fixture("missing", duration: 3), package = h.evidence.appendingPathComponent("missing.roughscorepkg")
        let w = Workspace(services: h.services()); defer { w.shutdown() }
        #expect(await w.loadAudio(at: original)?.value == true && w.saveCopy(to: package, format: .collected))
        let linked = h.evidence.appendingPathComponent("retained.roughscore")
        #expect(w.saveAs(to: linked))
        let snapshot = try PortableProjectPackage.read(at: package)
        try FileManager.default.removeItem(at: snapshot.resolve(assetID: snapshot.project.originalAsset!.id))
        let before = w.project, generation = w.prepared?.generation
        // A durable baseline avoids the real unsaved-changes dialog in this hidden native test.
        #expect(await w.loadProject(at: package)?.value == false)
        #expect(w.project == before && w.prepared?.generation == generation && w.currentPackageURL == nil)
        try FileManager.default.removeItem(at: original)
        #expect(!w.saveAs(to: h.evidence.appendingPathComponent("missing-copy.roughscorepkg"), format: .collected))
        #expect(w.project == before && w.activeProjectURL == linked && w.currentPackageURL == nil)
    }

    @Test func actualHostedSaveControlsInvokeNativeIntent() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        var requests: [ProjectSaveRequest] = []
        var s = services(); s.chooseSaveDestination = { requests.append($0); return nil }
        let w = Workspace(services: s); defer { w.shutdown() }
        let host = NotePointerTests.Host(ProjectSaveMenu(workspace: w), height: 80, width: 520)
        defer { host.close() }; host.settle()
        let menu = try #require(host.descendants().compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "project-save-menu" })
        let actions = try #require(menu.menu).items.filter { $0.target is BulkActionMenu.Coordinator }
        #expect(actions.count == 4)
        for entry in actions { NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry) }
        #expect(requests.count == 4 && requests.filter { $0.action == .saveAs }.count == 2 && requests.filter { $0.action == .saveCopy }.count == 2)
        #expect(requests.filter { $0.format == .collected }.count == 2)
    }

    @Test func activeLinkedFailureAfterWritingItsStagePreservesDurableBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("active.roughscore")
        var fail = false
        var s = services(); s.writeProject = { data, url in
            try data.write(to: url, options: .atomic)
            if fail { throw CocoaError(.fileWriteNoPermission) }
        }
        let w = Workspace(services: s); defer { w.shutdown() }
        w.project = ScoreProject(title: "active", duration: 4)
        #expect(w.saveAs(to: destination))
        let bytes = try Data(contentsOf: destination)
        w.addEvent(time: 1.123456789, string: 2); let edit = w.project
        fail = true
        #expect(!w.save(to: destination) && w.project == edit && w.dirty && w.canUndo)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".roughscore-write-") })
        fail = false; w.save()
        #expect(try disk(destination) == edit)
        #expect(!w.dirty)
    }

    @Test func changedLinkedStageCannotPublishOverAnActiveOrNewDestination() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("active.roughscore")
        let expected = ScoreProject(title: "old", duration: 4)
        let old = try JSONEncoder().encode(expected)
        try old.write(to: destination)
        var candidate = expected; candidate.title = "new"
        let bytes = try JSONEncoder().encode(candidate)
        var stage: URL?
        let write: (Data, URL) throws -> Void = { data, url in stage = url; try data.write(to: url) }
        let mutate: () throws -> Void = {
            let url = try #require(stage)
            try FileManager.default.removeItem(at: url)
            try Data("replacement".utf8).write(to: url)
        }
        #expect(throws: (any Error).self) {
            try LinkedProjectWriter.replace(bytes, at: destination, expected: expected, write: write, cancellation: mutate)
        }
        #expect(try Data(contentsOf: destination) == old)
        let copy = root.appendingPathComponent("copy.roughscore")
        #expect(throws: (any Error).self) {
            try LinkedProjectWriter.create(bytes, at: copy, write: write, cancellation: mutate)
        }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }
}
