import AudioToolbox
import CryptoKit
import Darwin
import Foundation

/// A collected directory, distinct from a linked v1 JSON document. Does not activate an editor document.
public enum PortableProjectPackage {
    public static let format = "org.roughscore.portable-project"
    public static let version = 1
    public static let fileExtension = "roughscorepkg"
    public static let copyChunkBytes = 1_048_576
    private static let maximumJSONBytes = 16 * 1_048_576

    public enum PackageError: Error, Equatable {
        case invalidDestination, destinationExists, unsafePath, invalidResource, sourceChanged
        case invalidPackage, unsupportedVersion, mediaUnavailable
    }

    /// Value snapshot. Resolving reopens and verifies bytes, so subsequent package tampering fails closed.
    public struct Snapshot: Sendable {
        public let root: URL
        public let project: ScoreProject
        private let rootDevice: dev_t
        private let rootInode: ino_t
        private let documentInode: ino_t
        fileprivate init(root: URL, project: ScoreProject, directory: stat, document: stat) {
            self.root = root; self.project = project
            rootDevice = directory.st_dev; rootInode = directory.st_ino; documentInode = document.st_ino
        }
        fileprivate func matches(directory: stat, document: stat, project: ScoreProject) -> Bool {
            rootDevice == directory.st_dev && rootInode == directory.st_ino &&
                documentInode == document.st_ino && self.project == project
        }
        public func validate(cancellation: () throws -> Void = {}) throws {
            let read = try validatedRead(at: root, cancellation: cancellation, hooks: Hooks())
            guard matches(directory: read.fence.directory.info, document: read.fence.files[0].1.info,
                          project: read.snapshot.project) else { throw PackageError.sourceChanged }
        }
        public func resolve(assetID: UUID, cancellation: () throws -> Void = {}) throws -> URL {
            guard let asset = project.assets?.first(where: { $0.id == assetID }), let identity = asset.identity else {
                throw PackageError.invalidResource
            }
            let directory = try Directory(root)
            let file = try directory.file(asset.reference.path)
            guard directory.info.st_dev == rootDevice, directory.info.st_ino == rootInode,
                  try verifiedIdentity(file, cancellation: cancellation) == identity, directory.isAt(root),
                  sameFile(try directory.file(asset.reference.path).info, file.info) else { throw PackageError.invalidResource }
            try check(cancellation)
            return root.appendingPathComponent(asset.reference.path)
        }
    }

    private struct Document: Codable {
        var format: String
        var version: Int
        var project: ScoreProject
    }

