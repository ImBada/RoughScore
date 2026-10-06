import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@MainActor @Suite(.serialized)
struct LateDocumentPublicationTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RoughScore-late-publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func linkedLateReplacementIsRestoredAndSaveFails() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("active.roughscore")
        let baseline = ScoreProject(title: "baseline", duration: 20)
        try JSONEncoder().encode(baseline).write(to: destination)
        var edited = baseline; edited.title = "our edit"
        var external = baseline; external.title = "external edit"
        let bytes = try JSONEncoder().encode(external)
        #expect(throws: (any Error).self) {
            try LinkedProjectWriter.replace(JSONEncoder().encode(edited), at: destination, expected: baseline,
                write: { try $0.write(to: $1) }, cancellation: {},
                beforePublication: { try bytes.write(to: destination, options: .atomic) })
        }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".roughscore-") })
    }

    @Test func metadataLateReplacementIsRestoredAndSaveFails() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try PortableProjectPackage.collect(ScoreProject(title: "baseline", duration: 20,
            events: [TabEvent(time: 1.123456789, lane: .right, string: 6)]), to: root.appendingPathComponent("active.roughscorepkg"))
        let destination = snapshot.root.appendingPathComponent("project.json")
        var external = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        var project = try #require(external["project"] as? [String: Any]); project["title"] = "external edit"
        external["project"] = project
        let bytes = try JSONSerialization.data(withJSONObject: external, options: [.sortedKeys])
        var edited = snapshot.project; edited.title = "our edit"
        #expect(throws: (any Error).self) {
            _ = try PortableProjectPackage.update(edited, replacing: snapshot, hooks: .init(checkpoint: {
                if $0 == .publishing { try bytes.write(to: destination, options: .atomic) }
            }))
        }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try PortableProjectPackage.read(at: snapshot.root).project.title == "external edit")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".roughscore-") })
    }

    @Test func mixedCasePackageOpensAndKeepsItsAutosaveFormat() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = ScoreProject(title: "case", duration: 120,
            events: [TabEvent(time: 100.123456789, lane: .right, string: 2, memo: "nil rhythm")])
        let lower = root.appendingPathComponent("initial.roughscorepkg")
        let upper = root.appendingPathComponent("moved.ROugHScOREpKG")
        _ = try PortableProjectPackage.collect(original, to: lower)
        try FileManager.default.moveItem(at: lower, to: upper)
        var services = WorkspaceServices.isolatedCache()
        services.initialProject = { nil }; services.lastProject = { nil }; services.rememberProject = { _ in }
        let w = Workspace(services: services); defer { w.shutdown() }
        #expect(await w.loadProject(at: upper)?.value == true)
        #expect(w.currentPackageURL == upper && w.project == original && !w.dirty)
        w.addEvent(time: 100.5, string: 3); let edited = w.project
        #expect(w.save(to: upper))
        #expect(try PortableProjectPackage.read(at: upper).project == edited)
        #expect(w.currentPackageURL == upper && !w.dirty)
    }

    @Test func mixedCaseCommandLineFormatsAreRecognized() {
        for ext in ["ROUGHSCOREPKG", "ROugHScOREpKG", "ROUGHSCORE", "RouGhScore"] {
            let path = "/generated/song." + ext
            #expect(WorkspaceServices.initialProjectURL(arguments: ["RoughScore", "--ignore", path]) == URL(fileURLWithPath: path))
        }
    }

    @Test func linkedSecondWriterIsRetainedDuringRollback() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("active.roughscore")
        let baseline = ScoreProject(title: "baseline", duration: 20)
        try JSONEncoder().encode(baseline).write(to: destination)
        var edited = baseline; edited.title = "our edit"
        var first = baseline; first.title = "external first"
        var second = baseline; second.title = "external second"
        let firstBytes = try JSONEncoder().encode(first), secondBytes = try JSONEncoder().encode(second)
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            try LinkedProjectWriter.replace(JSONEncoder().encode(edited), at: destination, expected: baseline,
                write: { try $0.write(to: $1) }, cancellation: {},
                beforePublication: { try firstBytes.write(to: destination, options: .atomic) },
                beforeRollback: { try secondBytes.write(to: destination, options: .atomic) })
            Issue.record("Late writers must reject publication")
        } catch let error as AtomicDocumentPublication.Conflict { conflict = error }
        let retained = try #require(conflict?.recoveryURL)
        #expect(conflict?.restored == true)
        #expect(try Data(contentsOf: destination) == firstBytes)
        #expect(try Data(contentsOf: retained) == secondBytes)
        #expect(conflict?.errorDescription?.contains(retained.path) == true)
    }

    @Test func metadataSecondWriterIsRetainedDuringRollback() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try PortableProjectPackage.collect(ScoreProject(title: "baseline", duration: 20),
            to: root.appendingPathComponent("active.roughscorepkg"))
        let destination = snapshot.root.appendingPathComponent("project.json")
        func bytes(title: String) throws -> Data {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
            var project = try #require(envelope["project"] as? [String: Any]); project["title"] = title
            envelope["project"] = project
            return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        }
        let first = try bytes(title: "external first"), second = try bytes(title: "external second")
        var edited = snapshot.project; edited.title = "our edit"
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            _ = try PortableProjectPackage.update(edited, replacing: snapshot, hooks: .init(checkpoint: {
                if $0 == .publishing { try first.write(to: destination, options: .atomic) }
                if $0 == .rollingBack { try second.write(to: destination, options: .atomic) }
            }))
            Issue.record("Late writers must reject publication")
        } catch let error as AtomicDocumentPublication.Conflict { conflict = error }
        let retained = try #require(conflict?.recoveryURL)
        #expect(conflict?.restored == true)
        #expect(try Data(contentsOf: destination) == first)
        #expect(try Data(contentsOf: retained) == second)
        #expect(try PortableProjectPackage.read(at: snapshot.root).project.title == "external first")
    }

    @Test func completePackageLateReplacementIsRestored() throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let original = try h.fixture("whole-package", duration: 3)
        let snapshot = try PortableProjectPackage.collect(ScoreProject(title: "baseline", audioPath: original.path, duration: 3),
            to: h.evidence.appendingPathComponent("active.roughscorepkg"))
        let incoming = h.evidence.appendingPathComponent("incoming.roughscorepkg")
        var other = snapshot.project; other.title = "external package"
        _ = try PortableProjectPackage.collect(other, to: incoming, sourceRoot: snapshot.root)
        let oldLocation = h.evidence.appendingPathComponent("old.roughscorepkg")
        let stem = AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: original.path), originalTimeOffset: -0.25)
        let edited = try snapshot.project.attachingStem(stem)
        #expect(throws: AtomicDocumentPublication.Conflict.self) {
            _ = try PortableProjectPackage.update(edited, replacing: snapshot, hooks: .init(checkpoint: {
                if $0 == .publishing {
                    try FileManager.default.moveItem(at: snapshot.root, to: oldLocation)
                    try FileManager.default.moveItem(at: incoming, to: snapshot.root)
                }
            }))
        }
        #expect(try PortableProjectPackage.read(at: snapshot.root).project.title == "external package")
        #expect(try PortableProjectPackage.read(at: oldLocation).project == snapshot.project)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: h.evidence.path).contains { $0.hasPrefix(".roughscore-") })
    }

    @Test func mixedCaseNewSaveFormatsAreAccepted() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var services = WorkspaceServices.isolatedCache()
        services.initialProject = { nil }; services.lastProject = { nil }; services.rememberProject = { _ in }
        let w = Workspace(services: services); defer { w.shutdown() }
        w.project = ScoreProject(title: "new case", duration: 20)
        let package = root.appendingPathComponent("new.ROUGHSCOREPKG"), linked = root.appendingPathComponent("new.RoughScore")
        #expect(w.saveAs(to: package, format: .collected))
        #expect(w.saveCopy(to: linked, format: .linked))
        #expect(try PortableProjectPackage.read(at: package).project == w.project)
        #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: linked)) == w.project)
        #expect(w.activeProjectURL == package && !w.dirty)
    }

    @Test(arguments: ["file", "directory", "symlink"])
    func metadataRejectsLateUndeclaredEntriesWithoutDeletingThem(kind: String) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try PortableProjectPackage.collect(ScoreProject(title: "baseline", duration: 20),
            to: root.appendingPathComponent("active.roughscorepkg"))
        let json = initial.root.appendingPathComponent("project.json"), old = try Data(contentsOf: json)
        let foreign = initial.root.appendingPathComponent("undeclared"), target = root.appendingPathComponent("target.txt")
        let bytes = Data("foreign data".utf8); try bytes.write(to: target)
        var candidate = initial.project; candidate.title = "our edit"
        #expect(throws: AtomicDocumentPublication.Conflict.self) {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .publishing {
                    if kind == "directory" { try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false) }
                    else if kind == "symlink" { try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: target) }
                    else { try bytes.write(to: foreign) }
                }
            }))
        }
        #expect(try Data(contentsOf: json) == old)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(try Data(contentsOf: target) == bytes)
        if kind == "file" { #expect(try Data(contentsOf: foreign) == bytes) }
    }

    @Test func rollbackReportsActualLocationsAfterParentMoves() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("active.roughscore")
        let baseline = ScoreProject(title: "baseline", duration: 20)
        try JSONEncoder().encode(baseline).write(to: destination)
        var candidate = baseline; candidate.title = "our edit"
        let first = Data("first external".utf8), second = Data("second external".utf8), unrelated = Data("unrelated new parent".utf8)
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            try LinkedProjectWriter.replace(JSONEncoder().encode(candidate), at: destination, expected: baseline,
                write: { try $0.write(to: $1) }, cancellation: {}, beforePublication: {
                    try first.write(to: destination, options: .atomic)
                }, beforeRollback: {
                    try second.write(to: destination, options: .atomic)
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    try unrelated.write(to: destination)
                })
            Issue.record("Expected a publication conflict")
        } catch let error as AtomicDocumentPublication.Conflict { conflict = error }
        let recovery = try #require(conflict?.recoveryURL), restored = try #require(conflict?.restoredAtURL)
        #expect(conflict?.restored == false && conflict?.retained == true)
        #expect(try Data(contentsOf: destination) == unrelated)
        #expect(try Data(contentsOf: restored) == first)
        #expect(try Data(contentsOf: recovery) == second)
        #expect(restored.deletingLastPathComponent().path == moved.path)
        #expect(conflict?.errorDescription?.contains(restored.path) == true)
    }
}
