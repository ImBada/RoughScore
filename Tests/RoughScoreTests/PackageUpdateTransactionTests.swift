import AVFoundation
import Foundation
import Testing
@testable import RoughScoreCore

struct PackageUpdateTransactionTests {
    private func fixture() throws -> (URL, PortableProjectPackage.Snapshot) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoughScore-package-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 16000) }
        buffer.floatChannelData![0][4000] = 0.8; buffer.floatChannelData![1][5000] = -0.6
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer); file.close()
        let project = ScoreProject(title: "portable", audioPath: source.path, duration: 2,
                                   events: [TabEvent(time: 0.5000000123, lane: .right, string: 2, memo: "한글\n?")])
        let snapshot = try PortableProjectPackage.collect(project, to: root.appendingPathComponent("active.roughscorepkg"))
        return (root, snapshot)
    }

    @Test func metadataOnlyUpdateKeepsMediaAndRejectsTheOldReceipt() throws {
        let (root, initial) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try initial.resolve(assetID: initial.project.originalAsset!.id)
        let before = try Data(contentsOf: media)
        var candidate = initial.project
        candidate.events[0].memo = "new memo"; candidate.tuningDefinition = .standard
        var copied = false
        let updated = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
            if case .copying = $0 { copied = true }
        }))
        #expect(!copied && updated.project == candidate)
        #expect(try Data(contentsOf: media) == before)
        try updated.validate()
        #expect(throws: PortableProjectPackage.PackageError.sourceChanged) { try initial.validate() }
        #expect(throws: PortableProjectPackage.PackageError.sourceChanged) {
            _ = try PortableProjectPackage.update(candidate, replacing: initial)
        }
    }

    @Test func metadataFailuresAndCancellationLeaveTheDurablePackageIntact() throws {
        let (root, initial) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let json = initial.root.appendingPathComponent("project.json")
        let before = try Data(contentsOf: json)
        var candidate = initial.project; candidate.events[0].fret = 12
        for checkpoint in [PortableProjectPackage.Checkpoint.writingProject, .validating, .committing] {
            #expect(throws: CocoaError.self) {
                _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                    if $0 == checkpoint { throw CocoaError(.fileWriteNoPermission) }
                }))
            }
            #expect(try Data(contentsOf: json) == before)
            try initial.validate()
            #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".roughscore-") })
        }
        #expect(throws: CancellationError.self) {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, cancellation: { throw CancellationError() })
        }
        #expect(try Data(contentsOf: json) == before)
    }

    @Test func replacingResourcesPublishesOnlyTheCompleteNewPackage() throws {
        let (root, initial) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let oldBytes = try Data(contentsOf: initial.root.appendingPathComponent("project.json"))
        let source = root.appendingPathComponent("original.caf")
        let stem = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: source.path), originalTimeOffset: -0.25)
        let candidate = try initial.project.attachingStem(stem)
        #expect(throws: CocoaError.self) {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .committing { throw CocoaError(.fileWriteNoPermission) }
            }))
        }
        #expect(try Data(contentsOf: initial.root.appendingPathComponent("project.json")) == oldBytes)
        try initial.validate()
        let updated = try PortableProjectPackage.update(candidate, replacing: initial)
        #expect(updated.project.stemAsset?.originalTimeOffset == -0.25)
        #expect(updated.project.assets?.allSatisfy { $0.reference.kind == .contained } == true)
        #expect(updated.project.events == initial.project.events)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".roughscore-") })
    }
}
