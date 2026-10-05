import Foundation
import Testing
@testable import RoughScore
@testable import RoughScoreCore

@MainActor private final class IndependentExportCapture {
    var owner: Workspace?
    var writes = 0
    var savedDuringModal = false
    var destination: URL?
    var outputTaskWasCancelled = false
}

@MainActor @Suite(.serialized)
struct IndependentIssue15R1Probes {
    private func ownRoot(_ name: String) throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ROUGH_SCORE_INDEPENDENT_PROBE_ROOT"]!)
        let root = base.appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func services(_ root: URL) throws -> WorkspaceServices {
        let environment = try AudioCacheEnvironment(configuration: .init(root: root.appendingPathComponent("cache")))
        var s = WorkspaceServices.cachedLive(environment: environment)
        s.initialProject = { nil }; s.lastProject = { nil }; s.rememberProject = { _ in }
        s.sessionStore = .disabled
        return s
    }
    private func record(_ root: URL, _ result: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("result.json"))
    }

    @Test(arguments: [false, true])
    func collectedSaveDuringExportModalMustProtectTheNewActiveMedia(overwriteMedia: Bool) async throws {
        let root = try ownRoot("new-package-boundary")
        let harness = StemReviewHarness()
        let generated = try harness.fixture("generated-only", duration: 3)
        // File decoding and collection are content-based; an existing project may
        // legitimately refer to a CAF stream whose filename uses .txt.
        let source = root.appendingPathComponent(overwriteMedia ? "source.txt" : "source.caf")
        try FileManager.default.copyItem(at: generated, to: source)
        let original = try Data(contentsOf: source)
        let asset = AudioAsset(reference: .init(path: source.path))
        let package = root.appendingPathComponent("new-active.roughscorepkg")
        let media = package.appendingPathComponent("Media/" + asset.id.uuidString + (overwriteMedia ? ".txt" : ".caf"))
        let target = overwriteMedia ? media : package.appendingPathComponent("shared-tab.txt")
        let c = IndependentExportCapture()
        var s = try services(root)
        s.exportServices.chooseDestination = { _, _ in
            c.savedDuringModal = c.owner!.saveAs(to: package, format: .collected)
            return target
        }
        s.exportServices.write = { data, url in c.writes += 1; try data.write(to: url, options: .atomic) }
        let w = Workspace(services: s); c.owner = w
        defer { c.owner = nil; w.shutdown() }
        w.project = ScoreProject(audioPath: source.path, duration: 3)
        w.project.assets = [asset]
        w.beginExport(.tab)
        let snapshot = try #require(w.exportSnapshot)
        #expect(snapshot.packageRoot == nil)
        #expect(w.canSave)
        let completed = await w.completeExport(snapshot, options: .init())
        let after = try Data(contentsOf: media)
        let packageReadable = (try? PortableProjectPackage.read(at: package)) != nil
        try record(root, ["savedDuringModal": c.savedDuringModal, "completed": completed,
            "writes": c.writes, "activeProject": w.activeProjectURL!.path,
            "protectedMedia": media.path, "exportDestination": target.path, "overwriteMedia": overwriteMedia,
            "beforeBytes": original.count, "afterBytes": after.count,
            "mediaUnchanged": after == original, "packageReadableAfterExport": packageReadable,
            "externalSourceUnchanged": try Data(contentsOf: source) == original])
        #expect(c.savedDuringModal)
        #expect(!completed && c.writes == 0, "Export must refresh destination protection after a reentrant Save As")
        #expect(after == original, "Export must preserve the newly active package's collected audio")
        #expect(packageReadable, "The active package must still pass its media identity check")
    }

    @Test func taskCancellationDuringDestinationCallbackMustNotWrite() async throws {
        let root = try ownRoot("modal-task-cancellation"), c = IndependentExportCapture()
        let output = root.appendingPathComponent("cancelled.txt")
        var s = try services(root)
        s.exportServices.chooseDestination = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return output
        }
        s.exportServices.write = { data, url in
            c.outputTaskWasCancelled = Task.isCancelled
            c.writes += 1
            try data.write(to: url, options: .atomic)
        }
        let w = Workspace(services: s); defer { w.shutdown() }
        w.beginExport(.tab); let snapshot = try #require(w.exportSnapshot)
        let operation = Task { await w.completeExport(snapshot, options: .init()) }
        let completed = await operation.value
        try record(root, ["completed": completed, "writes": c.writes,
            "outputTaskWasCancelled": c.outputTaskWasCancelled,
            "outputExists": FileManager.default.fileExists(atPath: output.path)])
        #expect(!completed && c.writes == 0, "Cancelled export task must not publish after the destination modal")
    }

    @Test func rangeLaneRhythmAndAllControlBytesStayExact() throws {
        var project = ExportCoreTests.sample()
        project.events[1].memo = "한글 e\u{301} 😀 \"quote\" \\" + String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! } + [UnicodeScalar(127)!]))
        let original = project
        let snapshot = ScoreExportSnapshot(projectID: UUID(), initialFormat: .table, project: project,
            selectedRange: .init(start: 3.125, end: 9.999999999999998),
            analysis: .init(project: project), waveform: nil, protectedFiles: [], packageRoot: nil)
        for lane in ScoreExportOptions.Lanes.allCases {
            var options = ScoreExportOptions(); options.format = .table; options.rangeChoice = .selected; options.lanes = lane
            let decoded = try SparseTabExporter.parseEventTable(snapshot.bytes(options))
            let expected = project.events.filter { $0.time >= 3.125 && $0.time < 9.999999999999998 && lane.values.contains($0.lane) }
            #expect(decoded.events == expected)
            for (actual, source) in zip(decoded.events, expected) {
                #expect(actual.time.bitPattern == source.time.bitPattern)
                #expect(Array(actual.memo.utf8) == Array(source.memo.utf8))
            }
            options.format = .tab; options.showRhythm = false
            let text = String(decoding: try snapshot.bytes(options), as: UTF8.self)
            #expect(!text.contains(" length="))
            for e in expected { #expect(text.components(separatedBy: e.id.uuidString).count - 1 == 1) }
        }
        #expect(project == original)
    }
}
