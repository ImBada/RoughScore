import Darwin
import Foundation

/// Exchange first, then verify the entry actually displaced by that atomic operation. A late
/// writer's entry is restored by exchange, never deleted. A second conflicting version is retained.
package enum AtomicDocumentPublication {
    package struct Conflict: LocalizedError, Sendable {
        package let restored: Bool
        package let recoveryURL: URL?
        package var errorDescription: String? {
            var message = restored ? "다른 작업에서 파일을 변경해 저장을 취소하고 이전 파일을 복원했습니다."
                : "다른 작업에서 파일을 변경해 저장을 취소했습니다."
            if let recoveryURL { message += " 추가 파일은 \(recoveryURL.path)에 보관했습니다." }
            return message
        }
    }

    package static func replace(stagingParent: Int32, stagedName: String,
                                destinationParent: Int32, destinationName: String, recoveryURL: URL,
                                verifyOld: (Int32, String) throws -> Bool,
                                verifyNew: (Int32, String) throws -> Bool, removeOld: () -> Void,
                                beforePublication: () throws -> Void = {}, beforeRollback: () throws -> Void = {}) throws {
        try beforePublication()
        guard renameatx_np(stagingParent, stagedName, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if (try? verifyOld(stagingParent, stagedName)) == true,
           (try? verifyNew(destinationParent, destinationName)) == true {
            removeOld()
            return
        }
        // Even if another writer changes the destination during rollback, exchange preserves both
        // entries. Only our verified staging bytes may be removed by the caller's cleanup.
        try? beforeRollback()
        var restored = renameatx_np(stagingParent, stagedName, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0
        if !restored {
            // A concurrent removal can leave no destination. Restore only into that empty name.
            restored = renameatx_np(stagingParent, stagedName, destinationParent, destinationName, UInt32(RENAME_EXCL)) == 0
        }
        var entry = stat()
        let exists = fstatat(stagingParent, stagedName, &entry, AT_SYMLINK_NOFOLLOW) == 0
        let retained = exists && (try? verifyNew(stagingParent, stagedName)) != true
        throw Conflict(restored: restored, recoveryURL: retained ? recoveryURL : nil)
    }

    /// A rename may change ctime. Inode, mode, size, mtime and exact bytes still identify the
    /// displaced/published document; a second stat rejects mutation while reading.
    package static func matchesFile(parent: Int32, name: String, receipt: stat, bytes: Data) throws -> Bool {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var first = stat(), last = stat()
        guard fstat(fd, &first) == 0, (first.st_mode & S_IFMT) == S_IFREG,
              sameContentState(first, receipt), first.st_size == bytes.count else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard try handle.readToEnd() == bytes, fstat(fd, &last) == 0 else { return false }
        return sameContentState(first, last) && first.st_ctimespec.tv_sec == last.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == last.st_ctimespec.tv_nsec
    }

    package static func sameContentState(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
}
