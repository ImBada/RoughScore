import CryptoKit
import Darwin
import Foundation

/// A dedicated, version-marked directory. No source, project or media URL is accepted by cleanup.
public actor OwnedArtifactCache {
    public static let format = "org.roughscore.owned-artifacts.v1"
    public enum CacheError: Error { case unsafePath, invalidArtifact, occupiedRoot, io(Int32) }
    public struct Configuration: Sendable {
        public var root: URL
        public var quotaBytes: Int64
        public init(root: URL, quotaBytes: Int64 = 4 * 1_024 * 1_024 * 1_024) {
            self.root = root; self.quotaBytes = max(0, quotaBytes)
        }
    }
    public struct Key: Codable, Equatable, Sendable {
        public var contentSHA256: String
        public var kind: String
        public var algorithm: String
        public var settings: [String: String]
        public init(contentSHA256: String, kind: String, algorithm: String, settings: [String: String] = [:]) {
            self.contentSHA256 = contentSHA256; self.kind = kind; self.algorithm = algorithm; self.settings = settings
        }
        public var digest: String {
            get throws {
                guard contentSHA256.count == 64, contentSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                      !kind.isEmpty, !algorithm.isEmpty else { throw CacheError.invalidArtifact }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return CacheFile.digest(try encoder.encode(self))
            }
        }
    }
    private struct Manifest: Codable {
        var format: String = OwnedArtifactCache.format
        var generation: String
        var key: Key
        var payload: Data
        var files: [String: FileRecord]
    }
    private struct FileRecord: Codable { var bytes: Int64; var sha256: String }
    private struct Flight {
        let task: Task<Lease, Error>
        var consumers: Set<UUID>
    }
    private let root: CacheDirectory
    private let policy: QuotaPolicy
    private var flights: [String: Flight] = [:]

    public init(configuration: Configuration) throws {
        root = try CacheDirectory.ownedRoot(configuration.root)
        policy = QuotaPolicy(configuration.quotaBytes)
        try Self.removeOrphans(root)
        try Self.evict(root, quota: configuration.quotaBytes)
    }

    /// Each requester owns an independent interest in a shared build. Cancelling the last interest
    /// cancels its stage; cancelling one requester cannot invalidate another requester's result.
    public func acquire(_ key: Key, build: @escaping @Sendable (Stage) async throws -> Data) async throws -> Lease {
        try Task.checkCancellation()
        let digest = try key.digest, consumer = UUID()
        let task: Task<Lease, Error>
        if var flight = flights[digest] {
            flight.consumers.insert(consumer); flights[digest] = flight; task = flight.task
        } else {
            let root = root, policy = policy
            task = Task.detached(priority: .userInitiated) {
                if let hit = try Self.find(key, root: root, policy: policy) { return hit }
                try Task.checkCancellation()
                let stage = try Stage(root: root, key: key, policy: policy)
                let payload = try await build(stage)
                try Task.checkCancellation()
                return try stage.commit(payload: payload)
            }
            flights[digest] = Flight(task: task, consumers: [consumer])
        }
        defer { finish(digest, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let lease = try await task.value
            try Task.checkCancellation()
            try lease.validate()
            try trim()
            return lease
        } onCancel: { Task { await self.cancel(digest, consumer: consumer) } }
    }
    private func finish(_ digest: String, consumer: UUID) {
        guard var flight = flights[digest] else { return }
        flight.consumers.remove(consumer)
        flights[digest] = flight.consumers.isEmpty ? nil : flight
    }
    private func cancel(_ digest: String, consumer: UUID) {
        guard var flight = flights[digest], flight.consumers.remove(consumer) != nil else { return }
        if flight.consumers.isEmpty { flight.task.cancel(); flights[digest] = nil }
        else { flights[digest] = flight }
    }
    func requestCountForTesting() -> Int { flights.values.reduce(0) { $0 + $1.consumers.count } }
    public func setQuota(_ bytes: Int64) throws { policy.bytes = max(0, bytes); try trim() }
    public func maintain() throws { try Self.removeOrphans(root); try trim() }

    /// Pinned entries may exceed quota. Last lease release retries eviction without retaining an actor or graph.
    public func trim() throws { try Self.evict(root, quota: policy.bytes) }
    private static func evict(_ root: CacheDirectory, quota: Int64) throws {
        let entries = try root.names().filter { Self.entryName($0) }.compactMap { name -> (String, CacheDirectory, Int64, timespec)? in
            guard let directory = try? root.child(name), let files = try? directory.safeOwnedFiles(),
                  files["manifest.json"] != nil else { return nil }
            return (name, directory, files.values.reduce(0) { $0 + $1.info.st_size }, directory.info.st_mtimespec)
        }
        var size = entries.reduce(Int64(0)) { $0 + $1.2 }
        for (name, directory, bytes, _) in entries.sorted(by: {
            $0.3.tv_sec == $1.3.tv_sec ? $0.3.tv_nsec < $1.3.tv_nsec : $0.3.tv_sec < $1.3.tv_sec
        }) where size > quota {
            guard flock(directory.fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(directory.fd, LOCK_UN) }
            if try root.removeOwned(name, directory: directory) { size -= bytes }
        }
    }
    public func diskBytes() throws -> Int64 {
        try root.names().filter { Self.entryName($0) || Self.stageName($0) }.reduce(0) { total, name in
            guard let directory = try? root.child(name), let files = try? directory.safeOwnedFiles() else { return total }
            return total + files.values.reduce(0) { $0 + $1.info.st_size }
        }
    }
    private static func entryName(_ name: String) -> Bool {
        let parts = name.split(separator: "_")
        return parts.count == 3 && parts[0] == "entry" && parts[1].count == 64 &&
            parts[1].allSatisfy({ "0123456789abcdef".contains($0) }) && UUID(uuidString: String(parts[2])) != nil
    }
    private static func stageName(_ name: String) -> Bool {
        name.hasPrefix("stage_") && UUID(uuidString: String(name.dropFirst(6))) != nil
    }
    private static func removeOrphans(_ root: CacheDirectory) throws {
        for name in try root.names() where stageName(name) {
            guard let directory = try? root.child(name), flock(directory.fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(directory.fd, LOCK_UN) }
            _ = try? root.recoverStage(name, directory: directory)
        }
    }
    private static func find(_ key: Key, root: CacheDirectory, policy: QuotaPolicy) throws -> Lease? {
        let prefix = "entry_" + (try key.digest) + "_"
        for name in try root.names().sorted() where entryName(name) && name.hasPrefix(prefix) {
            try Task.checkCancellation()
            guard let directory = try? root.child(name) else { continue }
            // Lock before validating; a different cache instance cannot evict a candidate being read.
            guard flock(directory.fd, LOCK_SH | LOCK_NB) == 0 else { continue }
            do {
                let files = try directory.safeOwnedFiles()
                guard let manifestFile = files["manifest.json"], manifestFile.info.st_size <= 32 * 1_048_576 else { throw CacheError.invalidArtifact }
                let manifest = try JSONDecoder().decode(Manifest.self, from: manifestFile.data(maximum: 32 * 1_048_576))
                guard manifest.format == format, manifest.key == key,
                      name == "entry_" + (try key.digest) + "_" + manifest.generation,
                      Set(files.keys) == Set(manifest.files.keys).union(["owner", "manifest.json", "ownership.json"]) else { throw CacheError.invalidArtifact }
                for (name, record) in manifest.files {
                    guard let file = files[name], file.info.st_size == record.bytes,
                          try file.fingerprint() == record.sha256 else { throw CacheError.invalidArtifact }
                }
                let lease = Lease(root: root, directory: directory, name: name, key: manifest.key, payload: manifest.payload,
                                  files: files, cacheHit: true, onRelease: { try? Self.evict(root, quota: policy.bytes) })
                try lease.validate(); try directory.touch()
                return lease
            } catch {
                flock(directory.fd, LOCK_UN)
                if error is CancellationError { throw error }
                // Never overwrite a corrupt entry or follow its contents. A fresh generation may be built.
                if flock(directory.fd, LOCK_EX | LOCK_NB) == 0 {
                    _ = try? root.removeOwned(name, directory: directory)
                    flock(directory.fd, LOCK_UN)
                }
            }
        }
        return nil
    }

    public final class Lease: @unchecked Sendable {
        public let generation: UUID = UUID()
        public let directoryURL: URL
        public let payload: Data
        public let key: Key
        public let cacheHit: Bool
        private let root: CacheDirectory
        private let directory: CacheDirectory
        private let name: String
        private let files: [String: CacheFile]
        private let onRelease: @Sendable () -> Void
        fileprivate init(root: CacheDirectory, directory: CacheDirectory, name: String, key: Key, payload: Data,
                         files: [String: CacheFile], cacheHit: Bool, onRelease: @escaping @Sendable () -> Void) {
            self.root = root; self.directory = directory; self.name = name; self.key = key; self.payload = payload
            self.files = files; self.cacheHit = cacheHit; self.onRelease = onRelease; directoryURL = root.url.appendingPathComponent(name)
        }
        deinit { flock(directory.fd, LOCK_UN); onRelease() }
        public func validate() throws {
            guard root.isBound, root.matches(name, directory.info) else { throw CacheError.unsafePath }
            for (name, file) in files {
                guard file.unchanged, directory.matches(name, file.info) else { throw CacheError.invalidArtifact }
            }
        }
        public func url(_ name: String) throws -> URL {
            try validate()
            guard files[name] != nil else { throw CacheError.invalidArtifact }
            return directoryURL.appendingPathComponent(name)
        }
        public final class Reader: @unchecked Sendable {
            public let url: URL
            private let file: CacheFile
            private let lease: Lease
            private let name: String
            fileprivate init(file: CacheFile, lease: Lease, name: String) {
                self.file = file; self.lease = lease; self.name = name
                url = URL(fileURLWithPath: "/dev/fd/\(file.fd)")
            }
            /// URL-only backends may reopen this app-owned canonical file. The reader still pins
            /// its generation and independent descriptor; callers must validate after awaited work.
            public func canonicalURL() throws -> URL {
                try validate()
                return try lease.url(name)
            }
            public func validate() throws {
                guard file.unchanged else { throw CacheError.invalidArtifact }
                try lease.validate()
            }
        }
        /// Each native reader gets an independent descriptor under the retained directory. Reopened
        /// inode/state checks prevent path ABA; independent offsets prevent /dev/fd reader interference.
        public func reader(_ name: String) throws -> Reader {
            try validate()
            guard let expected = files[name] else { throw CacheError.invalidArtifact }
            let independent = try directory.file(name)
            guard CacheFile.sameState(independent.info, expected.info) else { throw CacheError.invalidArtifact }
            return Reader(file: independent, lease: self, name: name)
        }
        public func withPinnedFile<T>(_ name: String, _ read: (URL) throws -> T) throws -> T {
            let reader = try reader(name)
            let result = try read(reader.url)
            try reader.validate()
            return result
        }
        public func data(_ name: String, maximum: Int) throws -> Data {
            try validate()
            guard let file = files[name] else { throw CacheError.invalidArtifact }
            return try file.data(maximum: maximum)
        }
    }

    public final class Stage: @unchecked Sendable {
        public let directoryURL: URL
        private let root: CacheDirectory
        private let directory: CacheDirectory
        private let key: Key
        private var name: String
        private let generation: String
        private let policy: QuotaPolicy
        private var committed = false
        fileprivate init(root: CacheDirectory, key: Key, policy: QuotaPolicy) throws {
            self.root = root; self.key = key; self.policy = policy; generation = UUID().uuidString
            name = "stage_" + generation
            directory = try root.createDirectory(name)
            directoryURL = root.url.appendingPathComponent(name)
            guard flock(directory.fd, LOCK_SH | LOCK_NB) == 0 else { throw CacheError.io(errno) }
            do {
                try directory.write("owner", data: Data((OwnedArtifactCache.format + "\n").utf8))
                try directory.recordOwnership()
            } catch {
                root.removeCreated(name, directory: directory)
                flock(directory.fd, LOCK_UN)
                throw error
            }
        }
        deinit {
            if !committed { root.removeCreated(name, directory: directory) }
            if !committed { flock(directory.fd, LOCK_UN) }
        }
        /// Only these app-defined payload names are permitted. Callers cannot supply arbitrary paths.
        public func write(_ name: String, data: Data) throws {
            guard CacheDirectory.payloadNames.contains(name) else { throw CacheError.unsafePath }
            try directory.write(name, data: data)
            try directory.recordOwnership()
        }
        public final class WritableFile: @unchecked Sendable {
            private let file: CacheFile
            public var descriptor: Int32 { file.fd }
            fileprivate init(_ file: CacheFile) { self.file = file }
        }
        public func createPinnedFile(_ name: String) throws -> WritableFile {
            guard CacheDirectory.payloadNames.contains(name), root.isBound,
                  root.matches(self.name, directory.info) else { throw CacheError.unsafePath }
            let file = try directory.createFile(name)
            try directory.recordOwnership()
            return WritableFile(file)
        }
        fileprivate func commit(payload: Data) throws -> Lease {
            try Task.checkCancellation()
            guard payload.count <= 16 * 1_048_576 else { throw CacheError.invalidArtifact }
            var records: [String: FileRecord] = [:]
            let files = try directory.safeOwnedFiles()
            guard files["manifest.json"] == nil else { throw CacheError.invalidArtifact }
            for (name, file) in files where CacheDirectory.payloadNames.contains(name) {
                records[name] = FileRecord(bytes: file.info.st_size, sha256: try file.fingerprint())
                guard fsync(file.fd) == 0, fchmod(file.fd, 0o400) == 0 else { throw CacheError.io(errno) }
            }
            let sealedFiles = try directory.safeOwnedFiles()
            let manifest = Manifest(generation: generation, key: key, payload: payload, files: records)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try directory.write("manifest.json", data: encoder.encode(manifest))
            try directory.recordOwnership()
            let finalFiles = try directory.safeOwnedFiles()
            guard Set(finalFiles.keys) == Set(records.keys).union(["owner", "manifest.json", "ownership.json"]),
                  root.isBound, root.matches(name, directory.info), fsync(directory.fd) == 0 else { throw CacheError.invalidArtifact }
            for (name, file) in sealedFiles where name != "ownership.json" {
                guard directory.matches(name, file.info), file.unchanged else { throw CacheError.invalidArtifact }
            }
            try Task.checkCancellation()
            let finalName = "entry_" + (try key.digest) + "_" + generation
            guard renameatx_np(root.fd, name, root.fd, finalName, UInt32(RENAME_EXCL)) == 0 else { throw CacheError.io(errno) }
            committed = true; name = finalName
            directory.closeWriters()
            // No fallible operation follows atomic publication. Descriptors remain pinned across rename.
            return Lease(root: root, directory: directory, name: finalName, key: key, payload: payload, files: finalFiles, cacheHit: false, onRelease: { [root, policy] in try? OwnedArtifactCache.evict(root, quota: policy.bytes) })
        }
    }
}

private final class QuotaPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var bytes: Int64 { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

private final class CacheFile: @unchecked Sendable {
    let fd: Int32
    let info: stat
    init(_ fd: Int32) throws {
        guard fd >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
            close(fd); throw OwnedArtifactCache.CacheError.unsafePath
        }
        self.fd = fd; info = value
    }
    deinit { close(fd) }
    var unchanged: Bool {
        var value = stat()
        return fstat(fd, &value) == 0 && Self.sameState(info, value)
    }
    static func sameState(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func fingerprint() throws -> String {
        var hash = SHA256(), offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = pread(fd, &buffer, buffer.count, offset)
            guard count >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        guard unchanged else { throw OwnedArtifactCache.CacheError.invalidArtifact }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func data(maximum: Int) throws -> Data {
        guard info.st_size >= 0, info.st_size <= maximum else { throw OwnedArtifactCache.CacheError.invalidArtifact }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count, unchanged else { throw OwnedArtifactCache.CacheError.invalidArtifact }
        return data
    }
}

private final class CacheDirectory: @unchecked Sendable {
    static let payloadNames: Set<String> = ["left.caf", "right.caf", "stereo.caf", "envelope.bin", "result.json"]
    let fd: Int32
    let info: stat
    let url: URL
    private var rootMarker: CacheFile?
    private let parent: CacheDirectory?
    private var createdFiles: [String: CacheFile] = [:]
    init(fd: Int32, url: URL, parent: CacheDirectory? = nil) throws {
        guard fd >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { close(fd); throw OwnedArtifactCache.CacheError.unsafePath }
        self.fd = fd; info = value; self.url = url; self.parent = parent
    }
    deinit { close(fd) }
    static func ownedRoot(_ requested: URL) throws -> CacheDirectory {
        // Foundation rewrites /private/var back to /var on macOS. Resolve only the three
        // platform aliases explicitly; every other component is traversed with O_NOFOLLOW.
        let components = requested.standardizedFileURL.pathComponents
        let systemAlias = components.count > 1 && ["var", "tmp", "etc"].contains(components[1])
        let url = systemAlias ? URL(fileURLWithPath: "/private" + requested.standardizedFileURL.path) : requested.standardizedFileURL
        guard url.isFileURL, !url.path.contains("\0"), url.pathComponents.count > 2 else { throw OwnedArtifactCache.CacheError.unsafePath }
        let parentURL = url.deletingLastPathComponent()
        var parent = try CacheDirectory(fd: open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), url: URL(fileURLWithPath: "/"))
        for component in parentURL.pathComponents.dropFirst() { parent = try parent.child(component) }
        let created = mkdirat(parent.fd, url.lastPathComponent, 0o700) == 0
        guard created || errno == EEXIST else { throw OwnedArtifactCache.CacheError.io(errno) }
        let root = try parent.child(url.lastPathComponent)
        if created { try root.write("root-version", data: Data((OwnedArtifactCache.format + "\n").utf8)) }
        guard let marker = try? root.file("root-version"),
              try marker.data(maximum: 128) == Data((OwnedArtifactCache.format + "\n").utf8) else { throw OwnedArtifactCache.CacheError.occupiedRoot }
        root.rootMarker = marker
        guard root.isBound else { throw OwnedArtifactCache.CacheError.unsafePath }
        return root
    }
    var isBound: Bool {
        var value = stat()
        if let marker = rootMarker {
            guard marker.unchanged, matches("root-version", marker.info) else { return false }
        }
        if let parent { return parent.isBound && parent.matches(url.lastPathComponent, info) }
        return lstat(url.path, &value) == 0 && value.st_dev == info.st_dev && value.st_ino == info.st_ino
    }
    func matches(_ name: String, _ expected: stat) -> Bool {
        var value = stat()
        return fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 && value.st_dev == expected.st_dev && value.st_ino == expected.st_ino
    }
    func child(_ name: String) throws -> CacheDirectory {
        guard safeName(name) else { throw OwnedArtifactCache.CacheError.unsafePath }
        return try CacheDirectory(fd: openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), url: url.appendingPathComponent(name), parent: self)
    }
    func createDirectory(_ name: String) throws -> CacheDirectory {
        guard safeName(name), isBound, mkdirat(fd, name, 0o700) == 0 else { throw OwnedArtifactCache.CacheError.unsafePath }
        return try child(name)
    }
    func file(_ name: String) throws -> CacheFile {
        guard safeName(name) else { throw OwnedArtifactCache.CacheError.unsafePath }
        return try CacheFile(openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
    }
    func createFile(_ name: String) throws -> CacheFile {
        guard safeName(name) else { throw OwnedArtifactCache.CacheError.unsafePath }
        let file = try CacheFile(openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        createdFiles[name] = file
        return file
    }
    func write(_ name: String, data: Data) throws {
        let file = try createFile(name)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(file.fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard count > 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
            offset += count
        }
        guard fsync(file.fd) == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
    }
    private struct NodeIdentity: Codable {
        var device: Int32; var inode: UInt64
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
        func matches(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }
    }
    private struct Ownership: Codable {
        var format = OwnedArtifactCache.format
        var files: [String: NodeIdentity]
    }
    func recordOwnership() throws {
        let next = try createFile(".owner-next")
        var identities = createdFiles.filter { $0.key != "ownership.json" && $0.key != ".owner-next" }.mapValues { NodeIdentity($0.info) }
        identities["ownership.json"] = NodeIdentity(next.info)
        let data = try JSONEncoder().encode(Ownership(files: identities))
        let count = data.withUnsafeBytes { Darwin.write(next.fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(next.fd) == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
        if let old = createdFiles["ownership.json"] {
            guard matches("ownership.json", old.info) else { throw OwnedArtifactCache.CacheError.unsafePath }
        } else {
            var value = stat()
            guard fstatat(fd, "ownership.json", &value, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw OwnedArtifactCache.CacheError.unsafePath }
        }
        guard matches(".owner-next", next.info), renameat(fd, ".owner-next", fd, "ownership.json") == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
        createdFiles.removeValue(forKey: ".owner-next"); createdFiles["ownership.json"] = next
        guard fsync(fd) == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
    }
    func safeOwnedFiles() throws -> [String: CacheFile] {
        let names = try names()
        guard Set(names).isSubset(of: Self.payloadNames.union(["owner", "manifest.json", "ownership.json"])),
              names.contains("owner"), names.contains("ownership.json") else { throw OwnedArtifactCache.CacheError.unsafePath }
        let files = try Dictionary(uniqueKeysWithValues: names.map { ($0, try file($0)) })
        guard try files["owner"]!.data(maximum: 128) == Data((OwnedArtifactCache.format + "\n").utf8) else { throw OwnedArtifactCache.CacheError.unsafePath }
        let record = try JSONDecoder().decode(Ownership.self, from: files["ownership.json"]!.data(maximum: 16_384))
        guard record.format == OwnedArtifactCache.format, Set(record.files.keys) == Set(names) else { throw OwnedArtifactCache.CacheError.unsafePath }
        for (name, file) in files {
            guard record.files[name]?.matches(file.info) == true else { throw OwnedArtifactCache.CacheError.unsafePath }
        }
        return files
    }
    func removeCreatedEntries() {
        for (name, file) in createdFiles where matches(name, file.info) { _ = unlinkat(fd, name, 0) }
    }
    func closeWriters() { createdFiles.removeAll() }
    func removeSelfCreated() {
        guard let parent, parent.isBound, parent.matches(url.lastPathComponent, info) else { return }
        removeCreatedEntries()
        if parent.matches(url.lastPathComponent, info) { _ = unlinkat(parent.fd, url.lastPathComponent, AT_REMOVEDIR) }
    }
    func names() throws -> [String] {
        // dup shares a directory offset: open a new description instead, so repeated scans start at EOF zero.
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scan >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
        guard let stream = fdopendir(scan) else { close(scan); throw OwnedArtifactCache.CacheError.io(errno) }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    /// Interrupted ownership-journal publication can leave a small unknown entry. Reclaim only
    /// previously journaled inodes; preserve unknown/replaced entries and their ownership evidence.
    func recoverStage(_ name: String, directory: CacheDirectory) throws -> Bool {
        guard isBound, matches(name, directory.info) else { return false }
        if let _ = try? directory.safeOwnedFiles() { return try removeOwned(name, directory: directory) }
        let marker = try directory.file("owner"), journal = try directory.file("ownership.json")
        guard try marker.data(maximum: 128) == Data((OwnedArtifactCache.format + "\n").utf8) else { return false }
        let record = try JSONDecoder().decode(Ownership.self, from: journal.data(maximum: 16_384))
        guard record.format == OwnedArtifactCache.format, record.files["owner"]?.matches(marker.info) == true,
              record.files["ownership.json"]?.matches(journal.info) == true,
              Set(record.files.keys).isSubset(of: Self.payloadNames.union(["owner", "ownership.json", "manifest.json"])) else { return false }
        for (fileName, identity) in record.files where Self.payloadNames.contains(fileName) || fileName == "manifest.json" {
            guard let file = try? directory.file(fileName), identity.matches(file.info), directory.matches(fileName, file.info) else { continue }
            _ = unlinkat(directory.fd, fileName, 0)
        }
        return false
    }
    func removeCreated(_ name: String, directory: CacheDirectory) {
        guard isBound, matches(name, directory.info) else { return }
        directory.removeCreatedEntries()
        if matches(name, directory.info) { _ = unlinkat(fd, name, AT_REMOVEDIR) }
    }
    func removeOwned(_ name: String, directory: CacheDirectory) throws -> Bool {
        guard isBound, matches(name, directory.info) else { return false }
        let files = try directory.safeOwnedFiles()
        // Descriptor-relative, identity-fenced cleanup never follows a replaced path or a symlink.
        for (name, file) in files where directory.matches(name, file.info) { _ = unlinkat(directory.fd, name, 0) }
        guard matches(name, directory.info) else { return false }
        return unlinkat(fd, name, AT_REMOVEDIR) == 0
    }
    func touch() throws {
        guard futimens(fd, nil) == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
    }
    private func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// Explicit per-operation scratch ownership for injected/nonpersistent preparation. Construction
/// creates the directory; it never adopts an arbitrary media/project path supplied by a manifest.
public final class OwnedAudioScratch: @unchecked Sendable {
    public let directoryURL: URL
    private let directory: CacheDirectory
    private let lock = NSLock()
    private var pins = 0
    private var disposed = false
    private var cleaned = false
    private var files: [String: CacheFile] = [:]
    public init(parent: URL) throws {
        directory = try CacheDirectory.ownedRoot(parent.appendingPathComponent("RoughScore-scratch-" + UUID().uuidString))
        directoryURL = directory.url
    }
    deinit { directory.removeSelfCreated() }
    /// Bounded copy into an exclusively created inode; sources are opened read-only and never deleted.
    public func copy(from source: URL, named name: String) throws -> URL {
        try lock.withLock {
            guard !disposed, CacheDirectory.payloadNames.contains(name) else { throw OwnedArtifactCache.CacheError.unsafePath }
            let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
            defer { close(input) }
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw OwnedArtifactCache.CacheError.unsafePath }
            let output = try directory.createFile(name)
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(input, &buffer, buffer.count)
                guard count >= 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
                if count == 0 { break }
                var written = 0
                while written < count {
                    let n = buffer.withUnsafeBytes { Darwin.write(output.fd, $0.baseAddress!.advanced(by: written), count - written) }
                    guard n > 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
                    written += n
                }
            }
            guard fsync(output.fd) == 0 else { throw OwnedArtifactCache.CacheError.io(errno) }
            files[name] = try directory.file(name)
            return directoryURL.appendingPathComponent(name)
        }
    }
    public func withPinnedFile<T>(_ name: String, _ read: (URL) throws -> T) throws -> T {
        try lock.withLock {
            guard !disposed, directory.isBound, let expected = files[name] else { throw OwnedArtifactCache.CacheError.unsafePath }
            let file = try directory.file(name)
            guard CacheFile.sameState(expected.info, file.info) else { throw OwnedArtifactCache.CacheError.invalidArtifact }
            let result = try read(URL(fileURLWithPath: "/dev/fd/\(file.fd)"))
            guard file.unchanged, directory.isBound, directory.matches(name, expected.info) else { throw OwnedArtifactCache.CacheError.invalidArtifact }
            return result
        }
    }
    /// Native scratch readers retain both an independent descriptor and a cleanup pin.
    public final class Reader: @unchecked Sendable {
        public let url: URL
        private let file: CacheFile
        private let pin: Pin
        private let owner: OwnedAudioScratch
        private let name: String
        fileprivate init(file: CacheFile, pin: Pin, owner: OwnedAudioScratch, name: String) {
            self.file = file; self.pin = pin; self.owner = owner; self.name = name
            url = URL(fileURLWithPath: "/dev/fd/\(file.fd)")
        }
        public func validate() throws { try owner.validateReader(name, file: file) }
    }
    public func reader(_ name: String) throws -> Reader {
        let pin = try self.pin()
        return try lock.withLock {
            guard !cleaned, directory.isBound, let expected = files[name] else { throw OwnedArtifactCache.CacheError.unsafePath }
            let file = try directory.file(name)
            guard CacheFile.sameState(expected.info, file.info) else { throw OwnedArtifactCache.CacheError.invalidArtifact }
            return Reader(file: file, pin: pin, owner: self, name: name)
        }
    }
    private func validateReader(_ name: String, file: CacheFile) throws {
        try lock.withLock {
            guard !cleaned, directory.isBound, let expected = files[name], file.unchanged,
                  directory.matches(name, expected.info) else { throw OwnedArtifactCache.CacheError.invalidArtifact }
        }
    }
    public final class Pin: @unchecked Sendable {
        private let owner: OwnedAudioScratch
        fileprivate init(_ owner: OwnedAudioScratch) { self.owner = owner }
        deinit { owner.unpin() }
    }
    public func pin() throws -> Pin {
        try lock.withLock {
            guard !disposed, directory.isBound else { throw OwnedArtifactCache.CacheError.unsafePath }
            pins += 1; return Pin(self)
        }
    }
    public func dispose() { lock.withLock { disposed = true; cleanupIfReady() } }
    private func unpin() { lock.withLock { pins -= 1; cleanupIfReady() } }
    private func cleanupIfReady() {
        if disposed, pins == 0, !cleaned { directory.removeSelfCreated(); cleaned = true }
    }
}
