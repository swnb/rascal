import Darwin
import Foundation

package enum JournalOwnerLeaseError: Error, Sendable, Equatable {
    case invalidDirectory(Int32)
    case invalidLockFile(Int32)
    case unsafeLockFile
    case alreadyOwned
}

/// Holds the process fence for the complete lifetime of the SQLite writer.
/// The descriptor is close-on-exec so CrashProbe helpers cannot keep a dead
/// owner's lease alive after the owner process terminates.
package final class JournalOwnerLease: @unchecked Sendable {
    package let epoch: UUID
    private let descriptor: Int32

    package init(journalURL: URL) throws {
        let directoryURL = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let directoryFD = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw JournalOwnerLeaseError.invalidDirectory(errno)
        }
        defer { Darwin.close(directoryFD) }

        let lockName = journalURL.lastPathComponent + ".owner.lock"
        let lockFD = lockName.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard lockFD >= 0 else {
            throw JournalOwnerLeaseError.invalidLockFile(errno)
        }

        var info = stat()
        guard fstat(lockFD, &info) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw JournalOwnerLeaseError.invalidLockFile(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid() else {
            Darwin.close(lockFD)
            throw JournalOwnerLeaseError.unsafeLockFile
        }
        guard fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw JournalOwnerLeaseError.invalidLockFile(code)
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw JournalOwnerLeaseError.alreadyOwned
        }

        descriptor = lockFD
        epoch = UUID()
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    package func descriptorIsCloseOnExec() -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }
}
