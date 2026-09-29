// Test host for ADR 0004 § 10 tests that need a separate process ("Ohm" stand-in that can be
// kill -9'd, the watcher, a crashing process, an event-tap owner, a fake app tree). Test support only:
// every role acts solely on pids passed in by the test, which the test spawned itself.
import COhmSys
import CoreGraphics
import Darwin
import Foundation
import OhmGovernor
import OhmJournal
import OhmModel

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func say(_ s: String) { print("[\(clock_gettime_nsec_np(CLOCK_REALTIME))] \(s)") }

/// A spawned test process presented to the Governor as a hidden, inactive `.regular` app.
final class StaticAppController: AppControlling {
    let infos: [RunningAppInfo]
    init(infos: [RunningAppInfo]) { self.infos = infos }
    func app(pid: Int32) -> RunningAppInfo? { infos.first { $0.pid == pid } }
    func apps(for key: AppKey) -> [RunningAppInfo] { infos.filter { $0.bundleID == key.value } }
    func isActive(pid: Int32) -> Bool { false }
    func isHidden(pid: Int32) -> Bool { true }
    func hide(pid: Int32) -> Bool { true }
    func unhide(pid: Int32) -> Bool { true }
    func hasOnScreenWindows(pid: Int32) -> Bool { false }
}

/// Ready iff some other process holds thawd.lock (an externally started watcher).
final class LockOnlyProtection: ProtectionProviding {
    let paths: JournalPaths
    init(paths: JournalPaths) { self.paths = paths }
    var mode: ProtectionMode = .launchAgent
    var spawnedPid: Int32? { nil }
    func activate() -> ProtectionMode { mode }
    func isReady() -> Bool { FileLock.isHeldByAnother(path: paths.thawdLock) }
    func watcherDied() -> ProtectionMode { mode }
    func abandon() { mode = .none }
}

/// Test processes must never outlive their parent (e.g. if the test runner crashes). A spawned
/// watcher is exempt: outliving the Ohm stand-in is its purpose, and it exits after recovery.
func exitWithParent() {
    let parent = getppid()
    let t = Thread {
        while true {
            if getppid() != parent { exit(0) }
            usleep(200_000)
        }
    }
    t.start()
}
let role = args.count > 1 ? args[1] : ""
if role != "sigtest" && !args.contains("--spawned") { exitWithParent() }

