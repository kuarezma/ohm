import Darwin
import Foundation
import OhmGovernor
import OhmJournal
import OhmModel
import Synchronization

// Safety rule for every test: signals and scheduling changes only reach pids that the test spawned
// itself. `ProcessBag.cleanup()` always sends SIGCONT before SIGKILL and reaps.

let packageRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}()
let hostPath = packageRoot + "/.build/debug/OhmTestHost"

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }

/// kill(2) that refuses pid <= 1 (0 and -1 would hit the whole process group / every process).
/// Never traps: a crash would skip every teardown and orphan the spawned processes.
@discardableResult
func safeKill(_ pid: Int32, _ sig: Int32) -> Int32 {
    guard pid > 1 else {
        print("T-023 safeKill: refused kill(\(pid), \(sig))")
        return EINVAL
    }
    return Darwin.kill(pid, sig)
}

/// Canonical (/private/var/…) so it compares equal to proc_pidpath results.
func tempDir(_ tag: String) -> String {
    let d = NSTemporaryDirectory() + "ohm-t023-\(tag)-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(d, &buf) != nil else { return d }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func isT(_ pid: Int32) -> Bool { ProcessProbe.isStopped(pid) }

@discardableResult
func waitUntil(_ timeout: Double, poll: Double = 0.005, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        usleep(useconds_t(poll * 1e6))
    }
    return cond()
}

final class ProcessBag: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    private var logs: [Int32: String] = [:]

    /// posix_spawn; stdout/stderr go to a log file when `log` is set.
    @discardableResult
    func spawn(_ path: String, _ args: [String], log: String? = nil, newSession: Bool = false) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let log {
            posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The test runner may ignore SIGTERM/SIGINT; children must start with default dispositions.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if newSession { flags |= Int32(POSIX_SPAWN_SETSID) }
        posix_spawnattr_setflags(&attr, Int16(flags))
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard rc == 0 else {
            print("T-023 spawn \(path) failed \(rc)")
            return -1
        }
        lock.withLock {
            pids.append(pid)
            if let log { logs[pid] = log }
        }
        _ = waitUntil(2) { ProcessProbe.startAbs(pid) != nil }
        return pid
    }

    /// Also tracks pids the test did not spawn directly but created through its own processes.
    /// Identity-checked at cleanup because these are not our children (their pid could be reused).
    func adopt(_ pid: Int32) {
        guard let id = ProcessProbe.identity(of: pid) else { return }
        lock.withLock { adopted.append(id) }
    }
    private var adopted: [ProcessIdentity] = []

    /// SIGKILL + reap (the pid is then free for reuse, so cleanup must not touch it again).
    func kill9(_ pid: Int32) {
        guard !isReaped(pid) else { return }
        safeKill(pid, SIGKILL)
        var st: Int32 = 0
        _ = waitpid(pid, &st, 0)
    }

    /// True if the child is gone and reaped (or was reaped elsewhere): never signal it again.
    private func isReaped(_ pid: Int32) -> Bool {
        var st: Int32 = 0
        let r = waitpid(pid, &st, WNOHANG)
        return r == pid || (r == -1 && errno == ECHILD)
    }

    /// SIGCONT then SIGKILL to every live child, blocking reap, then proof that none survived.
    @discardableResult
    func cleanup() -> [Int32] {
        for id in lock.withLock({ adopted }) where ProcessProbe.matches(id) {
            safeKill(id.pid, SIGCONT)
            safeKill(id.pid, SIGKILL)
        }
        let all = lock.withLock { pids }.filter { $0 > 1 }
        let live = all.filter { !isReaped($0) }
        for p in live { safeKill(p, SIGCONT); safeKill(p, SIGKILL) }
        for p in live { var st: Int32 = 0; _ = waitpid(p, &st, 0) }
        // Adopted processes are not our children: their death is asynchronous to us.
        let adoptedIDs = lock.withLock { adopted }
        _ = waitUntil(2) { !adoptedIDs.contains(where: ProcessProbe.isLive) }
        let survivors = all.filter { p in !isReaped(p) } + adoptedIDs.filter(ProcessProbe.isLive).map(\.pid)
        if !survivors.isEmpty { print("T-023 cleanup: SURVIVORS \(survivors)") }
        return survivors
    }
}

/// Fake app bundle whose executable is a copy of the test host (so helpers are "inside the bundle").
func makeFakeBundle(_ dir: String) -> (bundle: String, exe: String) {
    let bundle = dir + "/Fake.app"
    let macos = bundle + "/Contents/MacOS"
    try? FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
    let exe = macos + "/FakeApp"
    try? FileManager.default.removeItem(atPath: exe)
    try! FileManager.default.copyItem(atPath: hostPath, toPath: exe)
    return (bundle, exe)
}

// MARK: Fakes (Sendable shared state + non-Sendable thin wrappers owned by the Governor)

struct FakeAppEntry {
    var info: RunningAppInfo
    var active = false
    var hidden = true
    var onScreen = false
    /// hide() takes effect after this delay (Phase A wait).
    var hideDelay: Double = 0.1
    var hideRequestedAt: Date?
    var hideCalls = 0
    var unhideCalls = 0
}

