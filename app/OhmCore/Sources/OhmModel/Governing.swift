import Foundation

// ADR 0001 § 2 (MARK: Governor) and ADR 0004. Value types only; the Governor actor lives in OhmGovernor.

extension AppKey {
    public static func bundle(_ id: String) -> AppKey { AppKey(kind: .bundleID, value: id) }
}

// Effect, FrontmostPolicy, FreezeParams, ECoreParams, DesiredEffect and DesiredState live in RuleTypes.swift.

extension EffectOrigin {
    /// Journal representation (ADR 0004 § 5): "manual" | "rule:<UUID>" | "runaway" | "cli".
    public var journalValue: String {
        switch self {
        case .manual: "manual"
        case .rule(let id): "rule:\(id.uuidString)"
        case .runaway: "runaway"
        case .cli: "cli"
        }
    }

    public var isRule: Bool { if case .rule = self { true } else { false } }

    public var isAutomatic: Bool {
        isRule
    }
}

/// Journal `reason` values (ADR 0004 § 5). `rollback` is used by the § 4 pseudo-code;
/// `protectionLost`, `journalUnwritable` and `frontmost` are additions (see ADR 0004 T-023 notes).
public enum ThawReason: String, Sendable, Codable {
    case activation, ruleEnded, user, maxDuration, quit, powerOff, terminated, verifyFailed, recovery
    case rollback, protectionLost, journalUnwritable, frontmost, userNeverList
}

/// Every reason a freeze can be refused (ADR 0004 § 2 scope gate, dynamic vetoes and § 4 admissible()).
public enum FreezeVeto: String, Sendable, Codable, Hashable, CaseIterable {
    // Scope gate (static part is also checked at rule registration, ADR 0003).
    case notRunning, notRegularApp, otherUser, systemPath, appleBundle, ohmItself
    case backgroundNeedsConfirmation
    // Dynamic vetoes (§ 2 table).
    case frontmost, notHidden, recentlyActive, refreezeGrace
    case audio, camera, powerAssertion, eventTap, outOfBundleChild, debugged, userNeverList, unsavedDocument
    /// A safety probe could not measure (T-024 #7): unknown is never treated as safe.
    case safetyProbeFailed
    // General state.
    case powerOffInProgress, postWakeQuiet, shuttingDown, protectionNotReady, journalUnwritable
    case bootUnverified, recoveryPending
    // Tree (§ 3).
    case unstableTree, unsafeTopology, unverifiedTopology
    // Procedure (§ 4).
    case superseded, notDesired, busy, tableFull
}

public enum ProtectionMode: String, Sendable, Codable { case none, launchAgent, spawnedWatcher }

public enum GovernorCommand: Sendable, Equatable {
    /// Manual / CLI / runaway-card freeze of one running process. `confirmedBackground` is the extra
    /// confirmation ADR 0004 § 2 requires for non-`.regular` processes.
    case freeze(pid: Int32, origin: EffectOrigin, confirmedBackground: Bool)
    /// Thaws the group whose root (or member) is `pid`.
    case thaw(pid: Int32)
    case eCore(pid: Int32, on: Bool, origin: EffectOrigin)
    case thawAll
}

public enum GovernorOutcome: Sendable, Equatable {
    case frozen(group: UUID)
    case vetoed([FreezeVeto])
    /// A freeze started and was rolled back (D10). The reason is the journal thaw reason.
    case rolledBack(ThawReason, detail: String)
    case thawed(groups: Int)
    case eCoreApplied(group: UUID)
    case eCoreRemoved(groups: Int)
    case notFound
}

public struct ReconcileReport: Sendable, Equatable {
    public var outcomes: [AppKey: GovernorOutcome]
    public init(outcomes: [AppKey: GovernorOutcome] = [:]) { self.outcomes = outcomes }
}

public struct ThawReport: Sendable, Equatable {
    public var freezeGroups: Int
    public var eCoreGroups: Int
    public init(freezeGroups: Int = 0, eCoreGroups: Int = 0) {
        self.freezeGroups = freezeGroups
        self.eCoreGroups = eCoreGroups
    }
}

public enum GovernorEvent: Sendable, Equatable {
    case frozen(group: UUID, bundleID: String?, pids: [Int32])
    case thawed(group: UUID, reason: ThawReason)
    case vetoed(bundleID: String?, vetoes: [FreezeVeto])
    case rolledBack(group: UUID, reason: ThawReason)
    case eCoreApplied(group: UUID, bundleID: String?)
    case eCoreRemoved(group: UUID, reason: ThawReason)
    case effectsDisabled(FreezeVeto)
    case protectionChanged(ProtectionMode)
    case freezeUnsafeMarked(bundleID: String)
}

/// Facts from NSWorkspace, delivered by the app's `WorkspaceObserver` (ADR 0001 § 3).
public enum WorkspaceEvent: Sendable, Equatable {
    case activated(pid: Int32)
    case deactivated(pid: Int32)
    case terminated(pid: Int32)
    case willPowerOff
    case willSleep
    case didWake
}

public protocol Governing: Actor {
    func reconcile(_ desired: DesiredState) async -> ReconcileReport
    func perform(_ command: GovernorCommand) async -> GovernorOutcome
    func thawAll(reason: ThawReason) async -> ThawReport
    nonisolated var events: AsyncStream<GovernorEvent> { get }
}
