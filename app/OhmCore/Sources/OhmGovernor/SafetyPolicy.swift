import CoreAudio
import CoreGraphics
import CoreMediaIO
import Darwin
import Foundation
import IOKit.pwr_mgt
import OhmJournal
import OhmModel

/// System-wide measurements behind the ADR 0004 § 2 dynamic vetoes. Not Sendable; lives in the Governor.
public protocol SafetyProbing: AnyObject {
    /// CoreAudio: pid → process object → IsRunningOutput / IsRunningInput.
    func audioActive(pid: Int32) -> Bool
    /// `kCMIODevicePropertyDeviceIsRunningSomewhere` on any camera (system-wide).
    func cameraInUse() -> Bool
    /// Pids holding any active IOPM assertion (`IOPMCopyAssertionsByProcess`).
    func assertionHolders() -> Set<Int32>
    /// `CGGetEventTapList` → `tappingProcess`.
    func eventTapOwners() -> Set<Int32>
    func isTraced(pid: Int32) -> Bool
    /// Live children of `pid` whose executable is outside `bundlePath` (or unreadable).
    func outOfBundleChildren(pid: Int32, bundlePath: String) -> [Int32]
}

public final class SystemSafetyProbes: SafetyProbing {
    public init() {}

    public func audioActive(pid: Int32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        guard st == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return false }
        for selector in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(object, &a, 0, nil, &sz, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    public func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return false }
        for dev in devices {
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &running) == noErr,
               running != 0 { return true }
        }
        return false
    }

    public func assertionHolders() -> Set<Int32> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out = Set<Int32>()
        for (pid, list) in d {
            // Any assertion counts except released ones (level 0): the safer reading of
            // "uyku veya ekran uykusunu engelleyen herhangi bir iddia".
            let active = list.contains { a in (a["AssertLevel"] as? Int).map { $0 != 0 } ?? true }
            if active { out.insert(pid.int32Value) }
        }
        return out
    }

    public func eventTapOwners() -> Set<Int32> {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        return Set(taps.prefix(Int(count)).map { $0.tappingProcess })
    }

    public func isTraced(pid: Int32) -> Bool { ProcessProbe.isTraced(pid) }

    public func outOfBundleChildren(pid: Int32, bundlePath: String) -> [Int32] {
        let prefix = bundlePrefix(bundlePath)
        return ProcessProbe.childPids(pid).filter { child in
            guard ProcessProbe.startAbs(child) != nil else { return false }   // already gone
            guard let path = ProcessProbe.executablePath(child) else { return true } // unreadable: assume outside
            return !path.hasPrefix(prefix)
        }
    }
}

/// `~/Library/Application Support/Ohm/freeze-health.json` (ADR 0004 § 3): bundle IDs rules must not freeze.
public final class FreezeHealthStore {
    public let path: String
    private var unsafe: Set<String>

    public init(path: String) {
        self.path = path
        if let d = FileManager.default.contents(atPath: path),
           let obj = try? JSONDecoder().decode([String: [String]].self, from: d) {
            unsafe = Set(obj["freezeUnsafe"] ?? [])
        } else {
            unsafe = []
        }
    }

    public static var standardPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Ohm/freeze-health.json"
    }

    public func isUnsafe(_ bundleID: String?) -> Bool { bundleID.map { unsafe.contains($0) } ?? false }
    public var all: Set<String> { unsafe }

    public func mark(_ bundleID: String) { unsafe.insert(bundleID); save() }
    public func unmark(_ bundleID: String) { unsafe.remove(bundleID); save() }

    private func save() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let body = ["freezeUnsafe": unsafe.sorted()]
        if let d = try? JSONEncoder().encode(body) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

/// ADR 0004 § 2: scope gate and dynamic vetoes.
public final class SafetyPolicy {
    let probes: any SafetyProbing
    let config: GovernorConfig
    let health: FreezeHealthStore

    init(probes: any SafetyProbing, config: GovernorConfig, health: FreezeHealthStore) {
        self.probes = probes
        self.config = config
        self.health = health
    }

    /// Static part of the scope gate. Also used at rule registration (ADR 0003) so a target that can
    /// never be frozen is never written into a rule.
    public static func staticScopeVetoes(bundleID: String?, executablePath: String?,
                                         config: GovernorConfig) -> [FreezeVeto] {
        var v: [FreezeVeto] = []
        if let p = executablePath, config.protectedPathPrefixes.contains(where: { p.hasPrefix($0) }) {
            v.append(.systemPath)
        }
        if let b = bundleID {
            if b.hasPrefix("com.apple."), !config.appleAllowlist.contains(b) { v.append(.appleBundle) }
            if b.hasPrefix(config.ownBundlePrefix) { v.append(.ohmItself) }
            if config.userNeverFreeze.contains(b) { v.append(.userNeverList) }
        }
        return v
    }

    /// Scope gate for one running process. `forRule` requires `.regular`; manual freezes of
    /// background processes are allowed only with the extra confirmation (§ 2).
    func scopeVetoes(_ app: RunningAppInfo, forRule: Bool, confirmedBackground: Bool) -> [FreezeVeto] {
        var v = Self.staticScopeVetoes(bundleID: app.bundleID, executablePath: app.executablePath, config: config)
        if app.uid != getuid() { v.append(.otherUser) }
        if config.ownPids.contains(app.pid) || app.pid == getpid() { v.append(.ohmItself) }
        if let exe = app.executablePath, let own = config.ownBundlePath, exe.hasPrefix(own + "/") {
            v.append(.ohmItself)
        }
        if app.activationPolicy != .regular {
            if forRule { v.append(.notRegularApp) } else if !confirmedBackground { v.append(.backgroundNeedsConfirmation) }
        }
        return v
    }

    /// Dynamic vetoes over `pids` (every pid of the tree snapshot, D4).
    func treeVetoes(_ app: RunningAppInfo, pids: [Int32], forRule: Bool) -> [FreezeVeto] {
        var v: [FreezeVeto] = []
        if pids.contains(where: { probes.audioActive(pid: $0) }) { v.append(.audio) }
        if forRule, probes.cameraInUse() { v.append(.camera) }
        let holders = probes.assertionHolders()
        if pids.contains(where: holders.contains) { v.append(.powerAssertion) }
        let taps = probes.eventTapOwners()
        if pids.contains(where: taps.contains) { v.append(.eventTap) }
        if let bundle = app.bundlePath,
           pids.contains(where: { !probes.outOfBundleChildren(pid: $0, bundlePath: bundle).isEmpty }) {
            v.append(.outOfBundleChild)
        }
        if pids.contains(where: { probes.isTraced(pid: $0) }) { v.append(.debugged) }
        if forRule, health.isUnsafe(app.bundleID) { v.append(.unsafeTopology) }
        return v
    }
}
