import Darwin
import Foundation
import OhmModel

/// Kernel facts about a process (ADR 0004 D3). Every call is synchronous and cheap (one syscall).
public enum ProcessProbe {
    /// `ri_proc_start_abstime`; nil when the process is gone or unreadable.
    public static func startAbs(_ pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? ri.ri_proc_start_abstime : nil
    }

    public static func identity(of pid: Int32) -> ProcessIdentity? {
        startAbs(pid).map { ProcessIdentity(pid: pid, startAbsTime: $0) }
    }

    /// True only if `pid` is alive and is still the same process (pid-reuse guard).
    public static func matches(_ id: ProcessIdentity) -> Bool {
        startAbs(id.pid) == id.startAbsTime
    }

    /// Same process and not a zombie (an exited child its parent has not reaped still has rusage).
    public static func isLive(_ id: ProcessIdentity) -> Bool {
        guard matches(id), let info = bsdInfo(id.pid) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    public static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? info : nil
    }

    /// `pbi_status == SSTOP` (what `ps` shows as `T`).
    public static func isStopped(_ pid: Int32) -> Bool {
        bsdInfo(pid).map { $0.pbi_status == UInt32(SSTOP) } ?? false
    }

    /// `pbi_flags & PROC_FLAG_TRACED`. (ADR 0004 § 2 names `P_TRACED`, which is the kernel `p_flag`
    /// bit; the `proc_bsdinfo.pbi_flags` equivalent is `PROC_FLAG_TRACED`.)
    public static func isTraced(_ pid: Int32) -> Bool {
        bsdInfo(pid).map { $0.pbi_flags & UInt32(PROC_FLAG_TRACED) != 0 } ?? false
    }

    public static func parentPid(_ pid: Int32) -> Int32? {
        bsdInfo(pid).map { Int32(bitPattern: $0.pbi_ppid) }
    }

    public static func uid(_ pid: Int32) -> uid_t? {
        bsdInfo(pid).map { $0.pbi_uid }
    }

    public static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func allPids() -> [Int32] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        count += 64
        var pids = [Int32](repeating: 0, count: Int(count))
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    public static func childPids(_ pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 512)
        let n = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    /// Cumulative (total, P-cluster) energy in nJ; used to verify PRIO_DARWIN_BG (ADR 0004 § 8).
    public static func energy(_ pid: Int32) -> (total: UInt64, p: UInt64)? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? (ri.ri_energy_nj, ri.ri_penergy_nj) : nil
    }

    /// `kern.bootsessionuuid` (ADR 0004 D3).
    public static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
