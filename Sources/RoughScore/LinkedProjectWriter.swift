import Darwin
import Foundation
import RoughScoreCore

/// New linked documents publish through an exclusive sibling rename. Existing unrelated files,
/// including files created during the writer callback, are never overwritten.
@MainActor
enum LinkedProjectWriter {
    /// Publish over only the current durable document. The writer sees a private stage with the
    /// destination basename, so a callback failure never changes the active document's bytes.
    static func replace(_ data: Data, at destination: URL, expected: ScoreProject,
                        write: (Data, URL) throws -> Void, cancellation: () throws -> Void,
                        beforePublication: () throws -> Void = {}, beforeRollback: () throws -> Void = {}) throws {
        let parentURL = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }; defer { close(parent) }
        let name = destination.lastPathComponent
        let old = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard old >= 0 else { throw failure() }; defer { close(old) }
        var oldInfo = stat(), parentInfo = stat()
        guard fstat(old, &oldInfo) == 0, (oldInfo.st_mode & S_IFMT) == S_IFREG,
              fstat(parent, &parentInfo) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: old, closeOnDealloc: false)
        let before = try handle.readToEnd() ?? Data()
        guard try JSONDecoder().decode(ScoreProject.self, from: before).validated() == expected else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stageName = ".roughscore-write-" + UUID().uuidString
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw failure() }
        let stage = openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw failure() }; defer { close(stage) }
        var stageInfo = stat(); guard fstat(stage, &stageInfo) == 0 else { throw failure() }
        var createdFile: stat?
        var retainStage = false
        defer {
            var current = stat()
            if !retainStage, fstatat(parent, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == stageInfo.st_dev, current.st_ino == stageInfo.st_ino {
                // Only the regular file created by this writer is eligible for cleanup.
                if let createdFile, fstatat(stage, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == createdFile.st_dev, current.st_ino == createdFile.st_ino {
                    _ = unlinkat(stage, name, 0)
                }
                _ = unlinkat(parent, stageName, AT_REMOVEDIR)
            }
        }
        let target = parentURL.appendingPathComponent(stageName, isDirectory: true).appendingPathComponent(name)
        do { try write(data, target) }
        catch {
            var partial = stat()
            if fstatat(stage, name, &partial, AT_SYMLINK_NOFOLLOW) == 0,
               (partial.st_mode & S_IFMT) == S_IFREG { createdFile = partial }
            throw error
        }
        var written = stat(); guard fstatat(stage, name, &written, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        createdFile = written
        let staged = openat(stage, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard staged >= 0, (written.st_mode & S_IFMT) == S_IFREG else { throw failure() }
        defer { close(staged) }
        guard try FileHandle(fileDescriptor: staged, closeOnDealloc: false).readToEnd() == data,
              fsync(staged) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try cancellation()
        var current = stat(), parentNow = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == oldInfo.st_dev, current.st_ino == oldInfo.st_ino,
              current.st_size == oldInfo.st_size,
              current.st_mtimespec.tv_sec == oldInfo.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == oldInfo.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == oldInfo.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == oldInfo.st_ctimespec.tv_nsec,
              lstat(parentURL.path, &parentNow) == 0,
              parentNow.st_dev == parentInfo.st_dev, parentNow.st_ino == parentInfo.st_ino else {
            throw CocoaError(.fileWriteUnknown)
        }
        try handle.seek(toOffset: 0)
        guard try handle.readToEnd() == before else { throw CocoaError(.fileWriteUnknown) }
        var stagedNow = stat()
        guard fstatat(stage, name, &stagedNow, AT_SYMLINK_NOFOLLOW) == 0,
              sameState(stagedNow, written) else { throw CocoaError(.fileWriteUnknown) }
        do {
            try AtomicDocumentPublication.replace(stagingParent: stage, stagedName: name,
                destinationParent: parent, destinationName: name,
                verifyOld: { try AtomicDocumentPublication.matchesFile(parent: $0, name: $1, receipt: oldInfo, bytes: before) },
                verifyNew: { try AtomicDocumentPublication.matchesFile(parent: $0, name: $1, receipt: written, bytes: data) },
                removeOld: {
                    var displaced = stat()
                    if fstatat(stage, name, &displaced, AT_SYMLINK_NOFOLLOW) == 0,
                       displaced.st_dev == oldInfo.st_dev, displaced.st_ino == oldInfo.st_ino { _ = unlinkat(stage, name, 0) }
                }, bindingsValid: { AtomicDocumentPublication.directoryIsAt(parent, url: parentURL) },
                beforePublication: beforePublication, beforeRollback: beforeRollback)
        } catch let conflict as AtomicDocumentPublication.Conflict {
            retainStage = conflict.retained
            throw conflict
        }
    }

    static func create(_ data: Data, at destination: URL,
                       write: (Data, URL) throws -> Void, cancellation: () throws -> Void) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "roughscore",
              !destination.path.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        let parentURL = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0 else { throw failure() }
        var existing = stat()
        guard fstatat(parent, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT
        else { throw CocoaError(.fileWriteFileExists) }
        let name = ".roughscore-json-" + UUID().uuidString
        let stage = parentURL.appendingPathComponent(name)
        var receipt: stat?
        defer {
            if let receipt {
                var current = stat()
                if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == receipt.st_dev, current.st_ino == receipt.st_ino { _ = unlinkat(parent, name, 0) }
            }
        }
        do { try write(data, stage) }
        catch {
            // The callback can fail after writing its own stage. Only a regular file at this unique
            // operation-created name is adopted, never a directory or a symlink.
            var current = stat()
            if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, (current.st_mode & S_IFMT) == S_IFREG { receipt = current }
            throw error
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure() }
        receipt = info
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard try handle.readToEnd() == data, fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try cancellation()
        var parentNow = stat(), stageNow = stat()
        guard lstat(parentURL.path, &parentNow) == 0,
              parentNow.st_dev == parentInfo.st_dev, parentNow.st_ino == parentInfo.st_ino,
              fstatat(parent, name, &stageNow, AT_SYMLINK_NOFOLLOW) == 0,
              sameState(stageNow, info) else { throw CocoaError(.fileWriteUnknown) }
        guard renameatx_np(parent, name, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw failure() }
    }
    private static func sameState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    private static func failure() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
