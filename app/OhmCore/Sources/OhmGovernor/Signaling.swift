import COhmSys
import Darwin
import Foundation
import OhmJournal
import OhmModel

/// The only path through which the Governor touches other processes. Tests wrap the real one to
/// record order or inject identity/verification faults (ADR 0004 tests 7, 17, 23).
public protocol ProcessSignaling: AnyObject {
    func startAbs(_ pid: Int32) -> UInt64?
    /// Returns 0 or errno.
    func send(_ pid: Int32, _ sig: Int32) -> Int32
    /// PRIO_DARWIN_BG on/off. Returns 0 or errno.
    func setBackground(_ pid: Int32, _ on: Bool) -> Int32
    func isStopped(_ pid: Int32) -> Bool
    /// "gone" vs "could not tell" matters for undoing effects (T-024 #1).
    func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus
}

extension ProcessSignaling {
    func matches(_ id: ProcessIdentity) -> Bool { startAbs(id.pid) == id.startAbsTime }
}

public final class DarwinSignaler: ProcessSignaling {
    public init() {}
    public func startAbs(_ pid: Int32) -> UInt64? { ProcessProbe.startAbs(pid) }
    /// pid <= 1 is refused: 0 / -1 would address a process group or every process.
    public func send(_ pid: Int32, _ sig: Int32) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return kill(pid, sig) == 0 ? 0 : errno
    }
    public func setBackground(_ pid: Int32, _ on: Bool) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0 ? 0 : errno
    }
    public func isStopped(_ pid: Int32) -> Bool { ProcessProbe.isStopped(pid) }
    public func identityStatus(_ id: ProcessIdentity) -> ProcessProbe.IdentityStatus { ProcessProbe.identityStatus(id) }
}

/// Swift face of the async-signal-safe C table (ADR 0004 § 7).
public enum ThawTable {
    public static let capacity = Int(OHM_THAW_TABLE_CAPACITY)
    /// The handler re-verifies (pid, start) before SIGCONT (D3, T-024 #6).
    public static func add(_ id: ProcessIdentity) -> Bool { ohm_thaw_table_add(id.pid, id.startAbsTime) == 0 }
    public static func remove(_ pid: Int32) { ohm_thaw_table_remove(pid) }
    public static func contains(_ pid: Int32) -> Bool { ohm_thaw_table_contains(pid) != 0 }
    public static var count: Int { Int(ohm_thaw_table_count()) }
    /// Call once at app launch (first thaw layer, § 7).
    @discardableResult public static func installSignalHandlers() -> Bool { ohm_thaw_table_install_handlers() == 0 }
}

/// Canonical bundle path + "/" so it compares with `proc_pidpath` output (which resolves symlinks,
/// e.g. /var → /private/var).
func bundlePrefix(_ bundlePath: String) -> String {
    // realpath(3), not URL.resolvingSymlinksInPath (which maps /private/var back to /var).
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = realpath(bundlePath, &buf) != nil
        ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : bundlePath
    return resolved.hasSuffix("/") ? resolved : resolved + "/"
}

/// Helpers of an app root (ADR 0004 § 3).
public protocol ProcessTreeEnumerating: AnyObject {
    /// Live processes other than `root` that belong to the app's tree. Never includes `root`.
    func helpers(of root: ProcessIdentity, bundlePath: String?) -> [ProcessIdentity]
}

/// Tree = processes whose responsible pid is the root, or whose parent chain reaches the root, and
/// whose executable lies inside the app bundle. ADR 0004 § 3 names the responsible-pid rule and allows
/// the ppid chain as fallback; the union is used because either signal alone misses real helpers
/// (children spawned by a Terminal-launched app are "responsible" to Terminal).
public final class SystemProcessTree: ProcessTreeEnumerating {
    public init() {}

    public func helpers(of root: ProcessIdentity, bundlePath: String?) -> [ProcessIdentity] {
        guard let bundlePath, !bundlePath.isEmpty else { return [] }
        let prefix = bundlePrefix(bundlePath)
        let myUID = ProcessProbe.uid(root.pid) ?? getuid()
        var parent: [Int32: Int32] = [:]
        let pids = ProcessProbe.allPids()
        for p in pids {
            if let info = ProcessProbe.bsdInfo(p), info.pbi_uid == myUID {
                parent[p] = Int32(bitPattern: info.pbi_ppid)
            }
        }
        func descends(_ p: Int32) -> Bool {
            var cur = p
            for _ in 0..<64 {
                guard let pp = parent[cur], pp > 1 else { return false }
                if pp == root.pid { return true }
                cur = pp
            }
            return false
        }
        var out: [ProcessIdentity] = []
        for p in pids where p != root.pid && parent[p] != nil {
            let related = ohm_gov_responsible_pid(p) == root.pid || descends(p)
            guard related, let path = ProcessProbe.executablePath(p), path.hasPrefix(prefix),
                  let id = ProcessProbe.identity(of: p) else { continue }
            out.append(id)
        }
        return out.sorted { $0.pid < $1.pid }
    }
}
