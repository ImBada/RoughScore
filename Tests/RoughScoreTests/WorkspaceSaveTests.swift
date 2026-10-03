import AVFoundation
import Foundation
import RoughScoreCore
import Testing
@testable import RoughScore

private actor SaveAudioGate {
    private var continuation: CheckedContinuation<PreparedAudio, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func prepare() async throws -> PreparedAudio {
        try await withCheckedThrowingContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ result: Result<PreparedAudio, any Error>) {
        continuation?.resume(with: result); continuation = nil
    }
}

@MainActor
private struct SaveFixture {
    let root: URL
    let url: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("saved.roughscore")
    }
    func write(_ project: ScoreProject) throws { try JSONEncoder().encode(project).write(to: url, options: .atomic) }
    func read() throws -> ScoreProject { try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: url)) }
    func services() -> WorkspaceServices {
        var services = WorkspaceServices.live
        services.rememberProject = { _ in }
        services.lastProject = { nil }
        services.chooseSaveDestination = { _ in nil }
        return services
    }
    func audio(duration: Double) throws -> PreparedAudio {
        let original = root.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 8_000)
        try AVAudioFile(forWriting: original, settings: format.settings).write(from: buffer)
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PreparedAudio(original: original, left: original, right: original, directory: directory,
                             duration: duration, isMono: true, leftPeaks: [0], rightPeaks: [0])
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct WorkspaceSaveTests {
    @Test func relinkThenInputUndoKeepsMetadataDirtyUntilDiskMatches() async throws {
        let f = try SaveFixture(); defer { f.clean() }
        let manual = TabEvent(time: 1.213456789, lane: .right, string: 3, memo: "manual unknown")
        let identity = AudioContentIdentity(sha256: String(repeating: "a", count: 64), channelCount: 1,
                                            sampleRate: 8_000, frameCount: 160_000)
        let asset = AudioAsset(reference: AudioReference(path: "/missing/old.caf"), identity: identity)
        var disk = ScoreProject(title: "saved", audioPath: asset.reference.path, duration: 20,
                                events: [manual], analyses: ["stereo": AnalysisSummary(bpm: 123, provenance:
                                    AnalysisProvenance(assetID: asset.id, identity: identity, channel: "stereo", analyzerVersion: "historical-test-v1"))])
        disk.assets = [asset] // Proven historical analysis may remain available while its source is missing.
        try f.write(disk)
        let audio = try f.audio(duration: 21)
        var services = f.services(); services.prepare = { _, _ in audio }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: f.url)?.value == true)
        #expect(!workspace.dirty && workspace.saveState == .saved)
        #expect(await workspace.loadAudio(at: audio.original, relink: true)?.value == true)
        workspace.addEvent(time: 3, string: 6); workspace.inputDigit(1, at: 100); workspace.inputDigit(2, at: 100.1)
        workspace.undoEdit()
        #expect(workspace.project.events == [manual])
        #expect(workspace.project.audioPath == audio.original.path && workspace.project.duration == 21)
        #expect(workspace.project.analyses.isEmpty)
        #expect(workspace.dirty && workspace.saveState == .pending)
        #expect(try f.read() == disk)
        await workspace.awaitAutosave()
        #expect(try f.read() == workspace.project)
        #expect(!workspace.dirty && workspace.saveState == .saved)
    }

    @Test(arguments: [false, true]) func failedOrCancelledRelinkResumesDebouncedEdit(cancel: Bool) async throws {
        let f = try SaveFixture(); defer { f.clean() }
        let disk = ScoreProject(title: "retained", duration: 20); try f.write(disk)
        let gate = SaveAudioGate()
        var services = f.services(); services.prepare = { _, _ in try await gate.prepare() }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: f.url)?.value == true)
        workspace.addEvent(time: 1.213, string: 2); workspace.inputDigit(0, at: 100)
        let expected = workspace.project
        let task = try #require(workspace.loadAudio(at: f.root.appendingPathComponent("relink.caf"), relink: true))
        await gate.started()
        workspace.save() // Saving while busy must not consume the retained edit's pending autosave.
        try await Task.sleep(for: .milliseconds(900))
        #expect(try f.read() == disk)
        if cancel { workspace.cancelLoading() }
        await gate.finish(.failure(AudioIssue.unsupported))
        #expect(!(await task.value))
        #expect(workspace.dirty)
        await workspace.awaitAutosave()
        #expect(try f.read() == expected)
        #expect(workspace.project == expected && !workspace.dirty && workspace.saveState == .saved)
    }

    @Test func openingAudioWithDifferentDurationRetainsDecodedBaseline() async throws {
        let f = try SaveFixture(); defer { f.clean() }
        let audio = try f.audio(duration: 21)
        let disk = ScoreProject(title: "normalized", audioPath: audio.original.path, duration: 20,
                                analyses: ["stereo": AnalysisSummary(bpm: 120)])
        try f.write(disk)
        var services = f.services(); services.prepare = { _, _ in audio }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: f.url)?.value == true)
        #expect(workspace.dirty && workspace.project.duration == 21 && workspace.project.analyses.isEmpty)
        #expect(try f.read() == disk)
        await workspace.awaitAutosave()
        #expect(try f.read() == workspace.project)
        #expect(!workspace.dirty)
    }

    @Test func atomicFailureAndSaveCancellationKeepLocationBaselineAndFile() async throws {
        let f = try SaveFixture(); defer { f.clean() }
        let disk = ScoreProject(title: "old", duration: 20); try f.write(disk)
        let originalBytes = try Data(contentsOf: f.url)
        var services = f.services()
        services.writeProject = { data, url in
            if url.lastPathComponent != "saved.roughscore" { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        let workspace = Workspace(services: services); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: f.url)?.value == true)
        workspace.addEvent(time: 2, string: 1)
        let other = f.root.appendingPathComponent("denied.roughscore")
        #expect(!workspace.save(to: other))
        #expect(workspace.dirty && workspace.hasSaveLocation && workspace.saveState == .failed)
        #expect(try Data(contentsOf: f.url) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: other.path))
        workspace.undoEdit()
        #expect(!workspace.dirty) // Failed save never advanced the durable baseline.
        workspace.redoEdit(); workspace.save()
        #expect(try f.read() == workspace.project && !workspace.dirty)

        let unsaved = Workspace(services: f.services()); defer { unsaved.shutdown() }
        unsaved.project = ScoreProject(title: "new", duration: 20)
        unsaved.addEvent(time: 2, string: 1); unsaved.save()
        #expect(unsaved.dirty && !unsaved.hasSaveLocation && unsaved.saveState == .cancelled)
        unsaved.undoEdit()
        #expect(unsaved.dirty) // No durable save ever existed.
    }

    @Test func actualAtomicWriteFailurePreservesExistingDocument() async throws {
        let f = try SaveFixture(); defer { f.clean() }
        let disk = ScoreProject(title: "old", duration: 20); try f.write(disk)
        let bytes = try Data(contentsOf: f.url)
        let workspace = Workspace(services: f.services()); defer { workspace.shutdown() }
        #expect(await workspace.loadProject(at: f.url)?.value == true)
        workspace.addEvent(time: 2, string: 6)
        let missingParent = f.root.appendingPathComponent("missing/denied.roughscore")
        #expect(!workspace.save(to: missingParent))
        #expect(workspace.dirty && workspace.saveState == .failed)
        #expect(try Data(contentsOf: f.url) == bytes)
        workspace.save()
        #expect(try f.read() == workspace.project && !workspace.dirty)
    }
}