switch role {
case "burn":
    // CPU load for the E-core tests; bounded lifetime.
    let end = Date().addingTimeInterval(Double(arg("--seconds") ?? "60") ?? 60)
    var x: UInt64 = 0
    while Date() < end {
        for i in 0..<1_000_000 { x &+= UInt64(i) ^ (x >> 3) }
    }
    print(x == 42 ? "" : "done")

case "compact-fault", "rewrite-fault":
    // T-024 #2: a short write while renewing the journal (RLIMIT_FSIZE makes write() return short).
    // Records name pids above kern.maxproc, so nothing can ever be signalled.
    guard let dir = arg("--dir") else { exit(2) }
    let paths = JournalPaths(directory: dir)
    signal(SIGXFSZ, SIG_IGN)
    var lim = rlimit()
    getrlimit(RLIMIT_FSIZE, &lim)
    let normal = lim
    func limitFileSize(_ bytes: rlim_t) { var l = normal; l.rlim_cur = bytes; setrlimit(RLIMIT_FSIZE, &l) }
    let dummy = JournalPid(pid: 999_990, start: 1, role: .root)
    if role == "rewrite-fault" {
        do {
            let (j, _) = try JournalSession.open(paths: paths)
            try j.append(JournalRecord(op: .freeze, group: UUID(), app: "dummy", pids: [dummy]), sync: true)
        } catch { say("setup failed \(error)"); exit(1) }
        limitFileSize(40)
        do { _ = try JournalSession.open(paths: paths, ownerLockRetry: 1); say("OPEN ok") } catch { say("OPEN threw \(error)") }
        var l = normal; setrlimit(RLIMIT_FSIZE, &l)
    } else {
        let j: FreezeJournal
        do { (j, _) = try JournalSession.open(paths: paths) } catch { say("setup failed \(error)"); exit(1) }
        let g = UUID()
        try? j.append(JournalRecord(op: .freeze, group: g, app: "dummy", pids: [dummy]), sync: true)
        try? j.append(JournalRecord(op: .thaw, group: g, reason: "user"), sync: false)
        j.compactThresholdBytes = 0
        limitFileSize(40)
        do { try j.compactIfIdle(); say("COMPACT ok") } catch { say("COMPACT threw \(error)") }
        var l = normal; setrlimit(RLIMIT_FSIZE, &l)
        do {
            try j.append(JournalRecord(op: .freeze, group: UUID(), app: "dummy", pids: [dummy]), sync: true)
            say("APPEND ok")
        } catch { say("APPEND threw \(error)") }
    }
    let snap = JournalReader.read(path: paths.journal)
    say("JOURNAL corrupt=\(snap.corrupt) ignoredTail=\(snap.ignoredTail) ops=\(snap.records.map(\.op.rawValue))")

case "thawd":
    ThawWatcher.main(arguments: Array(args.dropFirst()))

case "ohm":
    guard let dir = arg("--dir") else { say("bad args"); exit(2) }
    let freezePid = arg("--freeze-pid").flatMap(Int32.init)
    let eCorePid = arg("--ecore-pid").flatMap(Int32.init)
    let paths = JournalPaths(directory: dir)
    let bundle = arg("--bundle")
    let infos = [freezePid, eCorePid].compactMap { $0 }.compactMap { pid -> RunningAppInfo? in
        guard let id = ProcessProbe.identity(of: pid) else { return nil }
        return RunningAppInfo(identity: id, bundleID: "dev.ohmtest.app\(pid)", bundlePath: bundle,
                              // /bin/sleep and /usr/bin/yes stand in for app binaries; their real path
                              // would trip the systemPath scope veto.
                              executablePath: nil, activationPolicy: .regular, uid: getuid())
    }
    let journal: FreezeJournal
    do { (journal, _) = try JournalSession.open(paths: paths) } catch { say("journal open failed \(error)"); exit(1) }
    let protection: any ProtectionProviding
    if let exe = arg("--spawn-watcher") {
        protection = WatcherProtection(paths: paths, executable: exe, arguments: ["thawd", "--spawned", "--dir", dir],
                                       useLaunchAgent: false)
    } else {
        protection = LockOnlyProtection(paths: paths)
    }
    var cfg = GovernorConfig()
    cfg.healthFile = dir + "/freeze-health.json"
    ThawTable.installSignalHandlers()
    let gov = Governor(config: cfg, journal: journal, appControl: StaticAppController(infos: infos), protection: protection)
    Task {
        let mode = await gov.startProtection()
        say("protection=\(mode)")
        if let pid = eCorePid {
            let o = await gov.perform(.eCore(pid: pid, on: true, origin: .manual))
            say("ECORE \(o)")
        }
        if let pid = freezePid {
            let o = await gov.perform(.freeze(pid: pid, origin: .manual, confirmedBackground: false))
            say("FREEZE \(o)")
        }
        say("READY")
    }
    dispatchMain()

case "sigtest":
    guard let pidS = arg("--pid"), let pid = Int32(pidS), let id = ProcessProbe.identity(of: pid) else { exit(2) }
    ThawTable.installSignalHandlers()
    // --wrong-start simulates pid reuse: the table entry names another process instance (T-024 #6).
    let entry = args.contains("--wrong-start") ? ProcessIdentity(pid: pid, startAbsTime: id.startAbsTime + 1) : id
    _ = ThawTable.add(entry)
    kill(pid, SIGSTOP)
    usleep(50_000)
    say("STOPPED stat=\(ProcessProbe.isStopped(pid) ? "T" : "?") — raising SIGSEGV")
    // Test hook: a real invalid memory access, not raise().
    let bad = UnsafeMutablePointer<Int>(bitPattern: 0x10)!
    bad.pointee = 42
    say("unreachable")

case "eventtap":
    let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
    let cb: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
    if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: cb, userInfo: nil) {
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        say("TAP ok")
        CFRunLoopRun()
    } else {
        say("TAP fail")
        sleep(1000)
    }

case "app-root":
    // Fake app root: optionally spawns children and writes a heartbeat file every 0.5 s.
    let hb = arg("--hb")
    for spec in args.indices.filter({ args[$0] == "--child" }).compactMap({ $0 + 1 < args.count ? args[$0 + 1] : nil }) {
        let parts = spec.split(separator: " ").map(String.init)
        var pid: pid_t = 0
        let argv = parts.map { strdup($0) } + [nil]
        posix_spawn(&pid, parts[0], nil, nil, argv, environ)
        say("child \(pid) \(spec)")
    }
    while true {
        if let hb { FileManager.default.createFile(atPath: hb, contents: Data("\(Date().timeIntervalSince1970)".utf8)) }
        usleep(500_000)
    }

case "app-helper":
    // Helper with a watchdog on the root: exits if the root heartbeat is older than 2 s, or if it
    // observes a > 2 s gap in its own loop (it was frozen together with the root).
    let hb = arg("--hb")
    var last = Date()
    while true {
        usleep(20_000)
        let now = Date()
        if now.timeIntervalSince(last) > 2 { say("helper: own gap, exiting"); exit(3) }
        last = now
        if let hb, let a = try? FileManager.default.attributesOfItem(atPath: hb),
           let m = a[.modificationDate] as? Date, now.timeIntervalSince(m) > 2 {
            say("helper: stale heartbeat, exiting"); exit(3)
        }
    }

default:
    print("usage: OhmTestHost thawd|ohm|sigtest|eventtap|app-root|app-helper …")
    exit(2)
}
