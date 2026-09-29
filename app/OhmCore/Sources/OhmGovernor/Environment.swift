import AppKit
import CoreGraphics
import Darwin
import Foundation
import OhmJournal
import OhmModel

public enum AppActivationPolicy: Sendable, Equatable { case regular, accessory, prohibited }

/// Snapshot of a running process as the Governor needs it. Background processes (no bundle)
/// have `bundleID == nil`, `bundlePath == nil` and `.prohibited`.
public struct RunningAppInfo: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var bundleID: String?
    public var bundlePath: String?
    public var executablePath: String?
    public var activationPolicy: AppActivationPolicy
    public var uid: uid_t

    public var pid: Int32 { identity.pid }

    public init(identity: ProcessIdentity, bundleID: String?, bundlePath: String?, executablePath: String?,
                activationPolicy: AppActivationPolicy, uid: uid_t) {
        self.identity = identity
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.activationPolicy = activationPolicy
        self.uid = uid
    }
}

/// AppKit facts and actions. Not Sendable: the implementation lives inside the Governor actor
/// (ADR 0001 § 3 "actor içinde hapsedilmiş, Sendable olmayan uygulamalar"). Tests pass fakes.
public protocol AppControlling: AnyObject {
    func app(pid: Int32) -> RunningAppInfo?
    func apps(for key: AppKey) -> [RunningAppInfo]
    func isActive(pid: Int32) -> Bool
    func isHidden(pid: Int32) -> Bool
    @discardableResult func hide(pid: Int32) -> Bool
    @discardableResult func unhide(pid: Int32) -> Bool
    /// A layer-0 window of `pid` is on screen (`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`).
    func hasOnScreenWindows(pid: Int32) -> Bool
}

/// Production implementation. `NSRunningApplication` is Sendable and callable off the main thread;
/// its time-varying properties refresh on main run-loop turns (header note), which the app provides.
public final class WorkspaceAppController: AppControlling {
    public init() {}

    public func app(pid: Int32) -> RunningAppInfo? {
        guard let id = ProcessProbe.identity(of: pid) else { return nil }
        let uid = ProcessProbe.uid(pid) ?? getuid()
        guard let ra = NSRunningApplication(processIdentifier: pid) else {
            return RunningAppInfo(identity: id, bundleID: nil, bundlePath: nil,
                                  executablePath: ProcessProbe.executablePath(pid),
                                  activationPolicy: .prohibited, uid: uid)
        }
        return info(ra, id: id, uid: uid)
    }

    public func apps(for key: AppKey) -> [RunningAppInfo] {
        guard key.kind == .bundleID else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: key.value).compactMap { ra in
            let pid = ra.processIdentifier
            guard let id = ProcessProbe.identity(of: pid) else { return nil }
            return info(ra, id: id, uid: ProcessProbe.uid(pid) ?? getuid())
        }
    }

    private func info(_ ra: NSRunningApplication, id: ProcessIdentity, uid: uid_t) -> RunningAppInfo {
        let policy: AppActivationPolicy = switch ra.activationPolicy {
        case .regular: .regular
        case .accessory: .accessory
        default: .prohibited
        }
        return RunningAppInfo(identity: id, bundleID: ra.bundleIdentifier, bundlePath: ra.bundleURL?.path,
                              executablePath: ra.executableURL?.path ?? ProcessProbe.executablePath(id.pid),
                              activationPolicy: policy, uid: uid)
    }

    public func isActive(pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.isActive ?? false }
    public func isHidden(pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
    public func hide(pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.hide() ?? false }
    public func unhide(pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.unhide() ?? false }

    public func hasOnScreenWindows(pid: Int32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return list.contains { w in
            (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0
        }
    }
}
