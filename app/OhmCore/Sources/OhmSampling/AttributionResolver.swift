import COhmSys
import Darwin
import Foundation
import OhmModel

/// Result of resolving a process to the app it is billed to (ADR 0002 § 1).
public struct Attribution: Sendable, Hashable {
    public var key: AppKey
    public var displayName: String
    /// Outermost `.app` bundle path (for the icon); nil for bare executables.
    public var bundlePath: String?
    public var category: AppCategory

    public init(key: AppKey, displayName: String, bundlePath: String?, category: AppCategory) {
        self.key = key
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.category = category
    }
}

/// Fields read from a bundle's Info.plist.
public struct BundleInfo: Sendable, Equatable {
    public var bundleID: String?
    public var executable: String?
    public var displayName: String?

    public init(bundleID: String?, executable: String?, displayName: String?) {
        self.bundleID = bundleID
        self.executable = executable
        self.displayName = displayName
    }
}

/// Seam over the process table and file system so attribution is testable. Not Sendable.
public protocol ProcessMetadataSource: AnyObject {
    func path(of pid: Int32) -> String?
    func name(of pid: Int32) -> String?
    /// nil when the responsibility SPI is unavailable or fails.
    func responsiblePID(of pid: Int32) -> Int32?
    func isAlive(_ pid: Int32) -> Bool
    func bundleInfo(appPath: String) -> BundleInfo?
}

public final class SystemProcessMetadata: ProcessMetadataSource {
    public init() {}

    public func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let n = buf.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func name(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func responsiblePID(of pid: Int32) -> Int32? {
        let r = ohm_responsible_pid(pid)
        return r > 0 ? r : nil
    }

    /// Existence probe without signalling anyone: EPERM still means the process exists.
    public func isAlive(_ pid: Int32) -> Bool {
        var raw = ohm_proc_counters()
        let rc = ohm_proc_read(pid, &raw)
        return rc == 0 || rc == EPERM
    }

    /// Reads Info.plist directly; `Bundle(path:)` would keep every bundle in a process-wide cache.
    public func bundleInfo(appPath: String) -> BundleInfo? {
        let url = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        return BundleInfo(bundleID: plist["CFBundleIdentifier"] as? String,
                          executable: plist["CFBundleExecutable"] as? String,
                          displayName: display?.isEmpty == false ? display : nil)
    }
}

/// pid → `AppKey` per ADR 0002 § 1, cached per `ProcessIdentity` (ADR 0001 § 4). Confined to one
/// isolation domain (the SamplingEngine actor via ProcessEnergySampler).
public final class AttributionResolver {
    private let meta: any ProcessMetadataSource
    private var cache: [ProcessIdentity: Attribution] = [:]
    private var bundles: [String: BundleInfo?] = [:]

    public init(meta: any ProcessMetadataSource = SystemProcessMetadata()) {
        self.meta = meta
    }

    public var cachedCount: Int { cache.count }

    public func resolve(_ identity: ProcessIdentity) -> Attribution {
        if let hit = cache[identity] { return hit }
        let result = attribute(pid: identity.pid)
        cache[identity] = result
        return result
    }

    /// Drops entries of processes that died (called once per tick).
    public func prune(keeping live: Set<ProcessIdentity>) {
        let dead = cache.keys.filter { !live.contains($0) }
        for identity in dead { cache.removeValue(forKey: identity) }
        if bundles.count > 1024 { bundles.removeAll() }  // bounded by installed apps; safety valve only
    }

    // ADR 0002 § 1 algorithm.
    func attribute(pid: Int32) -> Attribution {
        guard let path = meta.path(of: pid) else {
            let name = meta.name(of: pid) ?? "pid \(pid)"
            return Attribution(key: AppKey(kind: .processName, value: name), displayName: name,
                               bundlePath: nil, category: .userApp)
        }
        let own = Self.outermostApp(path)
        let responsible = meta.responsiblePID(of: pid) ?? pid
        if responsible != pid, meta.isAlive(responsible),
           let rPath = meta.path(of: responsible), let rApp = Self.outermostApp(rPath),
           own == rApp || Self.isServiceOrExtension(path) {
            return bundleAttribution(rApp)
        }
        if let own { return bundleAttribution(own) }
        let exe = Self.lastPathComponent(path)
        return Attribution(key: AppKey(kind: .executableName, value: exe), displayName: exe,
                           bundlePath: nil, category: Self.category(path: path, bundleID: nil))
    }

    private func bundleAttribution(_ appPath: String) -> Attribution {
        let info: BundleInfo?
        if let cached = bundles[appPath] {
            info = cached
        } else {
            info = meta.bundleInfo(appPath: appPath)
            bundles[appPath] = info
        }
        let fileName = String(Self.lastPathComponent(appPath).dropLast(4))  // strip ".app"
        let key: AppKey
        if let id = info?.bundleID, !id.isEmpty {
            key = AppKey(kind: .bundleID, value: id)
        } else {
            key = AppKey(kind: .executableName, value: info?.executable ?? fileName)
        }
        return Attribution(key: key, displayName: info?.displayName ?? fileName, bundlePath: appPath,
                           category: Self.category(path: appPath, bundleID: info?.bundleID))
    }

    // MARK: Pure path rules

    /// The first path component ending in ".app" (outermost bundle), or nil.
    static func outermostApp(_ path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    static func isServiceOrExtension(_ path: String) -> Bool {
        path.contains(".xpc/") || path.contains(".appex/")
    }

    static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Safari and friends live in cryptexes; judge them by their logical location.
    static func logicalPath(_ path: String) -> String {
        for prefix in ["/System/Volumes/Preboot/Cryptexes/App", "/System/Volumes/Preboot/Cryptexes/OS",
                       "/System/Cryptexes/App", "/System/Cryptexes/OS"] where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// ADR 0002 § 1 `app.category`: macOS services are system-located or `com.apple.` processes that
    /// are not ordinary apps in an Applications folder.
    static func category(path: String, bundleID: String?) -> AppCategory {
        let p = logicalPath(path)
        if p.hasPrefix("/Applications/") || p.hasPrefix("/System/Applications/") || p.hasPrefix("/usr/local/") {
            return .userApp
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], p.hasPrefix(home + "/Applications/") {
            return .userApp
        }
        let systemRoots = ["/System/", "/usr/", "/Library/Apple/", "/bin/", "/sbin/", "/private/", "/Library/Developer/CommandLineTools/"]
        if systemRoots.contains(where: { p.hasPrefix($0) }) { return .systemService }
        if let bundleID, bundleID.hasPrefix("com.apple.") { return .systemService }
        return .userApp
    }
}