final class FakeAppState: Sendable {
    let m = Mutex<[Int32: FakeAppEntry]>([:])
    let onHide = Mutex<(@Sendable (Int32) -> Void)?>(nil)

    func add(_ info: RunningAppInfo, hidden: Bool = true, active: Bool = false) {
        m.withLock { $0[info.pid] = FakeAppEntry(info: info, active: active, hidden: hidden) }
    }
    func entry(_ pid: Int32) -> FakeAppEntry? { m.withLock { $0[pid] } }
    func set(_ pid: Int32, _ f: @Sendable (inout FakeAppEntry) -> Void) {
        m.withLock { if var e = $0[pid] { f(&e); $0[pid] = e } }
    }
}

final class FakeAppControl: AppControlling {
    let s: FakeAppState
    init(_ s: FakeAppState) { self.s = s }
    func app(pid: Int32) -> RunningAppInfo? { s.entry(pid)?.info }
    func apps(for key: AppKey) -> [RunningAppInfo] {
        s.m.withLock { $0.values.filter { $0.info.bundleID == key.value }.map(\.info) }
    }
    func isActive(pid: Int32) -> Bool { s.entry(pid)?.active ?? false }
    func isHidden(pid: Int32) -> Bool {
        s.m.withLock { d in
            guard var e = d[pid] else { return false }
            if !e.hidden, let t = e.hideRequestedAt, Date().timeIntervalSince(t) >= e.hideDelay {
                e.hidden = true
                d[pid] = e
            }
            return e.hidden
        }
    }
    func hide(pid: Int32) -> Bool {
        s.set(pid) { $0.hideCalls += 1; $0.hideRequestedAt = Date() }
        if let hook = s.onHide.withLock({ $0 }) { hook(pid) }
        return true
    }
    func unhide(pid: Int32) -> Bool {
        s.set(pid) { $0.unhideCalls += 1; $0.hidden = false; $0.hideRequestedAt = nil }
        return true
    }
    func hasOnScreenWindows(pid: Int32) -> Bool { s.entry(pid)?.onScreen ?? false }
}

final class FakeProtectionState: Sendable {
    let ready = Atomic<Bool>(true)
}

final class FakeProtection: ProtectionProviding {
    let s: FakeProtectionState
    init(_ s: FakeProtectionState) { self.s = s }
    var mode: ProtectionMode = .launchAgent
    var spawnedPid: Int32? { nil }
    func activate() -> ProtectionMode { mode }
    func isReady() -> Bool { s.ready.load(ordering: .sequentiallyConsistent) }
    func watcherDied() -> ProtectionMode { mode }
    func abandon() { mode = .none }
}

final class ProbeState: Sendable {
    let audio = Mutex<Set<Int32>>([])
    let camera = Atomic<Bool>(false)
    /// Probes that report "could not measure" (T-024 #7).
    let failing = Mutex<Set<String>>([])
}

final class FakeProbes: SafetyProbing {
    let s: ProbeState
    init(_ s: ProbeState) { self.s = s }
    private func fails(_ k: String) -> Bool { s.failing.withLock { $0.contains(k) } }
    func audioActive(pid: Int32) -> Bool? { fails("audio") ? nil : s.audio.withLock { $0.contains(pid) } }
    func cameraInUse() -> Bool? { fails("camera") ? nil : s.camera.load(ordering: .sequentiallyConsistent) }
    func assertionHolders() -> Set<Int32>? { fails("assertions") ? nil : [] }
    func eventTapOwners() -> Set<Int32>? { fails("taps") ? nil : [] }
    func isTraced(pid: Int32) -> Bool? { fails("traced") ? nil : false }
    func outOfBundleChildren(pid: Int32, bundlePath: String) -> [Int32]? { fails("children") ? nil : [] }
}

struct SignalRecord: Sendable, Equatable {
    var pid: Int32
    var sig: Int32
    var ns: UInt64
}

final class SignalLog: Sendable {
    let records = Mutex<[SignalRecord]>([])
    /// pids for which `isStopped` reports false until `stallUntilNs`.
    let stall = Mutex<(Set<Int32>, UInt64)>(([], 0))
    let afterStop = Mutex<(@Sendable (Int32) -> Void)?>(nil)
    /// SIGCONT to these pids fails with the given errno and is not sent (T-024 #1).
    let contFail = Mutex<[Int32: Int32]>([:])
    /// setBackground(pid, on) calls that succeeded.
    let background = Mutex<[(Int32, Bool)]>([])
    /// setBackground(pid, false) fails with EPERM for these pids (T-024 #1).
    let bgOffFail = Mutex<Set<Int32>>([])
    /// identityStatus reports "could not tell" for these pids (T-024 #1).
    let identityUnknown = Mutex<Set<Int32>>([])

    func all() -> [SignalRecord] { records.withLock { $0 } }
    func sent(_ sig: Int32) -> [Int32] { all().filter { $0.sig == sig }.map(\.pid) }
}

