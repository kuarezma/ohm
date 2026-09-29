import Darwin
import Foundation

/// `flock(2)` on a lock file opened with `O_CLOEXEC` (ADR 0004 § 6: an inherited descriptor would keep
/// the lock alive after Ohm dies and the watcher would never wake). The kernel releases the lock when
/// the last descriptor closes, i.e. when the holding process dies by any means.
public final class FileLock {
    public let path: String
    private var fd: Int32

    public init(path: String) throws {
        self.path = path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 { throw JournalError.open(errno) }
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Blocks until the exclusive lock is held (retries on EINTR).
    public func lockExclusiveBlocking() -> Bool {
        while true {
            if flock(fd, LOCK_EX) == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    public func tryLockExclusive() -> Bool { flock(fd, LOCK_EX | LOCK_NB) == 0 }

    /// Non-blocking attempts for up to `seconds` (ADR 0004 § 6: the watcher may be recovering).
    public func tryLockExclusive(retryFor seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if tryLockExclusive() { return true }
            usleep(50_000)
        } while Date() < deadline
        return false
    }

    public func unlock() { flock(fd, LOCK_UN) }

    /// True if another open file description holds the lock. Implements the § 6 probe:
    /// `flock(LOCK_SH | LOCK_NB)` succeeding means nobody holds `LOCK_EX`.
    public static func isHeldByAnother(path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}

/// Proof that the caller holds `owner.lock` (ADR 0004 D6). Only obtainable through `acquire`.
public final class OwnerLock {
    public let paths: JournalPaths
    private let lock: FileLock

    private init(paths: JournalPaths, lock: FileLock) {
        self.paths = paths
        self.lock = lock
    }

    public enum Failure: Error, Equatable { case cannotOpen(Int32), heldByAnother }

    /// Ohm launch and CLI: non-blocking with retries for `retryFor` seconds (default 5 s, § 6).
    public static func acquire(paths: JournalPaths, retryFor seconds: Double = 5) throws -> OwnerLock {
        paths.ensureDirectory()
        let l: FileLock
        do { l = try FileLock(path: paths.ownerLock) } catch JournalError.open(let e) {
            throw Failure.cannotOpen(e)
        }
        guard l.tryLockExclusive(retryFor: seconds) else { throw Failure.heldByAnother }
        return OwnerLock(paths: paths, lock: l)
    }

    /// Watcher: blocks while Ohm lives; returns when Ohm died or released the lock.
    public static func acquireBlocking(paths: JournalPaths) throws -> OwnerLock {
        paths.ensureDirectory()
        let l: FileLock
        do { l = try FileLock(path: paths.ownerLock) } catch JournalError.open(let e) {
            throw Failure.cannotOpen(e)
        }
        guard l.lockExclusiveBlocking() else { throw Failure.cannotOpen(errno) }
        return OwnerLock(paths: paths, lock: l)
    }

    public func release() { lock.unlock() }
}
