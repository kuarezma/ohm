import Foundation
import OhmModel

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

public struct ManualContribution: Sendable, Equatable {
    public var eCore: ECoreParams?
    public var freeze: FreezeParams?

    public init(eCore: ECoreParams? = nil, freeze: FreezeParams? = nil) {
        self.eCore = eCore
        self.freeze = freeze
    }
}

private struct LeafKey: Hashable {
    let ruleID: UUID
    let path: String
}

private struct AppContribution {
    enum Kind {
        case freeze(minHiddenSeconds: Int?)
        case eCore(whileFrontmost: FrontmostPolicy)
    }
    let kind: Kind
    let origin: EffectOrigin
}

public actor RuleEngine: RuleEvaluating {
    private var rules: [Rule] = []
    private var ruleStates: [UUID: RuleRuntimeState] = [:]
    private var leafStates: [LeafKey: Bool] = [:]
    private var lastNotifiedAt: [UUID: Date] = [:]
    private var suppressedRules: [AppKey: Set<UUID>] = [:]
    private var manualContributions: [AppKey: ManualContribution] = [:]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    public func update(rules: [Rule]) {
        self.rules = rules
        // Clean up state for removed rules
        let currentIDs = Set(rules.map(\.id))
        ruleStates = ruleStates.filter { currentIDs.contains($0.key) }
        leafStates = leafStates.filter { currentIDs.contains($0.key.ruleID) }
        lastNotifiedAt = lastNotifiedAt.filter { currentIDs.contains($0.key) }
        for (appKey, set) in suppressedRules {
            let filtered = set.intersection(currentIDs)
            if filtered.isEmpty {
                suppressedRules.removeValue(forKey: appKey)
            } else {
                suppressedRules[appKey] = filtered
            }
        }
    }

    public func recordManualOverride(for appKey: AppKey) {
        // Suppress all currently active rules contributing to appKey
        var activeRuleIDs = Set<UUID>()
        for rule in rules where rule.enabled {
            if contributes(ruleStates[rule.id]) {
                activeRuleIDs.insert(rule.id)
            }
        }
        if !activeRuleIDs.isEmpty {
            suppressedRules[appKey, default: []].formUnion(activeRuleIDs)
        }
    }

    public func setManualContribution(
        for appKey: AppKey,
        effect: Effect,
        eCore: ECoreParams? = nil,
        freeze: FreezeParams? = nil
    ) {
        var current = manualContributions[appKey] ?? ManualContribution()
        switch effect {
        case .none:
            manualContributions.removeValue(forKey: appKey)
            return
        case .eCore:
            current.eCore = eCore ?? ECoreParams(whileFrontmost: .release)
        case .freeze:
            current.freeze = freeze ?? FreezeParams(minHiddenSeconds: 0)
        }
        manualContributions[appKey] = current
    }

    public func removeManualContribution(for appKey: AppKey, effect: Effect) {
        guard var current = manualContributions[appKey] else { return }
        switch effect {
        case .eCore:
            current.eCore = nil
        case .freeze:
            current.freeze = nil
        case .none:
            break
        }
        if current.eCore == nil && current.freeze == nil {
            manualContributions.removeValue(forKey: appKey)
        } else {
            manualContributions[appKey] = current
        }
    }

    public func clearManualContributions() {
        manualContributions.removeAll()
    }

    public func getRuleState(id: UUID) -> RuleRuntimeState {
        ruleStates[id] ?? .inactive
    }

    public func reset() {
        ruleStates.removeAll()
        leafStates.removeAll()
        lastNotifiedAt.removeAll()
        suppressedRules.removeAll()
        manualContributions.removeAll()
    }

    public func evaluate(_ context: RuleContext) -> RuleEvaluation {
        var newNotifications: [RuleNotification] = []
        var upcomingDeadlines: [Date] = []

        // Evaluate each rule
        for rule in rules {
            guard rule.enabled else {
                if ruleStates[rule.id] != .inactive {
                    handleBecameInactive(ruleID: rule.id)
                }
                ruleStates[rule.id] = .inactive
                continue
            }

            let (rawMatches, timeDeadline) = evaluateCondition(
                rule.when,
                ruleID: rule.id,
                path: "0",
                context: context
            )
            if let timeDeadline {
                upcomingDeadlines.append(timeDeadline)
            }

            let delays = Self.effectiveDelays(for: rule)
            let activateDelay = delays.activate
            let deactivateDelay = delays.deactivate

            let currentState = ruleStates[rule.id] ?? .inactive
            var becameActive = false
            var becameInactive = false

            switch currentState {
            case .inactive:
                if rawMatches {
                    if activateDelay == .zero {
                        ruleStates[rule.id] = .active
                        becameActive = true
                    } else {
                        let deadline = context.now.addingTimeInterval(activateDelay.timeInterval)
                        ruleStates[rule.id] = .pendingActive(since: context.now, deadline: deadline)
                        upcomingDeadlines.append(deadline)
                    }
                }

            case .pendingActive(_, let deadline):
                if rawMatches {
                    if context.now >= deadline {
                        ruleStates[rule.id] = .active
                        becameActive = true
                    } else {
                        upcomingDeadlines.append(deadline)
                    }
                } else {
                    ruleStates[rule.id] = .inactive
                }

            case .active:
                if !rawMatches {
                    if deactivateDelay == .zero {
                        ruleStates[rule.id] = .inactive
                        becameInactive = true
                    } else {
                        let deadline = context.now.addingTimeInterval(deactivateDelay.timeInterval)
                        ruleStates[rule.id] = .pendingInactive(since: context.now, deadline: deadline)
                        upcomingDeadlines.append(deadline)
                    }
                }

            case .pendingInactive(_, let deadline):
                if !rawMatches {
                    if context.now >= deadline {
                        ruleStates[rule.id] = .inactive
                        becameInactive = true
                    } else {
                        upcomingDeadlines.append(deadline)
                    }
                } else {
                    ruleStates[rule.id] = .active
                }
            }

            if becameInactive {
                handleBecameInactive(ruleID: rule.id)
            }

            if becameActive {
                for action in rule.actions {
                    if case .notify(let message) = action {
                        let last = lastNotifiedAt[rule.id]
                        let cooldown = rule.options.notifyCooldown.timeInterval
                        if last == nil || context.now.timeIntervalSince(last!) >= cooldown {
                            lastNotifiedAt[rule.id] = context.now
                            newNotifications.append(RuleNotification(
                                ruleID: rule.id,
                                ruleName: rule.name,
                                message: message,
                                timestamp: context.now
                            ))
                        }
                    }
                }
            }
        }

        // Sort notifications deterministically by rule id
        newNotifications.sort { $0.ruleID.uuidString < $1.ruleID.uuidString }

        // Collect contributions for active rules
        var contributionsByApp: [AppKey: [AppContribution]] = [:]

        for rule in rules where rule.enabled && contributes(ruleStates[rule.id]) {
            let targetKeys = resolveTargetKeys(rule.targets, context: context)
            for appKey in targetKeys {
                // Check if suppressed by manual override
                if suppressedRules[appKey]?.contains(rule.id) == true {
                    continue
                }

                for action in rule.actions {
                    switch action {
                    case .freeze(let minHiddenSeconds):
                        contributionsByApp[appKey, default: []].append(
                            AppContribution(
                                kind: .freeze(minHiddenSeconds: minHiddenSeconds),
                                origin: .rule(rule.id)
                            )
                        )
                    case .eCore(let whileFrontmost):
                        contributionsByApp[appKey, default: []].append(
                            AppContribution(
                                kind: .eCore(whileFrontmost: whileFrontmost),
                                origin: .rule(rule.id)
                            )
                        )
                    case .notify:
                        break
                    }
                }
            }
        }

        // Add manual contributions
        for (appKey, manual) in manualContributions {
            if let freeze = manual.freeze {
                contributionsByApp[appKey, default: []].append(
                    AppContribution(
                        kind: .freeze(minHiddenSeconds: freeze.minHiddenSeconds),
                        origin: .manual
                    )
                )
            }
            if let eCore = manual.eCore {
                contributionsByApp[appKey, default: []].append(
                    AppContribution(
                        kind: .eCore(whileFrontmost: eCore.whileFrontmost),
                        origin: .manual
                    )
                )
            }
        }

        // Merge contributions deterministically
        var desiredEffects: [AppKey: DesiredEffect] = [:]
        for (appKey, contributions) in contributionsByApp {
            if let merged = Self.merge(contributions: contributions) {
                desiredEffects[appKey] = merged
            }
        }

        // Next deadline calculation: earliest strictly after context.now
        let futureDeadlines = upcomingDeadlines.filter { $0 > context.now }
        let nextDeadline = futureDeadlines.min()

        return RuleEvaluation(
            desiredState: DesiredState(effects: desiredEffects),
            notifications: newNotifications,
            nextDeadline: nextDeadline,
            ruleStates: ruleStates
        )
    }

    private func contributes(_ state: RuleRuntimeState?) -> Bool {
        switch state {
        case .active, .pendingInactive:
            return true
        default:
            return false
        }
    }

    private func handleBecameInactive(ruleID: UUID) {
        // Clear manual override suppression when rule becomes inactive
        for (appKey, var set) in suppressedRules {
            if set.remove(ruleID) != nil {
                if set.isEmpty {
                    suppressedRules.removeValue(forKey: appKey)
                } else {
                    suppressedRules[appKey] = set
                }
            }
        }
    }

    private func resolveTargetKeys(_ targets: TargetSelector, context: RuleContext) -> [AppKey] {
        switch targets {
        case .apps(let apps):
            return apps.map(\.appKey)
        case .runaway:
            return context.runawayApps.map(\.appKey)
        case .allApps(let except):
            let exceptKeys = Set(except.map(\.appKey))
            return context.runningApps.map(\.appKey).filter { !exceptKeys.contains($0) }
        }
    }

    // MARK: - Condition Evaluation & Leaf Hysteresis

    private func evaluateCondition(
        _ condition: Condition,
        ruleID: UUID,
        path: String,
        context: RuleContext
    ) -> (matches: Bool, nextDeadline: Date?) {
        switch condition {
        case .always:
            return (true, nil)

        case .powerSource(let kind):
            return (context.powerSource == kind, nil)

        case .batteryPercent(let op, let value, let hysteresis):
            let h = hysteresis ?? 3
            let key = LeafKey(ruleID: ruleID, path: path)
            let wasActive = leafStates[key] ?? false
            let currentPct = context.batteryPercent

            let isActive: Bool
            switch op {
            case .below:
                // Percent < X turns on, >= X + h turns off
                if wasActive {
                    isActive = (currentPct < value + h)
                } else {
                    isActive = (currentPct < value)
                }
            case .atOrAbove:
                // Percent >= X turns on, < X - h turns off
                if wasActive {
                    isActive = (currentPct >= value - h)
                } else {
                    isActive = (currentPct >= value)
                }
            }
            leafStates[key] = isActive
            return (isActive, nil)

        case .thermal(let atLeast):
            return (context.thermalLevel >= atLeast, nil)

        case .frontmostApp(let appRef):
            guard let frontmost = context.frontmostApp else {
                return (false, nil)
            }
            let matches: Bool
            if let refBundle = appRef.bundleID, let frontBundle = frontmost.bundleID {
                matches = refBundle.caseInsensitiveCompare(frontBundle) == .orderedSame
            } else if let refExec = appRef.executableName, let frontExec = frontmost.executableName {
                matches = refExec.caseInsensitiveCompare(frontExec) == .orderedSame
            } else {
                matches = appRef.displayName.caseInsensitiveCompare(frontmost.displayName) == .orderedSame
            }
            return (matches, nil)

        case .timeWindow(let start, let end, let weekdays):
            return Self.evaluateTimeWindow(start: start, end: end, weekdays: weekdays, now: context.now)

        case .focus(let isOn):
            return (context.isFocusOn == isOn, nil)

        case .focusProfile(let profile):
            return (context.activeFocusProfile == profile, nil)

        case .not(let cond):
            let (m, d) = evaluateCondition(cond, ruleID: ruleID, path: path + ".not", context: context)
            return (!m, d)

        case .all(let conds):
            var allMatch = true
            var deadlines: [Date] = []
            for (idx, cond) in conds.enumerated() {
                let (m, d) = evaluateCondition(cond, ruleID: ruleID, path: "\(path).\(idx)", context: context)
                if !m { allMatch = false }
                if let d { deadlines.append(d) }
            }
            return (allMatch, deadlines.min())

        case .any(let conds):
            var anyMatch = false
            var deadlines: [Date] = []
            for (idx, cond) in conds.enumerated() {
                let (m, d) = evaluateCondition(cond, ruleID: ruleID, path: "\(path).\(idx)", context: context)
                if m { anyMatch = true }
                if let d { deadlines.append(d) }
            }
            return (anyMatch, deadlines.min())

        case .unsupported:
            return (false, nil)
        }
    }

    // MARK: - Time Window Semantics (Midnight-crossing, weekdays)

    public static func evaluateTimeWindow(
        start: LocalTime,
        end: LocalTime,
        weekdays: Set<Weekday>?,
        now: Date,
        calendar: Calendar = Calendar.current
    ) -> (matches: Bool, nextDeadline: Date?) {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        guard let currentHour = comps.hour,
              let currentMinute = comps.minute,
              let currentWdayInt = comps.weekday else {
            return (false, nil)
        }

        let weekdayMap: [Int: Weekday] = [
            1: .sun, 2: .mon, 3: .tue, 4: .wed, 5: .thu, 6: .fri, 7: .sat
        ]
        guard let currentWeekday = weekdayMap[currentWdayInt] else {
            return (false, nil)
        }

        let currentTimeInMinutes = currentHour * 60 + currentMinute
        let startMinutes = start.hour * 60 + start.minute
        let endMinutes = end.hour * 60 + end.minute
        let crossesMidnight = endMinutes <= startMinutes

        let matches: Bool
        if !crossesMidnight {
            let inTime = currentTimeInMinutes >= startMinutes && currentTimeInMinutes < endMinutes
            let inDay = (weekdays == nil || weekdays!.contains(currentWeekday))
            matches = inTime && inDay
        } else {
            // Window crosses midnight (e.g. 22:00 to 07:00)
            if currentTimeInMinutes >= startMinutes {
                // Evening part: weekday is current day
                matches = (weekdays == nil || weekdays!.contains(currentWeekday))
            } else if currentTimeInMinutes < endMinutes {
                // Morning part: weekday is yesterday
                let yesterdayWdayInt = (currentWdayInt == 1) ? 7 : (currentWdayInt - 1)
                let yesterdayWeekday = weekdayMap[yesterdayWdayInt]!
                matches = (weekdays == nil || weekdays!.contains(yesterdayWeekday))
            } else {
                matches = false
            }
        }

        // Calculate upcoming transition deadlines (start or end boundaries)
        var candidateDates: [Date] = []
        let startOfDay = calendar.startOfDay(for: now)
        for dayOffset in -1...2 {
            if let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) {
                if let startDate = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: dayDate), startDate > now {
                    candidateDates.append(startDate)
                }
                if let endDate = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: dayDate), endDate > now {
                    candidateDates.append(endDate)
                }
            }
        }

        return (matches, candidateDates.min())
    }

    // MARK: - Delays and Debounce

    public static func effectiveDelays(for rule: Rule) -> (activate: Duration, deactivate: Duration) {
        let leafDefaults = defaultDelays(for: rule.when)
        let activate = rule.options.activateAfter ?? leafDefaults.activate
        let deactivate = rule.options.deactivateAfter ?? leafDefaults.deactivate
        return (activate, deactivate)
    }

    private static func defaultDelays(for condition: Condition) -> (activate: Duration, deactivate: Duration) {
        switch condition {
        case .powerSource:
            return (.seconds(5), .seconds(5))
        case .batteryPercent:
            return (.zero, .zero)
        case .thermal:
            return (.seconds(10), .seconds(60))
        case .frontmostApp:
            return (.seconds(2), .seconds(2))
        case .timeWindow:
            return (.zero, .zero)
        case .focus, .focusProfile:
            return (.zero, .seconds(5))
        case .always, .unsupported:
            return (.zero, .zero)
        case .not(let c):
            return defaultDelays(for: c)
        case .all(let conds), .any(let conds):
            var maxAct: Duration = .zero
            var maxDeact: Duration = .zero
            for c in conds {
                let d = defaultDelays(for: c)
                if d.activate > maxAct { maxAct = d.activate }
                if d.deactivate > maxDeact { maxDeact = d.deactivate }
            }
            return (maxAct, maxDeact)
        }
    }

    // MARK: - Deterministic Merge

    private static func merge(contributions: [AppContribution]) -> DesiredEffect? {
        if contributions.isEmpty { return nil }

        var freezeContributions: [AppContribution] = []
        var eCoreContributions: [AppContribution] = []

        for c in contributions {
            switch c.kind {
            case .freeze:
                freezeContributions.append(c)
            case .eCore:
                eCoreContributions.append(c)
            }
        }

        var freezeParams: FreezeParams? = nil
        var freezeOrigins = Set<EffectOrigin>()
        if !freezeContributions.isEmpty {
            var ruleSeconds: [Int] = []
            var hasRuleFreeze = false
            for c in freezeContributions {
                freezeOrigins.insert(c.origin)
                if case .freeze(let s) = c.kind {
                    if c.origin != .manual {
                        hasRuleFreeze = true
                        ruleSeconds.append(s ?? 300)
                    }
                }
            }
            let mergedSeconds: Int
            if hasRuleFreeze {
                let maxSec = ruleSeconds.max() ?? 300
                mergedSeconds = max(300, maxSec)
            } else {
                mergedSeconds = 0
            }
            freezeParams = FreezeParams(minHiddenSeconds: mergedSeconds)
        }

        var eCoreParams: ECoreParams? = nil
        var eCoreOrigins = Set<EffectOrigin>()
        if !eCoreContributions.isEmpty {
            var anyRelease = false
            for c in eCoreContributions {
                eCoreOrigins.insert(c.origin)
                if case .eCore(let policy) = c.kind {
                    if policy == .release {
                        anyRelease = true
                    }
                }
            }
            let mergedPolicy: FrontmostPolicy = anyRelease ? .release : .keep
            eCoreParams = ECoreParams(whileFrontmost: mergedPolicy)
        }

        var origins: [Effect: Set<EffectOrigin>] = [:]
        if !freezeOrigins.isEmpty {
            origins[.freeze] = freezeOrigins
        }
        if !eCoreOrigins.isEmpty {
            origins[.eCore] = eCoreOrigins
        }

        return DesiredEffect(
            freeze: freezeParams,
            eCore: eCoreParams,
            origins: origins
        )
    }
}
