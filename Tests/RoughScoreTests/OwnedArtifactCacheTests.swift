import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RoughScoreCore

@Suite struct OwnedArtifactCacheTests {
    private func root() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RoughScore-cache-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return parent.appendingPathComponent("cache")
    }
    private func key(_ content: String = "source", version: String = "v1", settings: [String: String] = [:]) -> OwnedArtifactCache.Key {
        .init(contentSHA256: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined(),
              kind: "prepared", algorithm: version, settings: settings)
    }
    private let build: @Sendable (OwnedArtifactCache.Stage) async throws -> Data = { stage in
        try stage.write("left.caf", data: Data(repeating: 19, count: 4096))
        return Data("verified output metadata".utf8)
    }
    @Test func persistedHitHasSameBytesAndVersionSettingsContentMiss() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        var cold: OwnedArtifactCache.Lease? = try await store.acquire(key(), build: build)
        #expect(cold?.cacheHit == false)
        let path = try #require(cold).url("left.caf"), payload = cold?.payload
        cold = nil
        let reopened = try OwnedArtifactCache(configuration: .init(root: root))
        let warm = try await reopened.acquire(key()) { _ in Issue.record("warm hit rebuilt"); throw ProbeError.failure }
        #expect(warm.cacheHit && warm.payload == payload)
        #expect(try warm.url("left.caf") == path)
        #expect(try warm.data("left.caf", maximum: 5000) == Data(repeating: 19, count: 4096))
        for changed in [key("replacement"), key(version: "v2"), key(settings: ["channel": "right"])] {
            #expect(try await reopened.acquire(changed, build: build).cacheHit == false)
        }
    }
    @Test func leasesAcrossStoresPinEvictionAndRebuildAfterRelease() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try OwnedArtifactCache(configuration: .init(root: root))
        let second = try OwnedArtifactCache(configuration: .init(root: root, quotaBytes: 0))
        var lease: OwnedArtifactCache.Lease? = try await first.acquire(key(), build: build)
        let directory = try #require(lease).directoryURL
        try await second.trim()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try #require(lease).data("left.caf", maximum: 5000).count == 4096)
        lease = nil
        try await second.trim()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await first.acquire(key(), build: build).cacheHit == false)
    }
    @Test func quotaUsesActualLeastRecentUnpinnedEntryAndLastReleaseRetries() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        var a: OwnedArtifactCache.Lease? = try await store.acquire(key("a"), build: build)
        let aPath = try #require(a).directoryURL; a = nil
        var b: OwnedArtifactCache.Lease? = try await store.acquire(key("b"), build: build)
        let bPath = try #require(b).directoryURL; b = nil
        let twoEntries = try await store.diskBytes()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: aPath.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: bPath.path)
        var hit: OwnedArtifactCache.Lease? = try await store.acquire(key("a"), build: build)
        #expect(hit?.cacheHit == true); hit = nil
        var c: OwnedArtifactCache.Lease? = try await store.acquire(key("c"), build: build)
        let cPath = try #require(c).directoryURL
        try await store.setQuota(twoEntries)
        #expect(FileManager.default.fileExists(atPath: aPath.path))
        #expect(!FileManager.default.fileExists(atPath: bPath.path))
        #expect(FileManager.default.fileExists(atPath: cPath.path))
        try await store.setQuota(0)
        #expect(FileManager.default.fileExists(atPath: cPath.path))
        c = nil
        #expect(!FileManager.default.fileExists(atPath: cPath.path))
        #expect(try await store.diskBytes() == 0)
    }
    @Test func corruptionCannotHitAndForeignSymlinkIsPreserved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        var lease: OwnedArtifactCache.Lease? = try await store.acquire(key(), build: build)
        let directory = try #require(lease).directoryURL
        let file = try #require(lease).url("left.caf")
        lease = nil
        _ = chmod(file.path, 0o600)
        try Data("corrupt".utf8).write(to: file)
        #expect(try await store.acquire(key(), build: build).cacheHit == false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let foreign = root.deletingLastPathComponent().appendingPathComponent("user-media")
        try Data("must survive".utf8).write(to: foreign)
        let linked = root.appendingPathComponent("stage_" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: foreign)
        try await store.setQuota(0); try await store.maintain()
        #expect(try Data(contentsOf: foreign) == Data("must survive".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == foreign.path)
    }
    @Test func corruptManifestAndIncompleteGenerationRefused() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        var lease: OwnedArtifactCache.Lease? = try await store.acquire(key(), build: build)
        let directory = try #require(lease).directoryURL
        lease = nil
        try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(try await store.acquire(key(), build: build).cacheHit == false)
        let incomplete = root.appendingPathComponent("entry_" + (try key("incomplete").digest) + "_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
        try Data((OwnedArtifactCache.format + "\n").utf8).write(to: incomplete.appendingPathComponent("owner"))
        try Data("partial".utf8).write(to: incomplete.appendingPathComponent("left.caf"))
        try journal(incomplete)
        #expect(try await store.acquire(key("incomplete"), build: build).cacheHit == false)
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    }
    @Test func failedBuildLeavesNoPartialAndCrashOrphanRecoveryIsBounded() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        await #expect(throws: ProbeError.self) {
            _ = try await store.acquire(key()) { stage in
                try stage.write("left.caf", data: Data("partial".utf8)); throw ProbeError.failure
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["root-version"])
        let crash = root.appendingPathComponent("stage_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: false)
        try Data((OwnedArtifactCache.format + "\n").utf8).write(to: crash.appendingPathComponent("owner"))
        try Data("partial".utf8).write(to: crash.appendingPathComponent("left.caf"))
        try journal(crash)
        let foreign = root.appendingPathComponent("stage_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: foreign.appendingPathComponent("keep"))
        let reopened = try OwnedArtifactCache(configuration: .init(root: root))
        try await reopened.maintain()
        #expect(!FileManager.default.fileExists(atPath: crash.path))
        #expect(try Data(contentsOf: foreign.appendingPathComponent("keep")) == Data("foreign".utf8))
    }
    @Test func oneConsumerCancelDoesNotCancelOtherAndBuildDeduplicates() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        let gate = BuildGate()
        let build: @Sendable (OwnedArtifactCache.Stage) async throws -> Data = { stage in
            await gate.enter(); await gate.wait(); try Task.checkCancellation()
            try stage.write("left.caf", data: Data("complete".utf8)); return Data()
        }
        let a = Task { try await store.acquire(key(), build: build) }
        await gate.started()
        let b = Task { try await store.acquire(key(), build: build) }
        // Actor barrier guarantees b has registered before a is cancelled.
        while await store.requestCountForTesting() != 2 { await Task.yield() }
        a.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        let value = try await b.value
        #expect(try value.data("left.caf", maximum: 100) == Data("complete".utf8))
        #expect(await gate.count == 1)
        #expect(try await store.acquire(key(), build: build).cacheHit)
    }
    @Test func lastCancelCleansStageAndRetryBuilds() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        let gate = BuildGate()
        let a = Task { try await store.acquire(key()) { stage in
            try stage.write("left.caf", data: Data("partial".utf8)); await gate.enter(); await gate.wait()
            try Task.checkCancellation(); return Data()
        } }
        await gate.started(); a.cancel()
        while await store.requestCountForTesting() != 0 { await Task.yield() }
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["root-version"])
        #expect(try await store.acquire(key(), build: build).cacheHit == false)
    }
    @Test func samePathReplacementCannotDeleteOrRetainReplacement() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try OwnedArtifactCache(configuration: .init(root: root))
        let lease = try await store.acquire(key(), build: build)
        let moved = root.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: lease.directoryURL, to: moved)
        try FileManager.default.createDirectory(at: lease.directoryURL, withIntermediateDirectories: false)
        let foreign = lease.directoryURL.appendingPathComponent("foreign")
        try Data("user bytes".utf8).write(to: foreign)
        #expect(throws: (any Error).self) { try lease.validate() }
        try await store.setQuota(0)
        #expect(try Data(contentsOf: foreign) == Data("user bytes".utf8))
    }
    @Test func unsafeAndOccupiedRootsFailBeforeOwnership() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let user = root.appendingPathComponent("user-file")
        try Data("untouched".utf8).write(to: user)
        #expect(throws: (any Error).self) { _ = try OwnedArtifactCache(configuration: .init(root: root)) }
        let link = root.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { _ = try OwnedArtifactCache(configuration: .init(root: link)) }
        #expect(try Data(contentsOf: user) == Data("untouched".utf8))
    }
    private func journal(_ directory: URL) throws {
        let url = directory.appendingPathComponent("ownership.json")
        try Data().write(to: url)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var records: [String: [String: Any]] = [:]
        for name in names {
            var info = stat(); #expect(lstat(directory.appendingPathComponent(name).path, &info) == 0)
            records[name] = ["device": info.st_dev, "inode": info.st_ino]
        }
        try JSONSerialization.data(withJSONObject: ["format": OwnedArtifactCache.format, "files": records]).write(to: url)
    }
    private enum ProbeError: Error { case failure }
}

private actor BuildGate {
    var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func enter() { count += 1; startWaiters.forEach { $0.resume() }; startWaiters.removeAll() }
    func started() async { if count == 0 { await withCheckedContinuation { startWaiters.append($0) } } }
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
