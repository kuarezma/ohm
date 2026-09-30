import Foundation

public enum RunawayActivationPolicy: Sendable, Equatable {
    case regular, accessory, prohibited
}

/// Live app membership is independent of CPU deltas: an unreadable process is not a dead process.
public struct AppVisibility: Sendable, Equatable {
    public var displayName: String
    public var processes: [ProcessIdentity]
    public var activationPolicy: RunawayActivationPolicy
    public var isFrontmost: Bool
    public var hasVisibleWindows: Bool
    public var isHidden: Bool
    public var isBundled: Bool
    public var executablePaths: [String]

    public init(displayName: String, processes: [ProcessIdentity], activationPolicy: RunawayActivationPolicy,
                isFrontmost: Bool, hasVisibleWindows: Bool, isHidden: Bool, isBundled: Bool,
                executablePaths: [String] = []) {
        self.displayName = displayName
        self.processes = processes
        self.activationPolicy = activationPolicy
        self.isFrontmost = isFrontmost
        self.hasVisibleWindows = hasVisibleWindows
        self.isHidden = isHidden
        self.isBundled = isBundled
        self.executablePaths = executablePaths
    }

    public var isRunawayHidden: Bool {
        !isFrontmost && (!hasVisibleWindows || isHidden || activationPolicy != .regular || !isBundled)
    }

    public var requiresFreezeConfirmation: Bool { activationPolicy != .regular || !isBundled }
}

public struct VisibilitySnapshot: Sendable, Equatable {
    public var apps: [AppKey: AppVisibility]
    public init(apps: [AppKey: AppVisibility]) { self.apps = apps }
}

public struct RunawayConfig: Sendable, Equatable {
    public let startCPU: Double
    public let startDuration: Duration
    public let endCPU: Double
    public let endDuration: Duration
    public let snoozeDuration: Duration
    public var ignoredApps: Set<AppKey>

    public init(startCPU: Double = 0.80, startDuration: Duration = .seconds(600),
                endCPU: Double = 0.30, endDuration: Duration = .seconds(120),
                snoozeDuration: Duration = .seconds(3600), ignoredApps: Set<AppKey> = []) {
        precondition(startCPU.isFinite && endCPU.isFinite && startCPU > endCPU && endCPU >= 0)
        precondition(startDuration > .zero && endDuration > .zero && snoozeDuration >= .zero)
        self.startCPU = startCPU
        self.startDuration = startDuration
        self.endCPU = endCPU
        self.endDuration = endDuration
        self.snoozeDuration = snoozeDuration
        self.ignoredApps = ignoredApps
    }
}

public enum RunawayAction: Sendable, Equatable {
    case eCore
    case freeze(requiresConfirmation: Bool)
    case quit

    public var isDestructive: Bool { self == .quit }
}

/// The runtime must revalidate identities and current safety before applying any response.
public enum RunawayResponse: Sendable, Equatable {
    case commands([GovernorCommand])
    case openCard(AppKey)
    case quit(AppKey, processes: [ProcessIdentity])
}

public struct Runaway: Sendable, Equatable {
    public let app: AppKey
    public let displayName: String
    public let processes: [ProcessIdentity]
    public let averageCPU: Double
    public let hiddenDuration: Duration
    public let actions: [RunawayAction]
    public var pids: [Int32] { processes.map(\.pid).sorted() }

    public init(app: AppKey, displayName: String, processes: [ProcessIdentity], averageCPU: Double,
                hiddenDuration: Duration, requiresFreezeConfirmation: Bool) {
        self.app = app
        self.displayName = displayName
        self.processes = processes
        self.averageCPU = averageCPU
        self.hiddenDuration = hiddenDuration
        self.actions = [.eCore, .freeze(requiresConfirmation: requiresFreezeConfirmation), .quit]
    }

    public func response(to action: RunawayAction) -> RunawayResponse {
        // A regular app's root is supplied first by the visibility provider. Governor owns its tree.
        guard let root = processes.first else { return .openCard(app) }
        switch action {
        case .eCore:
            return .commands([.eCore(pid: root.pid, on: true, origin: .runaway)])
        case .freeze:
            guard actions.contains(.freeze(requiresConfirmation: false)) else { return .openCard(app) }
            return .commands([.freeze(pid: root.pid, origin: .runaway, confirmedBackground: false)])
        case .quit:
            return .quit(app, processes: processes)
        }
    }
}

public enum RunawayEvent: Sendable, Equatable {
    case started(Runaway)
    case ended(AppKey)
}

/// App-side notification adapter; the composition root delivers detector events in order.
@MainActor
public protocol RunawayNotifying: AnyObject {
    func handle(_ events: [RunawayEvent]) async throws
}
