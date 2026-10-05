import Darwin
import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@MainActor @Suite(.serialized)
struct IndependentIssue14R3Probes {
    func root() throws -> URL {
        let r = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RoughScore-independent-r3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: false)
        return r
    }
    func bytes(_ title: String) throws -> Data { try JSONEncoder().encode(ScoreProject(title: title, duration: 20)) }
    func tree(_ root: URL) throws -> [String: Data] {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let e = try #require(FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let u as URL in e {
            if try u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[u.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(canonical.pathComponents.count).joined(separator: "/")] = try Data(contentsOf: u)
            }
        }
        return result
    }
    func foreign(_ type: String, at url: URL, bytes: Data, target: URL) throws {
        if type == "directory" {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try bytes.write(to: url.appendingPathComponent("foreign.bin"))
        } else if type == "symlink" {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else if type == "inPlace" { try bytes.write(to: url) }
        else { try bytes.write(to: url, options: .atomic) }
    }

    @Test(arguments: ["atomic", "inPlace", "identicalABA", "symlink", "directory"])
    func linkedDisplacedEntriesArePreserved(type: String) throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let d = r.appendingPathComponent("active.RoUgHsCoRe"), target = r.appendingPathComponent("external.bin")
        let baseline = ScoreProject(title: "base", duration: 20)
        let old = try JSONEncoder().encode(baseline), other = try bytes("late foreign"), new = try bytes("our edit")
        try old.write(to: d); try other.write(to: target)
        let expected = type == "identicalABA" ? old : other
        var failed = false
        do {
            try LinkedProjectWriter.replace(new, at: d, expected: baseline, write: { try $0.write(to: $1) }, cancellation: {},
                beforePublication: { try foreign(type, at: d, bytes: expected, target: target) })
        } catch is AtomicDocumentPublication.Conflict { failed = true }
        #expect(failed)
        if type == "directory" { #expect(try Data(contentsOf: d.appendingPathComponent("foreign.bin")) == expected) }
        else { #expect(try Data(contentsOf: d) == expected) }
        if type == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: d.path) == target.path) }
        #expect(try Data(contentsOf: target) == other)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: r.path).contains { $0.hasPrefix(".roughscore-") })
    }

    @Test(arguments: ["atomic", "inPlace", "identicalABA", "symlink", "directory"])
    func metadataDisplacedEntriesArePreserved(type: String) throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let initial = try PortableProjectPackage.collect(ScoreProject(title: "base", duration: 20), to: r.appendingPathComponent("active.roughscorepkg"))
        let d = initial.root.appendingPathComponent("project.json"), target = r.appendingPathComponent("external.bin")
        let old = try Data(contentsOf: d), other = Data("late foreign document".utf8)
        try other.write(to: target)
        var new = initial.project; new.title = "our edit"
        let expected = type == "identicalABA" ? old : other
        var failed = false
        do {
            _ = try PortableProjectPackage.update(new, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .publishing { try foreign(type, at: d, bytes: expected, target: target) }
            }))
        } catch is AtomicDocumentPublication.Conflict { failed = true }
        #expect(failed)
        if type == "directory" { #expect(try Data(contentsOf: d.appendingPathComponent("foreign.bin")) == expected) }
        else { #expect(try Data(contentsOf: d) == expected) }
        if type == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: d.path) == target.path) }
        #expect(try Data(contentsOf: target) == other)
    }

    @Test(arguments: ["missing", "symlink", "directory", "inPlace"])
    func rollbackPreservesSecondWriterAndReportsUsableRecovery(type: String) throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let d = r.appendingPathComponent("active.roughscore"), target = r.appendingPathComponent("foreign-target")
        let baseline = ScoreProject(title: "base", duration: 20)
        let first = try bytes("first foreign"), second = try bytes("second foreign")
        try JSONEncoder().encode(baseline).write(to: d); try second.write(to: target)
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            try LinkedProjectWriter.replace(bytes("our edit"), at: d, expected: baseline, write: { try $0.write(to: $1) }, cancellation: {},
                beforePublication: { try first.write(to: d, options: .atomic) }, beforeRollback: {
                    if type == "missing" { try FileManager.default.removeItem(at: d) }
                    else { try foreign(type, at: d, bytes: second, target: target) }
                })
            Issue.record("Expected conflict")
        } catch let e as AtomicDocumentPublication.Conflict { conflict = e }
        #expect(try conflict?.restored == true && Data(contentsOf: d) == first)
        if type == "missing" { #expect(conflict?.recoveryURL == nil) }
        else {
            let recovery = try #require(conflict?.recoveryURL)
            if type == "directory" { #expect(try Data(contentsOf: recovery.appendingPathComponent("foreign.bin")) == second) }
            else { #expect(try Data(contentsOf: recovery) == second) }
            #expect(conflict?.errorDescription?.contains(recovery.path) == true)
        }
        #expect(try Data(contentsOf: target) == second)
    }

    @Test func completePackageRollbackRetainsBothForeignPackagesAndAllMedia() throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let audio = try h.fixture("original", duration: 3)
        let initial = try PortableProjectPackage.collect(ScoreProject(title: "base", audioPath: audio.path, duration: 3), to: h.evidence.appendingPathComponent("active.roughscorepkg"))
        var one = initial.project; one.title = "first foreign"
        var two = initial.project; two.title = "second foreign"
        let first = try PortableProjectPackage.collect(one, to: h.evidence.appendingPathComponent("first.roughscorepkg"), sourceRoot: initial.root)
        let second = try PortableProjectPackage.collect(two, to: h.evidence.appendingPathComponent("second.roughscorepkg"), sourceRoot: initial.root)
        let oldTree = try tree(initial.root), firstTree = try tree(first.root), secondTree = try tree(second.root)
        let savedOld = h.evidence.appendingPathComponent("saved-old.roughscorepkg"), movedOurs = h.evidence.appendingPathComponent("moved-ours.roughscorepkg")
        let candidate = try initial.project.attachingStem(AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: audio.path)))
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .publishing {
                    try FileManager.default.moveItem(at: initial.root, to: savedOld)
                    try FileManager.default.moveItem(at: first.root, to: initial.root)
                }
                if $0 == .rollingBack {
                    try FileManager.default.moveItem(at: initial.root, to: movedOurs)
                    try FileManager.default.moveItem(at: second.root, to: initial.root)
                }
            }))
            Issue.record("Expected conflict")
        } catch let e as AtomicDocumentPublication.Conflict { conflict = e }
        let recovery = try #require(conflict?.recoveryURL)
        #expect(conflict?.restored == true)
        print("R3_FULL_PACKAGE_TREE firstKeys=\(firstTree.keys.sorted()) destinationKeys=\(try tree(initial.root).keys.sorted()) secondKeys=\(secondTree.keys.sorted()) recoveryKeys=\(try tree(recovery).keys.sorted())")
        #expect(try tree(initial.root) == firstTree)
        #expect(try tree(recovery) == secondTree)
        #expect(try tree(savedOld) == oldTree)
        #expect(try PortableProjectPackage.read(at: initial.root).project.title == "first foreign")
        #expect(try PortableProjectPackage.read(at: recovery).project.title == "second foreign")
        #expect(try PortableProjectPackage.read(at: savedOld).project == initial.project)
        #expect(try PortableProjectPackage.read(at: movedOurs).project.assets?.count == 2)
    }

    @Test func cancellationAtPublicationPreservesBothDocumentRoutes() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let d = r.appendingPathComponent("active.roughscore"), baseline = ScoreProject(title: "base", duration: 20)
        let old = try JSONEncoder().encode(baseline); try old.write(to: d)
        #expect(throws: CancellationError.self) {
            try LinkedProjectWriter.replace(bytes("new"), at: d, expected: baseline, write: { try $0.write(to: $1) }, cancellation: {}, beforePublication: { throw CancellationError() })
        }
        #expect(try Data(contentsOf: d) == old)
        let initial = try PortableProjectPackage.collect(baseline, to: r.appendingPathComponent("active.roughscorepkg"))
        let oldTree = try tree(initial.root)
        var candidate = baseline; candidate.title = "new"
        #expect(throws: CancellationError.self) {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: { if $0 == .publishing { throw CancellationError() } }))
        }
        #expect(try tree(initial.root) == oldTree)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: r.path).contains { $0.hasPrefix(".roughscore-") })
    }

    @Test(arguments: ["linked", "collected"])
    func mixedCaseActiveRoutesActuallyAutosave(format: String) async throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        var s = WorkspaceServices.isolatedCache(); s.initialProject = { nil }; s.lastProject = { nil }; s.rememberProject = { _ in }
        let w = Workspace(services: s); defer { w.shutdown() }
        let d = r.appendingPathComponent(format == "linked" ? "active.RoUgHsCoRe" : "active.RoUgHsCoRePkG")
        w.project = ScoreProject(title: "base", duration: 20)
        #expect(w.saveAs(to: d, format: format == "linked" ? .linked : .collected))
        #expect(WorkspaceServices.initialProjectURL(arguments: ["app", d.path])?.path == d.path)
        w.addEvent(time: 1.23456789, string: 6); let edited = w.project
        await w.awaitAutosave(); #expect(!w.dirty && w.activeProjectURL == d)
        w.shutdown()
        let reopened = Workspace(services: s); defer { reopened.shutdown() }
        #expect(await reopened.loadProject(at: d)?.value == true)
        #expect(reopened.project == edited && !reopened.dirty)
    }

    @Test func lateMetadataRootRebindingMustNotOverwriteMovedOriginalOrReturnSuccess() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let initial = try PortableProjectPackage.collect(ScoreProject(title: "base", duration: 20), to: r.appendingPathComponent("active.roughscorepkg"))
        let incoming = try PortableProjectPackage.collect(ScoreProject(title: "foreign", duration: 20), to: r.appendingPathComponent("incoming.roughscorepkg"))
        let moved = r.appendingPathComponent("moved-original.roughscorepkg"), originalTree = try tree(initial.root), incomingTree = try tree(incoming.root)
        var candidate = initial.project; candidate.title = "our edit"
        var succeeded = false
        do {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .publishing {
                    try FileManager.default.moveItem(at: initial.root, to: moved)
                    try FileManager.default.moveItem(at: incoming.root, to: initial.root)
                }
            }))
            succeeded = true
        } catch {}
        print("R3_METADATA_ROOT_REBIND succeeded=\(succeeded) movedTitle=\(try PortableProjectPackage.read(at: moved).project.title) activeTitle=\(try PortableProjectPackage.read(at: initial.root).project.title)")
        #expect(!succeeded)
        #expect(try tree(moved) == originalTree)
        #expect(try tree(initial.root) == incomingTree)
    }

    @Test(arguments: ["linked", "completePackage"])
    func lateParentRebindingMustNotClaimTheForeignDestination(format: String) throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        try FileManager.default.createDirectory(at: h.evidence, withIntermediateDirectories: true)
        let parent = h.evidence.appendingPathComponent("parent"), moved = h.evidence.appendingPathComponent("moved-parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let d = parent.appendingPathComponent(format == "linked" ? "active.roughscore" : "active.roughscorepkg")
        let baseline = ScoreProject(title: "base", duration: 3)
        var candidate = baseline; candidate.title = "our edit"
        var succeeded = false
        if format == "linked" {
            try JSONEncoder().encode(baseline).write(to: d)
            do {
                try LinkedProjectWriter.replace(JSONEncoder().encode(candidate), at: d, expected: baseline, write: { try $0.write(to: $1) }, cancellation: {}, beforePublication: {
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    try self.bytes("foreign").write(to: d)
                }); succeeded = true
            } catch {}
            #expect(try JSONDecoder().decode(ScoreProject.self, from: Data(contentsOf: d)).title == "foreign")
        } else {
            let audio = try h.fixture("original", duration: 3)
            let initial = try PortableProjectPackage.collect(ScoreProject(title: "base", audioPath: audio.path, duration: 3), to: d)
            let new = try initial.project.attachingStem(AudioAsset(role: .importedGuitarStem, reference: AudioReference(path: audio.path)))
            do {
                _ = try PortableProjectPackage.update(new, replacing: initial, hooks: .init(checkpoint: {
                    if $0 == .publishing {
                        try FileManager.default.moveItem(at: parent, to: moved)
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                        _ = try PortableProjectPackage.collect(ScoreProject(title: "foreign", duration: 3), to: d)
                    }
                })); succeeded = true
            } catch {}
            #expect(try PortableProjectPackage.read(at: d).project.title == "foreign")
        }
        print("R3_PARENT_REBIND format=\(format) succeeded=\(succeeded)")
        #expect(!succeeded)
    }

    @Test func lateMediaReplacementMustBeIncludedInMetadataPublicationFence() throws {
        let h = StemReviewHarness(); defer { h.cleanEvidence() }
        let audio = try h.fixture("original", duration: 3), replacement = try h.fixture("replacement", duration: 3, rate: 44100)
        let initial = try PortableProjectPackage.collect(ScoreProject(title: "base", audioPath: audio.path, duration: 3), to: h.evidence.appendingPathComponent("active.roughscorepkg"))
        let media = try initial.resolve(assetID: initial.project.originalAsset!.id)
        let oldJSON = try Data(contentsOf: initial.root.appendingPathComponent("project.json")), replacementBytes = try Data(contentsOf: replacement)
        var candidate = initial.project; candidate.title = "our edit"
        var succeeded = false
        do {
            _ = try PortableProjectPackage.update(candidate, replacing: initial, hooks: .init(checkpoint: {
                if $0 == .publishing { try replacementBytes.write(to: media, options: .atomic) }
            })); succeeded = true
        } catch {}
        let readable = (try? PortableProjectPackage.read(at: initial.root)) != nil
        print("R3_METADATA_MEDIA_REPLACEMENT succeeded=\(succeeded) readable=\(readable)")
        #expect(!succeeded)
        #expect(try Data(contentsOf: initial.root.appendingPathComponent("project.json")) == oldJSON)
        #expect(try Data(contentsOf: media) == replacementBytes)
    }

    @Test func rollbackParentRebindingMustExposeAReachableRecoveryURL() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at: r) }
        let parent = r.appendingPathComponent("parent"), moved = r.appendingPathComponent("moved-parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let d = parent.appendingPathComponent("active.roughscore"), baseline = ScoreProject(title: "base", duration: 20)
        let first = try bytes("first foreign"), second = try bytes("second foreign")
        try JSONEncoder().encode(baseline).write(to: d)
        var conflict: AtomicDocumentPublication.Conflict?
        do {
            try LinkedProjectWriter.replace(bytes("our edit"), at: d, expected: baseline, write: { try $0.write(to: $1) }, cancellation: {},
                beforePublication: { try first.write(to: d, options: .atomic) }, beforeRollback: {
                    try second.write(to: d, options: .atomic)
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    try self.bytes("unrelated new parent").write(to: d)
                })
            Issue.record("Expected conflict")
        } catch let e as AtomicDocumentPublication.Conflict { conflict = e }
        let advertised = try #require(conflict?.recoveryURL)
        let actual = moved.appendingPathComponent(advertised.deletingLastPathComponent().lastPathComponent).appendingPathComponent(advertised.lastPathComponent)
        print("R3_RECOVERY_REBIND restored=\(conflict?.restored == true) advertisedExists=\(FileManager.default.fileExists(atPath: advertised.path)) actualExists=\(FileManager.default.fileExists(atPath: actual.path))")
        #expect(try Data(contentsOf: actual) == second)
        #expect(try Data(contentsOf: moved.appendingPathComponent("active.roughscore")) == first)
        #expect(FileManager.default.fileExists(atPath: advertised.path))
    }
}
