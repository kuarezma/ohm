import Darwin
import Foundation
import OhmJournal
import OhmModel
import ServiceManagement

/// ADR 0004 § 6 protection modes. Freeze and E-core need `isReady()` (part of D1 / admissible()).
public protocol ProtectionProviding: AnyObject {
    var mode: ProtectionMode { get }
    /// Chooses a mode (launchAgent → spawnedWatcher → none) and starts what it needs. Never waits:
    /// the Governor confirms readiness without blocking its queue (T-024 #5).
    func activate() -> ProtectionMode
    func isReady() -> Bool
    /// Pid of the spawned watcher child, if any (the Governor watches it for exit).
    var spawnedPid: Int32? { get }
    /// The spawned child died: restart it (without waiting). Returns the new mode (`.none` if the
    /// restart failed).
    func watcherDied() -> ProtectionMode
    /// The watcher never became ready: stop anything started; mode becomes `.none`.
    func abandon()
}

public final class WatcherProtection: ProtectionProviding {
    public let paths: JournalPaths
    public let executable: String
    public let arguments: [String]
    public let useLaunchAgent: Bool
    public let plistName: String
    public private(set) var mode: ProtectionMode = .none
    public private(set) var spawnedPid: Int32?
    private var spawnedIdentity: ProcessIdentity?
    // Injectable kernel identity read for deterministic startup-failure coverage.
    var identityProbe: (Int32) -> ProcessIdentity? = ProcessProbe.identity(of:)

    /// - Parameters:
    ///   - executable: `Ohm.app/Contents/MacOS/ohm-thawd`.
    ///   - arguments: arguments after argv[0]; default `--spawned --dir <journal dir>`.
    public init(paths: JournalPaths, executable: String, arguments: [String]? = nil,
                useLaunchAgent: Bool = true, plistName: String = "dev.ohm.thawd.plist") {
        self.paths = paths
        self.executable = executable
        self.arguments = arguments ?? ["--spawned", "--dir", paths.directory]
        self.useLaunchAgent = useLaunchAgent
        self.plistName = plistName
    }

    public func activate() -> ProtectionMode {
        if useLaunchAgent, SMAppService.agent(plistName: plistName).status == .enabled,
           FileLock.isHeldByAnother(path: paths.thawdLock) {
            mode = .launchAgent
            return mode
        }
        if FileLock.isHeldByAnother(path: paths.thawdLock) {
            // A protector from the previous Ohm session still waits on owner.lock. Reuse its
            // liveness lock instead of spawning another child blocked on thawd.lock.
            mode = .spawnedWatcher
            return mode
        }
        mode = spawn() ? .spawnedWatcher : .none
        return mode
    }

    public func isReady() -> Bool {
        switch mode {
        case .none:
            return false
        case .launchAgent:
            return SMAppService.agent(plistName: plistName).status == .enabled
                && FileLock.isHeldByAnother(path: paths.thawdLock)
        case .spawnedWatcher:
            if spawnedPid == nil { return FileLock.isHeldByAnother(path: paths.thawdLock) }
            guard let id = spawnedIdentity, ProcessProbe.matches(id),
                  let info = ProcessProbe.bsdInfo(id.pid), info.pbi_status != UInt32(SZOMB) else { return false }
            return FileLock.isHeldByAnother(path: paths.thawdLock)
        }
    }

    public func watcherDied() -> ProtectionMode {
        if let pid = spawnedPid { _ = waitpid(pid, nil, WNOHANG) }
        spawnedPid = nil
        spawnedIdentity = nil
        guard mode == .spawnedWatcher else { return mode }
        if FileLock.isHeldByAnother(path: paths.thawdLock) { return mode }
        mode = spawn() ? .spawnedWatcher : .none
        return mode
    }

    /// posix_spawn with POSIX_SPAWN_SETSID (own session: no process-group signals from Ohm's group)
    /// and POSIX_SPAWN_CLOEXEC_DEFAULT (no inherited descriptor can keep owner.lock alive, § 6).
    /// Does not wait for `thawd.lock`; readiness is confirmed by the Governor.
    private func spawn() -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Default dispositions and an empty mask: nothing Ohm ignores or blocks leaks into the watcher.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attr, argv, environ) == 0 else { return false }
        spawnedPid = pid
        spawnedIdentity = identityProbe(pid)
        return true
    }

    /// A direct, unreaped child cannot have its pid reused. waitpid establishes ownership even
    /// when the startup identity probe failed; ECHILD must never lead to a signal.
    private func stopOwnedChild(signal: Int32) {
        guard let pid = spawnedPid else { return }
        var result: pid_t
        repeat { result = waitpid(pid, nil, WNOHANG) } while result == -1 && errno == EINTR
        guard result == 0 else { return }
        _ = kill(pid, signal)
        repeat { result = waitpid(pid, nil, 0) } while result == -1 && errno == EINTR
    }

    public func abandon() {
        stopOwnedChild(signal: SIGKILL)
        spawnedPid = nil
        spawnedIdentity = nil
        mode = .none
    }

    /// Only when the journal is empty and both features are off (§ 6 "Kayıt ömrü").
    public func stopSpawnedWatcher() {
        stopOwnedChild(signal: SIGTERM)
        spawnedPid = nil
        spawnedIdentity = nil
        mode = .none
    }
}