    /// Checkpoints also provide deterministic failure injection to package IO tests. No global mutable hooks.
    enum Checkpoint: Equatable {
        case copying(Int), writingProject, validating, committing
    }
    struct Hooks {
        var checkpoint: (Checkpoint) throws -> Void = { _ in }
        var readDirectory: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) }
    }

    /// Collect all declared media or fail; missing/offline media is never silently omitted.
    /// `sourceRoot` is mandatory when the input contains contained references. No existing destination is replaced.
    public static func collect(_ project: ScoreProject, to destination: URL, sourceRoot: URL? = nil,
                               cancellation: () throws -> Void = {}, verifyingExpectedIdentities: Bool = false) throws -> Snapshot {
        try collect(project, to: destination, sourceRoot: sourceRoot, cancellation: cancellation, hooks: Hooks(),
                    verifyingExpectedIdentities: verifyingExpectedIdentities)
    }

    /// A package is a closed resource set: publishing another document inside it invalidates it.
    /// Check canonical components and existing ancestor identities, including symlink/case aliases,
    /// before any staging. Normal replacement of the active package uses `update` instead.
    public static func validateDestination(_ destination: URL, outside packageRoot: URL) throws {
        guard destination.isFileURL, packageRoot.isFileURL else { throw PackageError.invalidDestination }
        let rootURL = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        let root = try Directory(rootURL)
        let components = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if components.starts(with: rootURL.pathComponents) { throw PackageError.invalidDestination }
        for depth in stride(from: components.count, through: 1, by: -1) {
            let ancestor = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(depth))), isDirectory: true)
            let resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
            guard let existing = try? Directory(resolved) else { continue }
            // Resolve the nearest existing ancestor first: a missing leaf does not resolve ancestor
            // symlinks on Foundation. Its canonical ancestors also catch aliases into Media.
            let canonical = resolved.pathComponents
            if canonical.starts(with: rootURL.pathComponents) { throw PackageError.invalidDestination }
            for prefix in stride(from: canonical.count, through: 1, by: -1) {
                let url = URL(fileURLWithPath: NSString.path(withComponents: Array(canonical.prefix(prefix))), isDirectory: true)
                if let directory = prefix == canonical.count ? existing : try? Directory(url),
                   sameFile(directory.info, root.info) { throw PackageError.invalidDestination }
            }
            return
        }
        throw PackageError.invalidDestination
    }

    /// Replace only the exact previously opened/saved package. Staging is a sibling; resources and
    /// metadata publish together. An unrelated directory or a stale/ABA document is never overwritten.
    public static func update(_ project: ScoreProject, replacing expected: Snapshot,
                              cancellation: () throws -> Void = {}) throws -> Snapshot {
        try update(project, replacing: expected, cancellation: cancellation, hooks: Hooks())
    }

    static func update(_ project: ScoreProject, replacing expected: Snapshot,
                       cancellation: () throws -> Void = {}, hooks: Hooks) throws -> Snapshot {
        let candidate = try project.validated()
        let unchangedResources = candidate.assets?.map { ($0.id, $0.reference, $0.identity) }
        let oldResources = expected.project.assets?.map { ($0.id, $0.reference, $0.identity) }
        let sameResources = (unchangedResources ?? []).elementsEqual(oldResources ?? [], by: {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        }) && candidate.audioPath == nil
        if !sameResources {
            return try collect(candidate, to: expected.root, sourceRoot: expected.root,
                               cancellation: cancellation, hooks: hooks, replacing: expected, verifyingExpectedIdentities: true)
        }
        // Notes/offset/tuning changes do not recopy media. Publish just the complete envelope via
        // a descriptor-relative sibling-file rename while retaining the old resource validation fence.
        let read = try validatedRead(at: expected.root, cancellation: cancellation, hooks: hooks)
        guard expected.matches(directory: read.fence.directory.info, document: read.fence.files[0].1.info,
                               project: read.snapshot.project) else { throw PackageError.sourceChanged }
        let parentURL = expected.root.deletingLastPathComponent()
        let parent = try Directory(parentURL)
        let name = ".roughscore-metadata-" + UUID().uuidString
        let file = try parent.createFile(name)
        defer { parent.removeCreatedEntries() }
        try hooks.checkpoint(.writingProject)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(format: format, version: version, project: candidate))
        guard data.count <= maximumJSONBytes else { throw PackageError.invalidPackage }
        try file.handle.write(contentsOf: data); try file.handle.synchronize()
        try hooks.checkpoint(.validating)
        try file.handle.seek(toOffset: 0)
        guard try file.handle.readToEnd() == data else { throw PackageError.invalidPackage }
        var writtenInfo = stat()
        guard fstat(file.fd, &writtenInfo) == 0 else { throw posixError() }
        try hooks.checkpoint(.committing)
        try check(cancellation)
        try read.fence.revalidate()
        guard parent.isAt(parentURL), parent.matches(name, file.info),
              sameState(try parent.file(name).info, writtenInfo) else { throw PackageError.sourceChanged }
        guard renameat(parent.fd, name, read.fence.directory.fd, "project.json") == 0 else { throw posixError() }
        return Snapshot(root: expected.root, project: candidate, directory: read.fence.directory.info, document: file.info)
    }

    static func collect(_ project: ScoreProject, to destination: URL, sourceRoot: URL? = nil,
                        cancellation: () throws -> Void = {}, hooks: Hooks, replacing expected: Snapshot? = nil, verifyingExpectedIdentities: Bool = false) throws -> Snapshot {
        var candidate = try project.validated()
        try check(cancellation)
        guard destination.isFileURL, !destination.path.contains("\0"),
              destination.pathExtension == fileExtension,
              !["", ".", ".."].contains(destination.lastPathComponent) else { throw PackageError.invalidDestination }
        if expected == nil, let sourceRoot { try validateDestination(destination, outside: sourceRoot) }
        let parentURL = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parent = try Directory(parentURL)
        let destinationName = destination.lastPathComponent
        let previous = try expected.map { receipt -> (snapshot: Snapshot, fence: ValidationFence) in
            let read = try validatedRead(at: destination, cancellation: cancellation, hooks: hooks)
            guard receipt.root.standardizedFileURL == destination.standardizedFileURL,
                  receipt.matches(directory: read.fence.directory.info, document: read.fence.files[0].1.info,
                                  project: read.snapshot.project) else { throw PackageError.sourceChanged }
            return read
        }
        if previous == nil, parent.exists(destinationName) { throw PackageError.destinationExists }
        let stageName = ".roughscore-stage-" + UUID().uuidString
        guard mkdirat(parent.fd, stageName, 0o700) == 0 else { throw posixError() }
        let stageURL = parentURL.appendingPathComponent(stageName, isDirectory: true)
        var ownedStageInfo = stat()
        guard fstatat(parent.fd, stageName, &ownedStageInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        var committed = false
        var ownedStage: Directory?
        defer {
            // Only operation-created entries, through pinned descriptors; never traverse stageURL.
            if !committed, parent.matches(stageName, ownedStageInfo) {
                ownedStage?.removeCreatedEntries()
                if parent.matches(stageName, ownedStageInfo) { _ = unlinkat(parent.fd, stageName, AT_REMOVEDIR) }
            }
        }
        let stage = try Directory(parent: parent, name: stageName)
        ownedStage = stage
        guard sameFile(stage.info, ownedStageInfo) else { throw PackageError.unsafePath }
        var assets = candidate.assets ?? []
        if candidate.assets == nil, let legacyPath = candidate.audioPath {
            // Allocate a new asset UUID, not a claimed historical content identity or numeric tuning.
            assets = [AudioAsset(reference: AudioReference(path: legacyPath))]
        }
        let sourceDirectory = try sourceRoot.map { try Directory($0.resolvingSymlinksInPath().standardizedFileURL) }
        let media = try assets.isEmpty ? nil : stage.createDirectory("Media")
        var sources: [(AudioReference, File)] = []
        for index in assets.indices {
            _ = try assets[index].validated()
            try check(cancellation)
            let source: File
            switch assets[index].reference.kind {
            case .external:
                let url = URL(fileURLWithPath: assets[index].reference.path).resolvingSymlinksInPath()
                source = try File(url)
            case .contained:
                guard let sourceDirectory else { throw PackageError.mediaUnavailable }
                source = try sourceDirectory.file(assets[index].reference.path)
            }
            let ext = URL(fileURLWithPath: assets[index].reference.path).pathExtension.lowercased()
            let safeExtension = !ext.isEmpty && ext.count <= 16 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "audio"
            let path = "Media/" + assets[index].id.uuidString + "." + safeExtension
            let output = try media!.createFile(URL(fileURLWithPath: path).lastPathComponent)
            let copiedHash = try copy(source, to: output, cancellation: cancellation, hooks: hooks)
            let identity = try verifiedIdentity(stage.file(path), cancellation: cancellation)
            guard identity.sha256 == copiedHash, try fingerprint(source, cancellation: cancellation) == copiedHash,
                  source.unchanged, (!verifyingExpectedIdentities || assets[index].identity.map({ $0 == identity }) ?? true) else { throw PackageError.sourceChanged }
            switch assets[index].reference.kind {
            case .external:
                let reopened = try File(URL(fileURLWithPath: assets[index].reference.path).resolvingSymlinksInPath())
                guard sameState(reopened.info, source.info) else { throw PackageError.sourceChanged }
            case .contained:
                guard let sourceDirectory, let sourceRoot, sourceDirectory.isAt(sourceRoot.standardizedFileURL),
                      sameState(try sourceDirectory.file(assets[index].reference.path).info, source.info)
                else { throw PackageError.sourceChanged }
            }
            sources.append((assets[index].reference, source))
            assets[index].reference = AudioReference(kind: .contained, path: path)
            assets[index].identity = identity
        }
        candidate.audioPath = nil
        candidate.assets = assets.isEmpty ? nil : assets
        // Historical summaries only survive when their entire independent identity is proven by these bytes.
        candidate.analyses = candidate.analyses.filter { _, summary in
            guard let p = summary.provenance else { return false }
            return assets.contains { $0.id == p.assetID && $0.identity == p.identity }
        }
        _ = try candidate.validated()
        try check(cancellation)
        try hooks.checkpoint(.writingProject)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(Document(format: format, version: version, project: candidate))
        guard json.count <= maximumJSONBytes else { throw PackageError.invalidPackage }
        let jsonFile = try stage.createFile("project.json")
        try jsonFile.handle.write(contentsOf: json)
        try jsonFile.handle.synchronize()
        try hooks.checkpoint(.validating)
        let validated = try validatedRead(at: stageURL, cancellation: cancellation, hooks: hooks)
        guard validated.snapshot.project == candidate else { throw PackageError.invalidPackage }
        guard fsync(stage.fd) == 0 else { throw posixError() }
        try hooks.checkpoint(.committing)
        try check(cancellation)
        // Retain the descriptors and mutation state used to validate JSON, media and every directory.
        try validated.fence.revalidate()
        for (reference, file) in sources {
            let reopened: File
            if reference.kind == .external { reopened = try File(URL(fileURLWithPath: reference.path).resolvingSymlinksInPath()) }
            else {
                guard let sourceDirectory, let sourceRoot, sourceDirectory.isAt(sourceRoot.standardizedFileURL) else { throw PackageError.sourceChanged }
                reopened = try sourceDirectory.file(reference.path)
            }
            guard file.unchanged, sameState(file.info, reopened.info) else { throw PackageError.sourceChanged }
        }
        guard parent.matches(stageName, stage.info), parent.isAt(parentURL) else { throw PackageError.unsafePath }
        if let previous {
            try previous.fence.revalidate()
            guard parent.matches(destinationName, previous.fence.directory.info) else { throw PackageError.sourceChanged }
            guard renameatx_np(parent.fd, stageName, parent.fd, destinationName, UInt32(RENAME_SWAP)) == 0 else {
                throw posixError()
            }
            committed = true
            // Only the verified old document's declared entries, through retained descriptors.
            // Unknown/replaced entries are left alone; never recursively delete a pathname.
            if parent.matches(stageName, previous.fence.directory.info) {
                previous.fence.removeVerifiedEntries()
                if parent.matches(stageName, previous.fence.directory.info) { _ = unlinkat(parent.fd, stageName, AT_REMOVEDIR) }
            }
        } else {
            // RENAME_EXCL atomically rejects collisions, including late creations.
            guard renameatx_np(parent.fd, stageName, parent.fd, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST || errno == ENOTEMPTY { throw PackageError.destinationExists }
                throw posixError()
            }
            committed = true
        }
        return Snapshot(root: parentURL.appendingPathComponent(destinationName, isDirectory: true),
                        project: candidate, directory: stage.info, document: jsonFile.info)
    }

    public static func read(at root: URL, cancellation: () throws -> Void = {}) throws -> Snapshot {
        try read(at: root, cancellation: cancellation, hooks: Hooks())
    }

    static func read(at root: URL, cancellation: () throws -> Void = {}, hooks: Hooks) throws -> Snapshot {
        try validatedRead(at: root, cancellation: cancellation, hooks: hooks).snapshot
    }

    private static func validatedRead(at root: URL, cancellation: () throws -> Void, hooks: Hooks) throws
        -> (snapshot: Snapshot, fence: ValidationFence) {
        try check(cancellation)
        guard root.isFileURL else { throw PackageError.unsafePath }
        let canonical = root.standardizedFileURL
        let directory = try Directory(canonical)
        let json = try directory.file("project.json")
        guard json.info.st_size <= maximumJSONBytes else { throw PackageError.invalidPackage }
        let data = try json.handle.read(upToCount: maximumJSONBytes + 1) ?? Data()
        guard data.count <= maximumJSONBytes else { throw PackageError.invalidPackage }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format == format else { throw PackageError.invalidPackage }
        guard document.version == version else { throw PackageError.unsupportedVersion }
        let project = try document.project.validated()
        guard project.audioPath == nil else { throw PackageError.unsafePath }
        let assets = project.assets ?? []
        var expected = Set(["project.json"])
        var verifiedFiles: [(String, File)] = [("project.json", json)]
        for asset in assets {
            try check(cancellation)
            guard asset.reference.kind == .contained, let identity = asset.identity else { throw PackageError.invalidResource }
            let parts = try components(asset.reference.path)
            guard parts.count == 2, parts[0] == "Media", expected.insert(asset.reference.path).inserted else {
                throw PackageError.invalidResource
            }
            let file = try directory.file(asset.reference.path)
            guard try verifiedIdentity(file, cancellation: cancellation) == identity else { throw PackageError.invalidResource }
            verifiedFiles.append((asset.reference.path, file))
        }
        // Strict contract: no undeclared files, directories, device nodes, or symlinks (even unused ones).
        let directories = try directory.validateTree(expected: expected, cancellation: cancellation, hooks: hooks)
        let fence = ValidationFence(root: canonical, directory: directory, files: verifiedFiles, directories: directories)
        try check(cancellation)
        try fence.revalidate()
        return (Snapshot(root: canonical, project: project, directory: directory.info, document: json.info), fence)
    }

    private static func check(_ cancellation: () throws -> Void) throws {
        try Task.checkCancellation()
        try cancellation()
    }
    private static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func components(_ path: String) throws -> [String] {
        _ = try AudioReference(kind: .contained, path: path).validated()
        return path.split(separator: "/").map(String.init)
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func regular(_ s: stat) -> Bool { (s.st_mode & S_IFMT) == S_IFREG }
    private static func sameState(_ a: stat, _ b: stat) -> Bool {
        sameFile(a, b) && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private struct ValidationFence {
        let root: URL
        let directory: Directory
        let files: [(String, File)]
        let directories: [(String, Directory)]
        func removeVerifiedEntries() {
            for (path, file) in files {
                if path == "project.json", directory.matches(path, file.info) { _ = unlinkat(directory.fd, path, 0) }
                else if let media = directories.first(where: { $0.0 == "Media" })?.1,
                        directory.matches("Media", media.info), media.matches(URL(fileURLWithPath: path).lastPathComponent, file.info) {
                    _ = unlinkat(media.fd, URL(fileURLWithPath: path).lastPathComponent, 0)
                }
            }
            for (name, child) in directories where directory.matches(name, child.info) {
                _ = unlinkat(directory.fd, name, AT_REMOVEDIR)
            }
        }
        func revalidate() throws {
            for (path, file) in files {
                guard file.unchanged, sameState(try directory.file(path).info, file.info) else {
                    throw PackageError.sourceChanged
                }
            }
            for (name, child) in directories {
                guard child.unchanged, directory.matches(name, child.info) else { throw PackageError.sourceChanged }
            }
            guard directory.unchanged, directory.isAt(root) else { throw PackageError.sourceChanged }
        }
    }

    private final class File {
        let handle: FileHandle
        let info: stat
        var fd: Int32 { handle.fileDescriptor }
        init(fd: Int32) throws {
            var s = stat()
            guard fstat(fd, &s) == 0, regular(s) else { close(fd); throw PackageError.invalidResource }
            info = s; handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        convenience init(_ url: URL) throws {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw PackageError.mediaUnavailable }
            try self.init(fd: descriptor)
        }
        var unchanged: Bool {
            var s = stat()
            return fstat(fd, &s) == 0 && sameState(s, info)
        }
    }
    private final class Directory {
        let fd: Int32
        let info: stat
        private var createdFiles: [(String, File)] = []
        private var createdDirectories: [(String, Directory)] = []
        private init(descriptor: Int32) throws {
            guard descriptor >= 0 else { throw posixError() }
            fd = descriptor
            var s = stat()
            guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { close(fd); throw PackageError.unsafePath }
            info = s
        }
        convenience init(parent: Directory, name: String) throws {
            try self.init(descriptor: openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        convenience init(_ url: URL) throws {
            // Resolving and comparing components rejects symlink roots/ancestors rather than accepting string-prefix siblings.
            guard url.standardizedFileURL.pathComponents == url.resolvingSymlinksInPath().standardizedFileURL.pathComponents else {
                throw PackageError.unsafePath
            }
            try self.init(descriptor: open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        deinit { close(fd) }
        var unchanged: Bool {
            var s = stat()
            return fstat(fd, &s) == 0 && sameState(s, info)
        }
        func createDirectory(_ name: String) throws -> Directory {
            guard try components(name).count == 1 else { throw PackageError.unsafePath }
            guard mkdirat(fd, name, 0o700) == 0 else { throw posixError() }
            let child = try Directory(parent: self, name: name)
            createdDirectories.append((name, child))
            return child
        }
        func removeCreatedEntries() {
            // Unknown or replaced entries are left alone, even if that leaves a nonempty owned stage.
            for (name, file) in createdFiles where matches(name, file.info) { _ = unlinkat(fd, name, 0) }
            for (name, child) in createdDirectories where matches(name, child.info) {
                child.removeCreatedEntries()
                if matches(name, child.info) { _ = unlinkat(fd, name, AT_REMOVEDIR) }
            }
        }
        func exists(_ path: String) -> Bool {
            var s = stat()
            return fstatat(fd, path, &s, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
        }
        func matches(_ path: String, _ expected: stat) -> Bool {
            var s = stat()
            return fstatat(fd, path, &s, AT_SYMLINK_NOFOLLOW) == 0 && sameFile(s, expected)
        }
        func isAt(_ url: URL) -> Bool {
            var s = stat()
            return lstat(url.path, &s) == 0 && sameFile(s, info) &&
                url.pathComponents == url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
        func file(_ path: String) throws -> File { try openFile(path, create: false) }
        func createFile(_ name: String) throws -> File {
            guard try components(name).count == 1 else { throw PackageError.unsafePath }
            let file = try openFile(name, create: true)
            createdFiles.append((name, file))
            return file
        }
        private func openFile(_ path: String, create: Bool) throws -> File {
            let parts = try components(path)
            var current = dup(fd)
            guard current >= 0 else { throw posixError() }
            defer { close(current) }
            for part in parts.dropLast() {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PackageError.unsafePath }
                close(current); current = next
            }
            let flags = (create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            let descriptor = openat(current, parts.last!, flags, 0o600)
            guard descriptor >= 0 else { throw PackageError.invalidResource }
            return try File(fd: descriptor)
        }
        func validateTree(expected: Set<String>, cancellation: () throws -> Void, hooks: Hooks) throws -> [(String, Directory)] {
            var seen = Set<String>()
            var directories: [(String, Directory)] = []
            func visit(_ directory: Directory, _ prefix: String) throws {
                let descriptor = directory.fd
                guard let stream = fdopendir(dup(descriptor)) else { throw posixError() }
                defer { closedir(stream) }
                while true {
                    try check(cancellation)
                    errno = 0
                    guard let entry = hooks.readDirectory(stream) else {
                        guard errno == 0 else { throw posixError() }
                        break
                    }
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    let path = prefix + name
                    var s = stat()
                    guard fstatat(descriptor, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                    if (s.st_mode & S_IFMT) == S_IFDIR, path == "Media", expected.count > 1 {
                        let child = try Directory(parent: directory, name: name)
                        guard sameFile(child.info, s) else { throw PackageError.sourceChanged }
                        directories.append((name, child))
                        try visit(child, "Media/")
                    } else {
                        guard regular(s), expected.contains(path) else { throw PackageError.invalidResource }
                        seen.insert(path)
                    }
                }
                guard directory.unchanged else { throw PackageError.sourceChanged }
            }
            try visit(self, "")
            guard seen == expected else { throw PackageError.invalidResource }
            return directories
        }
    }
    private static func fingerprint(_ file: File, cancellation: () throws -> Void) throws -> String {
        try file.handle.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try check(cancellation)
            let data = try file.handle.read(upToCount: copyChunkBytes) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func copy(_ source: File, to output: File, cancellation: () throws -> Void, hooks: Hooks) throws -> String {
        var hash = SHA256(); var chunks = 0
        while true {
            try check(cancellation)
            let data = try source.handle.read(upToCount: copyChunkBytes) ?? Data()
            if data.isEmpty { break }
            try output.handle.write(contentsOf: data)
            hash.update(data: data)
            chunks += 1; try hooks.checkpoint(.copying(chunks))
        }
        try output.handle.synchronize()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func verifiedIdentity(_ file: File, cancellation: () throws -> Void) throws -> AudioContentIdentity {
        let hash = try fingerprint(file, cancellation: cancellation)
        // AudioToolbox callbacks use positional reads on the pinned descriptor. A pathname is never reopened by a decoder.
        var descriptor = file.fd
        let metadata = try withUnsafeMutablePointer(to: &descriptor) { pointer -> (Int, Double, Int64) in
            var audioID: AudioFileID?
            let opened = AudioFileOpenWithCallbacks(pointer, { context, position, count, buffer, actual in
                let fd = context.assumingMemoryBound(to: Int32.self).pointee
                let result = pread(fd, buffer, Int(count), off_t(position))
                guard result >= 0 else { actual.pointee = 0; return kAudioFileUnspecifiedError }
                actual.pointee = UInt32(result); return noErr
            }, nil, { context in
                var info = stat()
                return fstat(context.assumingMemoryBound(to: Int32.self).pointee, &info) == 0 ? info.st_size : 0
            }, nil, 0, &audioID)
            guard opened == noErr, let audioID else { throw PackageError.invalidResource }
            defer { AudioFileClose(audioID) }
            var extended: ExtAudioFileRef?
            guard ExtAudioFileWrapAudioFileID(audioID, false, &extended) == noErr, let extended else {
                throw PackageError.invalidResource
            }
            defer { ExtAudioFileDispose(extended) }
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr else {
                throw PackageError.invalidResource
            }
            var length: Int64 = 0; size = UInt32(MemoryLayout<Int64>.size)
            guard ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileLengthFrames, &size, &length) == noErr,
                  (1...2).contains(format.mChannelsPerFrame), length > 0, format.mSampleRate.isFinite, format.mSampleRate > 0,
                  Double(length) / format.mSampleRate <= 86_400 else { throw PackageError.invalidResource }
            let channels = format.mChannelsPerFrame
            var client = AudioStreamBasicDescription(mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            guard ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else { throw PackageError.invalidResource }
            let capacity: UInt32 = 16_384
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(capacity * channels * 4), alignment: 16)
            defer { storage.deallocate() }
            var frames: Int64 = 0
            while frames < length {
                try check(cancellation)
                var count = UInt32(min(Int64(capacity), length - frames))
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: capacity * channels * 4, mData: storage))
                guard ExtAudioFileRead(extended, &count, &buffers) == noErr, count > 0 else { throw PackageError.invalidResource }
                frames += Int64(count)
            }
            guard frames == length else { throw PackageError.invalidResource }
            return (Int(channels), format.mSampleRate, frames)
        }
        guard file.unchanged, try fingerprint(file, cancellation: cancellation) == hash else { throw PackageError.sourceChanged }
        return try AudioContentIdentity(sha256: hash, channelCount: metadata.0,
                                        sampleRate: metadata.1, frameCount: metadata.2).validated()
    }
}
