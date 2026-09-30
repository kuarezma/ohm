import AppKit
import CoreGraphics
import OhmJournal
import OhmModel

struct WorkspaceApplication: Sendable {
    let key: AppKey
    let identity: ProcessIdentity
    let name: String
    let policy: RunawayActivationPolicy
    let hidden: Bool
    let frontmost: Bool
    let executablePath: String?
}

enum RuntimeWorkspaceEvent: Sendable {
    case applications([WorkspaceApplication])
    case governor(WorkspaceEvent)
    case cadence(SamplingCadence)
}

/// AppKit facts cross into the runtime as values; observers belong to the app lifetime.
@MainActor
final class WorkspaceBridge {
    let events: AsyncStream<RuntimeWorkspaceEvent>
    private let continuation: AsyncStream<RuntimeWorkspaceEvent>.Continuation
    private var observers: [NSObjectProtocol] = []
    private var systemAsleep = false
    private var screenAsleep = false
    private var interactive = false

    init() {
        (events, continuation) = AsyncStream.makeStream()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.willPowerOffNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { self?.receive(name: name, pid: pid) }
            })
        }
        publishApplications()
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        continuation.finish()
    }

    func setInteractive(_ value: Bool) {
        interactive = value
        publishCadence()
        if value { publishApplications() }
    }

    private func publishCadence() {
        continuation.yield(.cadence(systemAsleep || screenAsleep ? .suspended : interactive ? .interactive : .ambient))
    }

    private func receive(name: Notification.Name, pid: Int32?) {
        switch name {
        case NSWorkspace.didActivateApplicationNotification:
            if let pid { continuation.yield(.governor(.activated(pid: pid))) }
        case NSWorkspace.didDeactivateApplicationNotification:
            if let pid { continuation.yield(.governor(.deactivated(pid: pid))) }
        case NSWorkspace.didTerminateApplicationNotification:
            if let pid { continuation.yield(.governor(.terminated(pid: pid))) }
        case NSWorkspace.willPowerOffNotification: continuation.yield(.governor(.willPowerOff))
        case NSWorkspace.willSleepNotification:
            systemAsleep = true
            continuation.yield(.governor(.willSleep))
            publishCadence()
        case NSWorkspace.didWakeNotification:
            systemAsleep = false
            continuation.yield(.governor(.didWake))
            publishCadence()
        case NSWorkspace.screensDidSleepNotification:
            screenAsleep = true
            publishCadence()
        case NSWorkspace.screensDidWakeNotification:
            screenAsleep = false
            publishCadence()
        default: break
        }
        publishApplications()
    }

    private func publishApplications() {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> WorkspaceApplication? in
            guard let bundleID = app.bundleIdentifier,
                  let identity = ProcessProbe.identity(of: app.processIdentifier) else { return nil }
            let policy: RunawayActivationPolicy = switch app.activationPolicy {
            case .regular: .regular
            case .accessory: .accessory
            default: .prohibited
            }
            return WorkspaceApplication(key: .bundle(bundleID), identity: identity,
                                        name: app.localizedName ?? bundleID, policy: policy,
                                        hidden: app.isHidden, frontmost: app.isActive,
                                        executablePath: app.executableURL?.path)
        }
        continuation.yield(.applications(applications))
    }

    nonisolated static func visibleWindowPids() -> Set<Int32>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return Set(windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return window[kCGWindowOwnerPID as String] as? Int32
        })
    }

    /// Pure mapping: roots precede attributed helpers. Missing window facts are conservative.
    nonisolated static func visibility(applications: [WorkspaceApplication], processes: [ProcessDelta],
                                      previous: VisibilitySnapshot, live: Set<ProcessIdentity>,
                                      visiblePids: Set<Int32>?) -> VisibilitySnapshot {
        let roots = Dictionary(grouping: applications, by: \.key)
        let deltas = Dictionary(grouping: processes, by: \.app)
        let keys = Set(roots.keys).union(deltas.keys).union(previous.apps.keys)
        var apps: [AppKey: AppVisibility] = [:]
        for key in keys {
            let rootApps = (roots[key] ?? []).filter { live.contains($0.identity) }
                .sorted { ($0.policy == .regular ? 0 : 1, $0.identity.pid) < ($1.policy == .regular ? 0 : 1, $1.identity.pid) }
            let samples = deltas[key] ?? []
            let rootIdentities = rootApps.map(\.identity)
            let members = Set(samples.map(\.identity) + (previous.apps[key]?.processes ?? [])).intersection(live)
            let helpers = members.subtracting(rootIdentities).sorted { $0.pid < $1.pid }
            let identities = rootIdentities + helpers
            guard !identities.isEmpty else { continue }
            let old = previous.apps[key]
            apps[key] = AppVisibility(
                displayName: rootApps.first?.name ?? samples.first?.displayName ?? old?.displayName ?? key.value,
                processes: identities, activationPolicy: rootApps.first?.policy ?? .prohibited,
                isFrontmost: rootApps.contains(where: \.frontmost),
                hasVisibleWindows: visiblePids.map { !Set(identities.map(\.pid)).isDisjoint(with: $0) } ?? true,
                isHidden: !rootApps.isEmpty && rootApps.allSatisfy(\.hidden),
                isBundled: !rootApps.isEmpty,
                executablePaths: rootApps.compactMap(\.executablePath))
        }
        return VisibilitySnapshot(apps: apps)
    }
}
