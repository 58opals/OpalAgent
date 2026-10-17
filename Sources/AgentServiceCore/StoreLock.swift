import Darwin

package enum StoreLockFailure: Error, Equatable {
    case busy
    case system(Int32)
}

/// Same-inode advisory exclusion only. Keep the lock file in place across lease releases.
package final class StoreLock: Sendable {
    private let descriptor: Int32

    package init(path: String) throws {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreLockFailure.system(errno) }
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