/// Real signals, recorded (order, timing) with optional verification stalls.
final class RecordingSignaler: ProcessSignaling {
    let log: SignalLog
    let real = DarwinSignaler()
    init(_ log: SignalLog) { self.log = log }
    func startAbs(_ pid: Int32) -> UInt64? { real.startAbs(pid) }
    func send(_ pid: Int32, _ sig: Int32) -> Int32 {
        if sig == SIGCONT, let e = log.contFail.withLock({ $0[pid] }) { return e }
        let rc = real.send(pid, sig)
        log.records.withLock { $0.append(SignalRecord(pid: pid, sig: sig, ns: nowNs())) }
        if sig == SIGSTOP, let hook = log.afterStop.withLock({ $0 }) { hook(pid) }
        return rc
    }
    func setBackground(_ pid: Int32, _ on: Bool) -> Int32 {
        if !on, log.bgOffFail.withLock({ $0.contains(pid) }) { return EPERM }
        let rc = real.setBackground(pid, on)
        if rc == 0 { log.background.withLock { $0.append((pid, on)) } }
        return rc
    }
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus {
        if log.identityUnknown.withLock({ $0.contains(id.pid) }) { return .unknown(EPERM) }
        return real.identityStatus(id)
    }
    func isStopped(_ pid: Int32) -> Bool {
        let (set, until) = log.stall.withLock { $0 }
        if set.contains(pid), nowNs() < until { return false }
        return real.isStopped(pid)
    }
}

final class TreeState: Sendable {
    /// Called with the pass number (1-based count of enumerations).
    let provider = Mutex<(@Sendable (Int) -> [ProcessIdentity])?>(nil)
    let calls = Atomic<Int>(0)
}

final class FakeTree: ProcessTreeEnumerating {
    let s: TreeState
    init(_ s: TreeState) { self.s = s }
    func helpers(of root: ProcessIdentity, bundlePath: String?) -> [ProcessIdentity] {
        let n = s.calls.add(1, ordering: .sequentiallyConsistent).newValue
        return s.provider.withLock { $0 }?(n) ?? []
    }
}

final class JournalFault: Sendable {
    /// Fail the n-th append (1-based) and every one after it; 0 = never.
    let failFrom = Atomic<Int>(0)
    let count = Atomic<Int>(0)
}

final class FaultyJournal: FreezeJournaling {
    let inner: FreezeJournal
    let fault: JournalFault
    init(_ inner: FreezeJournal, _ fault: JournalFault) {
        self.inner = inner
        self.fault = fault
    }
    var boot: String? { inner.boot }
    func append(_ record: JournalRecord, sync: Bool) throws {
        let n = fault.count.add(1, ordering: .sequentiallyConsistent).newValue
        let from = fault.failFrom.load(ordering: .sequentiallyConsistent)
        if from > 0, n >= from { throw JournalError.injected }
        try inner.append(record, sync: sync)
    }
    func compactIfIdle() throws { try inner.compactIfIdle() }
}

func appInfo(_ pid: Int32, bundleID: String = "dev.ohmtest.fake", bundle: String? = nil,
             policy: AppActivationPolicy = .regular) -> RunningAppInfo {
    RunningAppInfo(identity: ProcessProbe.identity(of: pid)!, bundleID: bundleID, bundlePath: bundle,
                   executablePath: bundle.map { $0 + "/Contents/MacOS/FakeApp" }, activationPolicy: policy, uid: getuid())
}

func testConfig(_ dir: String) -> GovernorConfig {
    var c = GovernorConfig()
    c.healthFile = dir + "/freeze-health.json"
    c.ownBundlePath = nil
    c.appleAllowlist.insert("com.apple.TextEdit")
    return c
}

/// Real journal in `dir` (owner lock held by the test process for the Governor's lifetime).
func openJournal(_ dir: String) throws -> FreezeJournal {
    try JournalSession.open(paths: JournalPaths(directory: dir), ownerLockRetry: 1).0
}

/// P-share thresholds need real Apple Silicon scheduling; GitHub's macOS runners are VMs, so there
/// only the kernel flag (the actual safety property) is asserted.
let onRealHardware = ProcessInfo.processInfo.environment["CI"] == nil

/// 1 while PRIO_DARWIN_BG is set on `pid`, 0 when clear, -1 if unreadable. getpriority(PRIO_DARWIN_PROCESS)
/// reports 0 for other processes even when the flag is set, so read the task's base priority instead:
/// darwin BG pins it to 4 (measured: 31 → 4 → 31). Only valid for non-GUI test processes (no App Nap).
func darwinBG(_ pid: Int32) -> Int32 {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return -1 }
    return info.pti_priority <= 4 ? 1 : 0
}

func pShare(_ pid: Int32, seconds: Double = 1.0) -> Double? {
    guard let a = ProcessProbe.energy(pid) else { return nil }
    usleep(useconds_t(seconds * 1e6))
    guard let b = ProcessProbe.energy(pid), b.total > a.total else { return nil }
    return Double(b.p - a.p) / Double(b.total - a.total)
}

func readLog(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
