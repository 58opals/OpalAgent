import Darwin

package enum StoreLockFailure: Error, Equatable {
    case busy
    case system(Int32)
}

/// Same-inode advisory exclusion only. Keep the lock file in place across lease releases.
package final class StoreLock: Sendable {
    private let descriptor: Int32

    package init(path: String, createIfMissing: Bool = true) throws {
        let flags = O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
        let fd = open(path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreLockFailure.system(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno; close(fd); throw StoreLockFailure.system(error)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw StoreLockFailure.system(EINVAL)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { throw StoreLockFailure.busy }
            throw StoreLockFailure.system(error)
        }
        descriptor = fd
    }

    deinit {
        close(descriptor)
    }
}
