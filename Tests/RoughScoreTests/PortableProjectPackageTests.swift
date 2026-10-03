import AVFoundation
import CryptoKit
import Darwin
import Foundation
@testable import RoughScoreCore
import Testing

@Suite(.serialized)
struct PortableProjectPackageTests {
    private final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("RoughScore-portable-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func audio(_ path: String, channels: AVAudioChannelCount = 2, frames: Int = 16_000, padding: Int = 0) throws -> URL {
            let url = url(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: channels))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(channels) {
                for i in 0..<frames {
                    buffer.floatChannelData![channel][i] = i < padding ? 0 : Float(sin(Double(i - padding) * (channel == 0 ? 0.13 : 0.21)) * 0.2)
                }
            }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            return url
        }
        func project(_ original: URL, stem: URL? = nil) throws -> ScoreProject {
            var project = ScoreProject(title: "대충 채보 · portable", audioPath: original.path, duration: 2, events: [
                TabEvent(time: 0.9, lane: .left, string: 6, fret: 3, memo: "첫 줄\n둘째 줄 · 한국어"),
                TabEvent(time: 1.213456789, lane: .right, string: 2, tentative: true, memo: "아직 모름")
            ])
            let identity = try identity(original)
            let originalAsset = AudioAsset(reference: AudioReference(path: original.path), identity: identity)
            project.assets = [originalAsset]
            if let stem {
                project.assets!.append(AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: stem.path),
                                                  identity: try self.identity(stem), originalTimeOffset: -0.25))
            }
            project.tuning = ["E", "B", "G", "D", "A", "D"]
            project.tuningDefinition = TuningDefinition(openMIDIPitches: [64, 59, 55, 50, 45, 38], capo: 2)
            project.analyses["left"] = AnalysisSummary(beats: [0.3, 1.2], provenance: AnalysisProvenance(
                assetID: originalAsset.id, identity: identity, channel: "left", analyzerVersion: "fixture-v1", settings: "custom"))
            if let stemAsset = project.assets?.last, stem != nil {
                project.analyses["right"] = AnalysisSummary(key: "D", provenance: AnalysisProvenance(
                    assetID: stemAsset.id, identity: stemAsset.identity!, channel: "right", analyzerVersion: "stem-fixture-v1"))
            }
            return try project.validated()
        }
        func identity(_ url: URL) throws -> AudioContentIdentity {
            let audio = try AVAudioFile(forReading: url)
            return AudioContentIdentity(sha256: try hash(url), channelCount: Int(audio.processingFormat.channelCount),
                                        sampleRate: audio.processingFormat.sampleRate, frameCount: audio.length)
        }
        func hash(_ url: URL) throws -> String {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func mutate(_ package: URL, _ change: (inout [String: Any]) -> Void) throws {
            let json = package.appendingPathComponent("project.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            change(&object)
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: json)
        }
        func children() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
    }
    private enum Failure: Error { case injected }

    @Test func stereoOriginalAndPaddedMonoStemRelocateWithoutSourcePaths() throws {
        let f = try Fixture()
        let original = try f.audio("sources/a/same.caf")
        let stem = try f.audio("sources/b/same.caf", channels: 1, frames: 18_000, padding: 2_000)
        let project = try f.project(original, stem: stem)
        let before = try [f.hash(original), f.hash(stem)]
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("first.roughscorepkg"))
        #expect(snapshot.project.events == project.events)
        #expect(snapshot.project.tuningDefinition == project.tuningDefinition && snapshot.project.tuning == project.tuning)
        #expect(snapshot.project.analyses == project.analyses && snapshot.project.duration == project.duration)
        #expect(snapshot.project.assets?.map(\.id) == project.assets?.map(\.id))
        #expect(snapshot.project.assets?.map(\.identity) == project.assets?.map(\.identity))
        #expect(snapshot.project.assets?.map(\.originalTimeOffset) == [0, -0.25])
        #expect(snapshot.project.audioPath == nil && snapshot.project.events[1].fret == nil && snapshot.project.events[1].length == nil)
        let json = try String(contentsOf: snapshot.root.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(!json.contains(original.path) && !json.contains(stem.path))
        #expect(try f.hash(original) == before[0] && f.hash(stem) == before[1])
        try FileManager.default.createDirectory(at: f.url("relocated"), withIntermediateDirectories: false)
        let moved = f.url("relocated/moved.roughscorepkg")
        try FileManager.default.moveItem(at: snapshot.root, to: moved)
        try FileManager.default.removeItem(at: f.url("sources")) // Only fixtures generated by this test.
        let reopened = try PortableProjectPackage.read(at: moved)
        #expect(reopened.project == snapshot.project)
        for (index, asset) in try #require(reopened.project.assets).enumerated() {
            let resolved = try reopened.resolve(assetID: asset.id)
            #expect(resolved.pathComponents.starts(with: moved.pathComponents))
            #expect(try f.hash(resolved) == before[index])
            let audio = try AVAudioFile(forReading: resolved)
            #expect(audio.length == asset.identity?.frameCount)
            #expect(Int(audio.processingFormat.channelCount) == asset.identity?.channelCount)
        }
        let stemURL = try reopened.resolve(assetID: project.assets![1].id)
        let file = try AVAudioFile(forReading: stemURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_001))
        try file.read(into: buffer)
        #expect((0..<2_000).allSatisfy { buffer.floatChannelData![0][$0] == 0 })
        // Recollect a contained project using its explicit root, preserving independent identities.
        let recollected = try PortableProjectPackage.collect(reopened.project, to: f.url("copy.roughscorepkg"), sourceRoot: moved)
        #expect(recollected.project == reopened.project)
    }

    @Test func legacyV1MintsAssetButNeverGuessesTuningOrAnalysisIdentity() throws {
        let f = try Fixture(); let original = try f.audio("source.wav", channels: 1)
        var legacy = ScoreProject(title: "v1", audioPath: original.path, duration: 2,
                                  events: [TabEvent(time: 0.9, lane: .right, string: 6, memo: "미정\n메모")],
                                  analyses: ["stereo": AnalysisSummary(beats: [1])])
        legacy.tuning = ["E", "B", "G", "D", "A", "D"]
        let decoded = try JSONDecoder().decode(ScoreProject.self, from: JSONEncoder().encode(legacy))
        let snapshot = try PortableProjectPackage.collect(decoded, to: f.url("legacy.roughscorepkg"))
        #expect(snapshot.project.events == legacy.events && snapshot.project.tuning == legacy.tuning)
        #expect(snapshot.project.tuningDefinition == nil && snapshot.project.soundingMIDI(string: 6, fret: 0) == nil)
        #expect(snapshot.project.originalAsset?.identity == (try f.identity(original)))
        #expect(snapshot.project.analyses.isEmpty)
        #expect(legacy.assets == nil && legacy.audioPath == original.path)
        var malformed = legacy; malformed.audioPath = "relative.caf"
        #expect(throws: ProjectError.self) {
            try PortableProjectPackage.collect(malformed, to: f.url("relative.roughscorepkg"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.url("relative.roughscorepkg").path))
    }

    @Test func noMediaIsExplicitButMissingDeclaredMediaFails() throws {
        let f = try Fixture(); let notes = ScoreProject(events: [TabEvent(time: 0.9, lane: .left, string: 3)])
        let snapshot = try PortableProjectPackage.collect(notes, to: f.url("notes.roughscorepkg"))
        #expect(try PortableProjectPackage.read(at: snapshot.root).project == notes)
        #expect(throws: PortableProjectPackage.PackageError.self) { try snapshot.resolve(assetID: UUID()) }
        var offline = notes; offline.audioPath = f.url("missing.caf").path
        #expect(throws: (any Error).self) { try PortableProjectPackage.collect(offline, to: f.url("offline.roughscorepkg")) }
        #expect(!FileManager.default.fileExists(atPath: f.url("offline.roughscorepkg").path))
        #expect(try f.children() == ["notes.roughscorepkg"])
    }

    @Test func contradictedIdentityAndOnlyItsProvenanceAreReplaced() throws {
        let f = try Fixture(); let original = try f.audio("original.caf"); let stem = try f.audio("stem.caf", channels: 1)
        let project = try f.project(original, stem: stem)
        try FileManager.default.removeItem(at: original)
        _ = try f.audio("original.caf", frames: 17_000)
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("changed.roughscorepkg"))
        #expect(snapshot.project.originalAsset?.identity != project.originalAsset?.identity)
        #expect(snapshot.project.assets?[1].identity == project.assets?[1].identity)
        #expect(snapshot.project.analyses["left"] == nil && snapshot.project.analyses["right"] == project.analyses["right"])
        #expect(snapshot.project.events == project.events && project.analyses["left"] != nil)
    }

    @Test func writerFailureAndCancellationPreserveSourceAndForeignStaging() throws {
        let f = try Fixture(); let original = try f.audio("original.caf", frames: 300_000)
        let project = try f.project(original); let hash = try f.hash(original)
        try FileManager.default.createDirectory(at: f.url(".roughscore-stage-foreign"), withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: f.url(".roughscore-stage-foreign/keep"))
        for phase in [PortableProjectPackage.Checkpoint.copying(1), .writingProject, .validating, .committing] {
            for cancelled in [false, true] {
                var cancel = false; var reached = false
                let hooks = PortableProjectPackage.Hooks(checkpoint: { checkpoint in
                    if checkpoint == phase {
                        reached = true
                        if cancelled { cancel = true } else { throw Failure.injected }
                    }
                })
                #expect(throws: (any Error).self) {
                    try PortableProjectPackage.collect(project, to: f.url("failed.roughscorepkg"),
                        cancellation: { if cancel { throw CancellationError() } }, hooks: hooks)
                }
                #expect(reached)
                #expect(try f.hash(original) == hash)
                #expect(try f.children() == [".roughscore-stage-foreign", "original.caf"])
                #expect(try Data(contentsOf: f.url(".roughscore-stage-foreign/keep")) == Data("foreign".utf8))
            }
        }
    }

    @Test func realDestinationCollisionsAndFinalCommitRaceAreExclusive() throws {
        let f = try Fixture(); let source = try f.audio("original.caf"); let project = try f.project(source)
        let destination = f.url("existing.roughscorepkg")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let marker = destination.appendingPathComponent("untouched")
        try Data("baseline".utf8).write(to: marker)
        #expect(throws: PortableProjectPackage.PackageError.destinationExists) {
            try PortableProjectPackage.collect(project, to: destination)
        }
        #expect(try Data(contentsOf: marker) == Data("baseline".utf8))
        let race = f.url("race.roughscorepkg")
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            if phase == .committing {
                try FileManager.default.createDirectory(at: race, withIntermediateDirectories: false)
                try Data("racer".utf8).write(to: race.appendingPathComponent("keep"))
            }
        })
        #expect(throws: PortableProjectPackage.PackageError.destinationExists) {
            try PortableProjectPackage.collect(project, to: race, hooks: hooks)
        }
        #expect(try Data(contentsOf: race.appendingPathComponent("keep")) == Data("racer".utf8))
        #expect(try f.children() == ["existing.roughscorepkg", "original.caf", "race.roughscorepkg"])
    }

    @Test func missingReadonlyParentAndInvalidDestinationDoNotChangeAnything() throws {
        let f = try Fixture(); let source = try f.audio("source.caf"); let project = try f.project(source)
        #expect(throws: (any Error).self) { try PortableProjectPackage.collect(project, to: f.url("missing/new.roughscorepkg")) }
        #expect(throws: PortableProjectPackage.PackageError.invalidDestination) {
            try PortableProjectPackage.collect(project, to: f.url("wrong.json"))
        }
        let readonly = f.url("readonly")
        try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: false)
        guard chmod(readonly.path, 0o500) == 0 else { throw Failure.injected }
        defer { chmod(readonly.path, 0o700) }
        #expect(geteuid() != 0) // This actual permission-denial test requires a non-root test runner.
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(project, to: readonly.appendingPathComponent("new.roughscorepkg"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: readonly.path).isEmpty)
    }

    @Test func corruptSourceAndSourceMutationNeverCommit() throws {
        let f = try Fixture(); let corrupt = f.url("bad.caf"); try Data("not audio".utf8).write(to: corrupt)
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(ScoreProject(audioPath: corrupt.path), to: f.url("bad.roughscorepkg"))
        }
        let source = try f.audio("source.caf", frames: 300_000); let project = try f.project(source)
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            if phase == .copying(1) {
                let handle = try FileHandle(forWritingTo: source); defer { try? handle.close() }
                try handle.seek(toOffset: 100); try handle.write(contentsOf: Data([0, 1, 2, 3]))
            }
        })
        #expect(throws: (any Error).self) { try PortableProjectPackage.collect(project, to: f.url("mutation.roughscorepkg"), hooks: hooks) }
        #expect(try f.children() == ["bad.caf", "source.caf"])
    }

    @Test func readerRejectsMalformedJSONUnsupportedSchemaAndMissingOrChangedBytes() throws {
        let f = try Fixture(); let source = try f.audio("source.caf"); let project = try f.project(source)
        for mutation in 0..<6 {
            let snapshot = try PortableProjectPackage.collect(project, to: f.url("case\(mutation).roughscorepkg"))
            let resource = try snapshot.resolve(assetID: project.originalAsset!.id)
            switch mutation {
            case 0: try Data("{broken".utf8).write(to: snapshot.root.appendingPathComponent("project.json"))
            case 1: try f.mutate(snapshot.root) { $0["version"] = 99 }
            case 2: try f.mutate(snapshot.root) { var p = $0["project"] as! [String: Any]; p["version"] = 99; $0["project"] = p }
            case 3: try FileManager.default.removeItem(at: resource)
            case 4: try Data("corrupt".utf8).write(to: resource)
            default: try Data("unexpected".utf8).write(to: snapshot.root.appendingPathComponent("extra"))
            }
            #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root) }
            if mutation == 3 || mutation == 4 {
                #expect(throws: (any Error).self) { try snapshot.resolve(assetID: project.originalAsset!.id) }
            }
        }
    }

    @Test func maliciousReferencesAndSymlinkSiblingEscapesAreNeverFollowed() throws {
        let f = try Fixture(); let source = try f.audio("source.caf"); let project = try f.project(source)
        for (index, path) in ["../source.caf", source.path, "Media/../../source.caf", "Media\\source.caf", "Media//file.caf", "Media/./file.caf"].enumerated() {
            let snapshot = try PortableProjectPackage.collect(project, to: f.url("malicious\(index).roughscorepkg"))
            try f.mutate(snapshot.root) {
                var p = $0["project"] as! [String: Any]; var assets = p["assets"] as! [[String: Any]]
                assets[0]["reference"] = ["kind": "contained", "path": path]; p["assets"] = assets; $0["project"] = p
            }
            #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root) }
        }
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("escape.roughscorepkg"))
        let resource = try snapshot.resolve(assetID: project.originalAsset!.id)
        // A sibling with the same textual prefix must not count as contained.
        let sibling = f.url("escape.roughscorepkg-sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: resource, to: sibling.appendingPathComponent(resource.lastPathComponent))
        try FileManager.default.removeItem(at: snapshot.root.appendingPathComponent("Media"))
        try FileManager.default.createSymbolicLink(at: snapshot.root.appendingPathComponent("Media"), withDestinationURL: sibling)
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root) }
        #expect(throws: (any Error).self) { try snapshot.resolve(assetID: project.originalAsset!.id) }
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(snapshot.project, to: f.url("escaped-copy.roughscorepkg"), sourceRoot: snapshot.root)
        }
        let safe = try PortableProjectPackage.collect(project, to: f.url("safe.roughscorepkg"))
        let safeResource = try safe.resolve(assetID: project.originalAsset!.id)
        try FileManager.default.removeItem(at: safeResource)
        try FileManager.default.createSymbolicLink(at: safeResource, withDestinationURL: source)
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: safe.root) }
        let rootLink = f.url("root-link.roughscorepkg")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: safe.root)
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: rootLink) }
    }

    @Test func sparseLargeWAVUsesStreamingCopyAndRealDecodedFrames() throws {
        let f = try Fixture(); let source = f.url("large.wav")
        let bytes: UInt32 = 64 * 1_048_576
        var header = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        u32(bytes + 36); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(48_000); u32(192_000); u16(4); u16(16); header.append(Data("data".utf8)); u32(bytes)
        try header.write(to: source)
        let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: UInt64(bytes) + 44); try handle.close()
        var chunks = 0
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            if case let .copying(count) = phase { chunks = count }
        })
        let project = ScoreProject(audioPath: source.path, duration: Double(bytes / 4) / 48_000)
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("large.roughscorepkg"), hooks: hooks)
        #expect(chunks == 65 && PortableProjectPackage.copyChunkBytes == 1_048_576)
        #expect(snapshot.project.originalAsset?.identity?.frameCount == Int64(bytes / 4))
        let resolved = try snapshot.resolve(assetID: snapshot.project.originalAsset!.id)
        #expect(try f.hash(resolved) == f.hash(source))
    }

    @Test func generatedAACCollectsAndMatchesExistingAudioMetadata() throws {
        let f = try Fixture(); let wav = try f.audio("aac-source.wav")
        let aac = f.url("generated.m4a")
        let converter = Process(); converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [wav.path, aac.path, "-f", "m4af", "-d", "aac@44100", "-b", "128000"]
        try converter.run(); converter.waitUntilExit()
        #expect(converter.terminationStatus == 0)
        let project = try f.project(aac)
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("aac.roughscorepkg"))
        #expect(snapshot.project.originalAsset?.identity == project.originalAsset?.identity)
        #expect(snapshot.project.analyses == project.analyses)
        let resolved = try snapshot.resolve(assetID: project.originalAsset!.id)
        #expect(try f.hash(resolved) == f.hash(aac))
    }

    @Test func readerAndResolverCancellationDoNotMutatePackage() throws {
        let f = try Fixture(); let source = try f.audio("source.caf", frames: 300_000)
        let project = try f.project(source)
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("cancel.roughscorepkg"))
        let json = snapshot.root.appendingPathComponent("project.json")
        let before = try f.hash(json)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try PortableProjectPackage.read(at: snapshot.root, cancellation: {
                checks += 1; if checks == 3 { throw CancellationError() }
            })
        }
        #expect(checks == 3)
        #expect(try f.hash(json) == before)
        #expect(throws: CancellationError.self) {
            try snapshot.resolve(assetID: project.originalAsset!.id, cancellation: { throw CancellationError() })
        }
        #expect(try PortableProjectPackage.read(at: snapshot.root).project == snapshot.project)
    }


    @Test func enumerationIOFailureAfterExpectedEntriesFailsReaderAndWriterClosed() throws {
        let f = try Fixture(); let project = ScoreProject()
        let snapshot = try PortableProjectPackage.collect(project, to: f.url("valid.roughscorepkg"))
        let before = try f.hash(snapshot.root.appendingPathComponent("project.json"))
        var reachedEnd = false
        let hooks = PortableProjectPackage.Hooks(readDirectory: { stream in
            let entry = readdir(stream)
            if entry == nil { reachedEnd = true; errno = EIO }
            return entry
        })
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root, hooks: hooks) }
        #expect(reachedEnd)
        reachedEnd = false
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(project, to: f.url("failed.roughscorepkg"), hooks: hooks)
        }
        #expect(reachedEnd)
        #expect(try f.children() == ["valid.roughscorepkg"])
        #expect(try f.hash(snapshot.root.appendingPathComponent("project.json")) == before)
        #expect(try PortableProjectPackage.read(at: snapshot.root).project == project)
    }

    private func stage(_ parent: URL) throws -> URL {
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: parent.path).first { $0.hasPrefix(".roughscore-stage-") })
        return parent.appendingPathComponent(name)
    }

    @Test func cleanupMustPreserveForeignStageWhenParentPathIsRebound() throws {
        let f = try Fixture(); let root = f.root
        let parent = root.appendingPathComponent("parent")
        let displaced = root.appendingPathComponent("displaced")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        var foreignMarker: URL?
        var reached = false
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            if phase == .committing {
                reached = true
                let owned = try stage(parent)
                try FileManager.default.moveItem(at: parent, to: displaced)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                let foreign = parent.appendingPathComponent(owned.lastPathComponent)
                try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
                let marker = foreign.appendingPathComponent("foreign.txt")
                try Data("FOREIGN MUST SURVIVE".utf8).write(to: marker)
                foreignMarker = marker
                throw Failure.injected
            }
        })
        #expect(throws: Failure.injected) {
            try PortableProjectPackage.collect(ScoreProject(), to: parent.appendingPathComponent("out.roughscorepkg"), hooks: hooks)
        }
        #expect(reached)
        let marker = try #require(foreignMarker)
        print("REVIEW_PARENT_REBOUND foreignMarkerExists=\(FileManager.default.fileExists(atPath: marker.path)) displacedOwnedStageCount=\(try FileManager.default.contentsOfDirectory(atPath: displaced.path).count)")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: marker) == Data("FOREIGN MUST SURVIVE".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
    }

    @Test func writerMustRejectStagedJSONMutationAfterValidationBeforeRename() throws {
        let f = try Fixture(); let root = f.root
        let destination = root.appendingPathComponent("out.roughscorepkg")
        var reached = false
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            if phase == .committing {
                reached = true
                try Data("{broken".utf8).write(to: stage(root).appendingPathComponent("project.json"))
            }
        })
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(ScoreProject(), to: destination, hooks: hooks)
        }
        #expect(reached)
        print("REVIEW_COMMIT_MUTATION destinationExists=\(FileManager.default.fileExists(atPath: destination.path))")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: destination) }
    }

    @Test func readerMustRejectUndeclaredEntryInsertedAtEnumerationEOF() throws {
        let f = try Fixture(); let root = f.root
        let destination = root.appendingPathComponent("out.roughscorepkg")
        _ = try PortableProjectPackage.collect(ScoreProject(), to: destination)
        var reached = false
        let hooks = PortableProjectPackage.Hooks(readDirectory: { stream in
            let entry = readdir(stream)
            if entry == nil && !reached {
                reached = true
                try! Data("UNDECLARED".utf8).write(to: destination.appendingPathComponent("foreign.txt"))
                errno = 0
            }
            return entry
        })
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: destination, hooks: hooks) }
        #expect(reached)
        print("REVIEW_ENUMERATION_MUTATION foreignExists=\(FileManager.default.fileExists(atPath: destination.appendingPathComponent("foreign.txt").path))")
        #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: destination) }
    }


    @Test func committingRejectsFileAndDirectoryMutationsWithoutDeletingForeignEntries() throws {
        for mutation in 0..<6 {
            let f = try Fixture(); let source = try f.audio("source.caf")
            let project = try f.project(source); let hash = try f.hash(source)
            let inputEncoder = JSONEncoder(); inputEncoder.outputFormatting = .sortedKeys
            let inputBytes = try inputEncoder.encode(project)
            let destination = f.url("out.roughscorepkg")
            var reached = false; var foreign: URL?
            let bytes = Data("foreign replacement".utf8)
            let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
                guard phase == .committing else { return }
                reached = true
                let stage = try stage(f.root)
                let media = stage.appendingPathComponent("Media")
                let resource = media.appendingPathComponent(project.originalAsset!.id.uuidString + ".caf")
                switch mutation {
                case 0: // Same-length JSON mutation cannot escape a size-only check.
                    let json = stage.appendingPathComponent("project.json")
                    var data = try Data(contentsOf: json); data[0] = 33; try data.write(to: json)
                case 1:
                    let handle = try FileHandle(forWritingTo: resource); defer { try? handle.close() }
                    try handle.seek(toOffset: 100); try handle.write(contentsOf: Data([1, 2, 3, 4]))
                case 2, 3:
                    let entry = (mutation == 2 ? stage : media).appendingPathComponent("foreign.txt")
                    try bytes.write(to: entry); foreign = entry
                case 4:
                    let json = stage.appendingPathComponent("project.json")
                    // Atomic replacement preserves the previous inode until rename, defeating inode reuse.
                    try bytes.write(to: json, options: .atomic); foreign = json
                default:
                    try FileManager.default.moveItem(at: media, to: stage.appendingPathComponent("displaced-media"))
                    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
                    let entry = media.appendingPathComponent("foreign.txt")
                    try bytes.write(to: entry); foreign = entry
                }
            })
            #expect(throws: (any Error).self) {
                try PortableProjectPackage.collect(project, to: destination, hooks: hooks)
            }
            #expect(reached && !FileManager.default.fileExists(atPath: destination.path))
            #expect(try f.hash(source) == hash)
            #expect(try inputEncoder.encode(project) == inputBytes)
            if let foreign { #expect(try Data(contentsOf: foreign) == bytes) }
            else { #expect(try f.children() == ["source.caf"]) }
        }
    }

    @Test func enumerationEOFRejectsRootAndMediaInsertRemoveAndReplacement() throws {
        for mutation in 0..<4 {
            let f = try Fixture(); let source = try f.audio("source.caf")
            let project = try f.project(source)
            let snapshot = try PortableProjectPackage.collect(project, to: f.url("out.roughscorepkg"))
            let media = snapshot.root.appendingPathComponent("Media")
            let resource = try snapshot.resolve(assetID: project.originalAsset!.id)
            let target = mutation == 0 ? snapshot.root : media
            var targetInfo = stat(); #expect(lstat(target.path, &targetInfo) == 0)
            var reached = false
            let hooks = PortableProjectPackage.Hooks(readDirectory: { stream in
                let entry = readdir(stream)
                var current = stat()
                if entry == nil, !reached, fstat(dirfd(stream), &current) == 0,
                   current.st_dev == targetInfo.st_dev, current.st_ino == targetInfo.st_ino {
                    reached = true
                    switch mutation {
                    case 0, 1: try! Data("undeclared".utf8).write(to: target.appendingPathComponent("foreign.txt"))
                    case 2: try! FileManager.default.removeItem(at: resource)
                    default:
                        try! FileManager.default.moveItem(at: media, to: snapshot.root.appendingPathComponent("displaced-media"))
                        try! FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
                        try! Data("replacement".utf8).write(to: media.appendingPathComponent("foreign.txt"))
                    }
                    errno = 0
                }
                return entry
            })
            #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root, hooks: hooks) }
            #expect(reached)
            #expect(throws: (any Error).self) { try PortableProjectPackage.read(at: snapshot.root) }
        }
    }

    @Test func parentRelocationBeforeRenameRejectsCommitAndCleansPinnedStage() throws {
        let f = try Fixture(); let source = try f.audio("source.caf")
        let project = try f.project(source); let hash = try f.hash(source)
        let parent = f.url("parent"); let displaced = f.url("displaced")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        var reached = false
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            guard phase == .committing else { return }
            reached = true
            try FileManager.default.moveItem(at: parent, to: displaced)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data("existing destination".utf8).write(to: parent.appendingPathComponent("out.roughscorepkg"))
        })
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(project, to: parent.appendingPathComponent("out.roughscorepkg"), hooks: hooks)
        }
        #expect(reached)
        #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
        #expect(try Data(contentsOf: parent.appendingPathComponent("out.roughscorepkg")) == Data("existing destination".utf8))
        #expect(try f.hash(source) == hash)
    }

    @Test func replacedStageIsPreservedOnFailure() throws {
        let f = try Fixture(); var foreign: URL?; var reached = false
        let hooks = PortableProjectPackage.Hooks(checkpoint: { phase in
            guard phase == .committing else { return }
            reached = true
            let owned = try stage(f.root)
            try FileManager.default.moveItem(at: owned, to: f.url("displaced-stage"))
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
            let marker = owned.appendingPathComponent("foreign.txt")
            try Data("foreign stage".utf8).write(to: marker); foreign = marker
            throw Failure.injected
        })
        #expect(throws: Failure.injected) {
            try PortableProjectPackage.collect(ScoreProject(), to: f.url("out.roughscorepkg"), hooks: hooks)
        }
        #expect(reached)
        #expect(try Data(contentsOf: #require(foreign)) == Data("foreign stage".utf8))
        #expect(FileManager.default.fileExists(atPath: f.url("displaced-stage/project.json").path))
    }

    @Test func mutationInFinalCancellationCallbackIsFencedBeforeCommit() throws {
        let f = try Fixture(); var committing = false; var reached = false
        let hooks = PortableProjectPackage.Hooks(checkpoint: { if $0 == .committing { committing = true } })
        #expect(throws: (any Error).self) {
            try PortableProjectPackage.collect(ScoreProject(), to: f.url("out.roughscorepkg"), cancellation: {
                guard committing else { return }
                reached = true
                try Data("{broken".utf8).write(to: stage(f.root).appendingPathComponent("project.json"))
            }, hooks: hooks)
        }
        #expect(reached)
        #expect(try f.children().isEmpty)
    }
}
