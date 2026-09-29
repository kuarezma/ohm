// T-013 spike: freeze a GUI app with SIGSTOP, thaw it with SIGCONT the moment it is activated,
// and guarantee no frozen process survives an agent crash (journal + separate watchdog).
//
//   freeze-agent agent <pid> <journal>   recover stale journal, spawn watchdog, freeze <pid>,
//                                        thaw on activation; SIGTERM/SIGINT thaws and exits
//   freeze-agent watchdog <agentPid> <journal>   waits for agent exit (kqueue), thaws journal
//   freeze-agent recover <journal>       next-launch recovery only
//
// Journal lines: "<pid> <ri_proc_start_abstime>". The start time guards against pid reuse:
// an entry is only thawed if the live process with that pid has the same start time.
// All log lines carry CLOCK_REALTIME nanoseconds so the harness can compute latencies.
import AppKit
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }
func log(_ s: String) { print("[\(nowNs())] \(s)") }

func startAbs(_ pid: pid_t) -> UInt64? {
    var ri = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return rc == 0 ? ri.ri_proc_start_abstime : nil
}

struct Journal {
    let path: String
    func read() -> [(pid_t, UInt64)] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 2, let p = pid_t(f[0]), let t = UInt64(f[1]) else { return nil }
            return (p, t)
        }
    }
    // Atomic replace + fsync: the entry must be durable before SIGSTOP is sent.
    func write(_ entries: [(pid_t, UInt64)]) {
        let body = entries.map { "\($0.0) \($0.1)\n" }.joined()
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { log("journal open failed errno=\(errno)"); return }
        _ = body.withCString { Darwin.write(fd, $0, strlen($0)) }
        fsync(fd)
        close(fd)
        rename(tmp, path)
    }
    // Thaw every journalled process that is still the same process, then clear the journal.
    func recover(_ who: String) {
        let entries = read()
        for (pid, t) in entries {
            if let live = startAbs(pid), live == t {
                let rc = kill(pid, SIGCONT)
                log("\(who): recovered pid=\(pid) SIGCONT rc=\(rc)")
            } else {
                log("\(who): skip pid=\(pid) (gone or pid reused)")
            }
        }
        write([])
        if entries.isEmpty { log("\(who): journal empty, nothing to recover") }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: freeze-agent agent <pid> <journal> | watchdog <agentPid> <journal> | recover <journal>")
    exit(2)
}

switch args[1] {
case "recover":
    Journal(path: args[2]).recover("recover")
    exit(0)

case "watchdog":
    let agent = pid_t(args[2])!
    let journal = Journal(path: args[3])
    let kq = kqueue()
    var ev = kevent(ident: UInt(agent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                    fflags: NOTE_EXIT, data: 0, udata: nil)
    if kevent(kq, &ev, 1, nil, 0, nil) != 0 {
        log("watchdog: agent \(agent) already gone (errno=\(errno))")
    } else {
        log("watchdog: watching agent pid=\(agent)")
        var out = kevent()
        _ = kevent(kq, nil, 0, &out, 1, nil)
        log("watchdog: agent pid=\(agent) exited")
    }
    journal.recover("watchdog")
    exit(0)

case "agent":
    guard args.count >= 4, let target = pid_t(args[2]) else { exit(2) }
    let journal = Journal(path: args[3])
    journal.recover("agent-startup")

    // Watchdog is a separate process so that `kill -9` on the agent cannot take it down.
    var wd: pid_t = 0
    let me = String(getpid())
    let exe = Bundle.main.executablePath ?? args[0]
    var cargs: [UnsafeMutablePointer<CChar>?] = [exe, "watchdog", me, journal.path].map { strdup($0) } + [nil]
    if posix_spawn(&wd, exe, nil, nil, &cargs, environ) != 0 { log("agent: watchdog spawn failed"); exit(1) }
    log("agent: pid=\(getpid()) watchdog pid=\(wd)")
    usleep(200_000) // let the watchdog register its kevent before anything is frozen

    guard let app = NSRunningApplication(processIdentifier: target), let t0 = startAbs(target) else {
        log("agent: target \(target) is not a running application"); exit(1)
    }
    log("agent: target pid=\(target) bundle=\(app.bundleIdentifier ?? "?")")

    var frozen = false
    // Hide first so the app is not frontmost; otherwise a later activation of it posts no
    // didActivate notification. Hiding needs the app to be running, so it precedes SIGSTOP.
    func freeze() {
        app.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            journal.write([(target, t0)]) // journal first, then signal
            let rc = kill(target, SIGSTOP)
            frozen = true
            log("agent: FROZE pid=\(target) rc=\(rc) hidden=\(app.isHidden) active=\(app.isActive)")
        }
    }
    func thaw(_ why: String) {
        guard frozen else { return }
        let rc = kill(target, SIGCONT)
        frozen = false
        journal.write([])
        log("agent: THAWED pid=\(target) rc=\(rc) reason=\(why)")
    }

    let nc = NSWorkspace.shared.notificationCenter
    let obs = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                             queue: .main) { note in
        let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = a?.processIdentifier ?? -1
        log("agent: didActivate pid=\(pid) bundle=\(a?.bundleIdentifier ?? "?")")
        if pid == target { thaw("didActivateApplication") }
    }
    _ = obs

    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { thaw("signal \(sig)"); log("agent: exiting"); exit(0) }
        s.resume()
        sources.append(s)
    }
    // SIGUSR1 re-freezes (lets the harness run several activation trials with one agent).
    signal(SIGUSR1, SIG_IGN)
    let u1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    u1.setEventHandler { if !frozen { freeze() } }
    u1.resume()
    sources.append(u1)

    freeze()
    RunLoop.main.run()

default:
    exit(2)
}
