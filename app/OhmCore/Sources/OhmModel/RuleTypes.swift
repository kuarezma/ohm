import Foundation

// MARK: - Governor & Effect Types (ADR 0001 § 2, ADR 0003 § 3)

public enum Effect: Int, Sendable, Codable, Comparable, CaseIterable {
    case none = 0
    case eCore = 1
    case freeze = 2

    public static func < (lhs: Effect, rhs: Effect) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum EffectOrigin: Sendable, Hashable, Codable {
    case manual
    case rule(UUID)
    case runaway
    case cli

    enum CodingKeys: String, CodingKey {
        case type, ruleID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "manual":
            self = .manual
        case "runaway":
            self = .runaway
        case "cli":
            self = .cli
        case "rule":
            let id = try container.decode(UUID.self, forKey: .ruleID)
            self = .rule(id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown EffectOrigin type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode("manual", forKey: .type)
        case .runaway:
            try container.encode("runaway", forKey: .type)
        case .cli:
            try container.encode("cli", forKey: .type)
        case .rule(let id):
            try container.encode("rule", forKey: .type)
            try container.encode(id, forKey: .ruleID)
        }
    }
}

public enum FrontmostPolicy: String, Sendable, Codable {
    case release
    case keep
}

public struct FreezeParams: Sendable, Equatable, Hashable, Codable {
    public var minHiddenSeconds: Int

    public init(minHiddenSeconds: Int) {
        self.minHiddenSeconds = minHiddenSeconds
    }
}

public struct ECoreParams: Sendable, Equatable, Hashable, Codable {
    public var whileFrontmost: FrontmostPolicy

    public init(whileFrontmost: FrontmostPolicy) {
        self.whileFrontmost = whileFrontmost
    }
}

public struct DesiredEffect: Sendable, Equatable {
    public var freeze: FreezeParams?
    public var eCore: ECoreParams?
    public var origins: [Effect: Set<EffectOrigin>]

    public init(
        freeze: FreezeParams? = nil,
        eCore: ECoreParams? = nil,
        origins: [Effect: Set<EffectOrigin>] = [:]
    ) {
        self.freeze = freeze
        self.eCore = eCore
        self.origins = origins
    }

    public var highestEffect: Effect {
        if freeze != nil { return .freeze }
        if eCore != nil { return .eCore }
        return .none
    }

    public func effectiveEffect(vetoing: Set<Effect>) -> Effect {
        if freeze != nil && !vetoing.contains(.freeze) { return .freeze }
        if eCore != nil && !vetoing.contains(.eCore) { return .eCore }
        return .none
    }
}

public struct DesiredState: Sendable, Equatable {
    public var effects: [AppKey: DesiredEffect]

    public init(effects: [AppKey: DesiredEffect] = [:]) {
        self.effects = effects
    }
}

// MARK: - Rule Model (ADR 0003 § 1)

public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var source: RuleSource
    public var when: Condition
    public var targets: TargetSelector
    public var actions: [Action]
    public var options: RuleOptions = .init()

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        source: RuleSource,
        when: Condition,
        targets: TargetSelector,
        actions: [Action],
        options: RuleOptions = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.enabled = enabled
        self.source = source
        self.when = when
        self.targets = targets
        self.actions = actions
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, enabled, source, when, targets, actions, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.source = try container.decode(RuleSource.self, forKey: .source)
        self.when = try container.decode(Condition.self, forKey: .when)
        self.targets = try container.decode(TargetSelector.self, forKey: .targets)
        self.actions = try container.decode([Action].self, forKey: .actions)
        self.options = try container.decodeIfPresent(RuleOptions.self, forKey: .options) ?? RuleOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(source, forKey: .source)
        try container.encode(when, forKey: .when)
        try container.encode(targets, forKey: .targets)
        try container.encode(actions, forKey: .actions)
        if options != RuleOptions() {
            try container.encode(options, forKey: .options)
        }
    }
}

public enum RuleSource: Codable, Sendable, Hashable {
    case manual
    case naturalLanguage(text: String)

    enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "manual":
            self = .manual
        case "naturalLanguage":
            let text = try container.decode(String.self, forKey: .text)
            self = .naturalLanguage(text: text)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown RuleSource type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode("manual", forKey: .type)
        case .naturalLanguage(let text):
            try container.encode("naturalLanguage", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

public enum BatteryComparison: String, Codable, Sendable, Hashable {
    case below
    case atOrAbove
}

public struct LocalTime: Codable, Sendable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else {
            return nil
        }
        self.hour = h
        self.minute = m
    }

    public var formattedString: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        guard let time = LocalTime(string: str) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid LocalTime: \(str)")
        }
        self = time
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formattedString)
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        return lhs.minute < rhs.minute
    }
}

public enum Weekday: String, Codable, Sendable, Hashable, CaseIterable {
    case mon, tue, wed, thu, fri, sat, sun
}

public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

public indirect enum Condition: Codable, Sendable, Hashable {
    case always
    case all([Condition])
    case any([Condition])
    case not(Condition)
    case powerSource(PowerSourceKind)
    case batteryPercent(BatteryComparison, value: Int, hysteresis: Int?)
    case thermal(atLeast: ThermalLevel)
    case frontmostApp(AppRef)
    case timeWindow(start: LocalTime, end: LocalTime, weekdays: Set<Weekday>?)
    case focus(isOn: Bool)
    case focusProfile(String)
    case unsupported(raw: JSONValue)

    enum CodingKeys: String, CodingKey {
        case type, of, condition, `is`, op, value, hysteresis, atLeast, app, start, end, weekdays, isOn, profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try? container.decode(String.self, forKey: .type) else {
            let raw = try JSONValue(from: decoder)
            self = .unsupported(raw: raw)
            return
        }

        switch type {
        case "always":
            self = .always
        case "all":
            let of = try container.decode([Condition].self, forKey: .of)
            self = .all(of)
        case "any":
            let of = try container.decode([Condition].self, forKey: .of)
            self = .any(of)
        case "not":
            let cond = try container.decode(Condition.self, forKey: .condition)
            self = .not(cond)
        case "powerSource":
            let kind = try container.decode(PowerSourceKind.self, forKey: .is)
            self = .powerSource(kind)
        case "batteryPercent":
            let op = try container.decode(BatteryComparison.self, forKey: .op)
            let value = try container.decode(Int.self, forKey: .value)
            let hysteresis = try container.decodeIfPresent(Int.self, forKey: .hysteresis)
            self = .batteryPercent(op, value: value, hysteresis: hysteresis)
        case "thermal":
            let levelStr = try container.decode(String.self, forKey: .atLeast)
            let level: ThermalLevel
            switch levelStr {
            case "fair": level = .fair
            case "serious": level = .serious
            case "critical": level = .critical
            case "nominal": level = .nominal
            default:
                throw DecodingError.dataCorruptedError(forKey: .atLeast, in: container, debugDescription: "Unknown thermal level: \(levelStr)")
            }
            self = .thermal(atLeast: level)
        case "frontmostApp":
            let app = try container.decode(AppRef.self, forKey: .app)
            self = .frontmostApp(app)
        case "timeWindow":
            let start = try container.decode(LocalTime.self, forKey: .start)
            let end = try container.decode(LocalTime.self, forKey: .end)
            let weekdaysList = try container.decodeIfPresent([Weekday].self, forKey: .weekdays)
            let weekdays = weekdaysList.map { Set($0) }
            self = .timeWindow(start: start, end: end, weekdays: weekdays)
        case "focus":
            let isOn = try container.decode(Bool.self, forKey: .isOn)
            self = .focus(isOn: isOn)
        case "focusProfile":
            let profile = try container.decode(String.self, forKey: .profile)
            self = .focusProfile(profile)
        default:
            let raw = try JSONValue(from: decoder)
            self = .unsupported(raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .always:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("always", forKey: .type)
        case .all(let of):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("all", forKey: .type)
            try container.encode(of, forKey: .of)
        case .any(let of):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("any", forKey: .type)
            try container.encode(of, forKey: .of)
        case .not(let cond):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("not", forKey: .type)
            try container.encode(cond, forKey: .condition)
        case .powerSource(let kind):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("powerSource", forKey: .type)
            try container.encode(kind.rawValue, forKey: .is)
        case .batteryPercent(let op, let value, let hysteresis):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("batteryPercent", forKey: .type)
            try container.encode(op.rawValue, forKey: .op)
            try container.encode(value, forKey: .value)
            if let hysteresis {
                try container.encode(hysteresis, forKey: .hysteresis)
            }
        case .thermal(let atLeast):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("thermal", forKey: .type)
            let str: String
            switch atLeast {
            case .nominal: str = "nominal"
            case .fair: str = "fair"
            case .serious: str = "serious"
            case .critical: str = "critical"
            }
            try container.encode(str, forKey: .atLeast)
        case .frontmostApp(let app):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("frontmostApp", forKey: .type)
            try container.encode(app, forKey: .app)
        case .timeWindow(let start, let end, let weekdays):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("timeWindow", forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            if let weekdays, !weekdays.isEmpty {
                let sorted = weekdays.sorted { $0.rawValue < $1.rawValue }
                try container.encode(sorted, forKey: .weekdays)
            }
        case .focus(let isOn):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("focus", forKey: .type)
            try container.encode(isOn, forKey: .isOn)
        case .focusProfile(let profile):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("focusProfile", forKey: .type)
            try container.encode(profile, forKey: .profile)
        case .unsupported(let raw):
            try raw.encode(to: encoder)
        }
    }
}

public enum TargetSelector: Codable, Sendable, Hashable {
    case apps([AppRef])
    case runaway
    case allApps(except: [AppRef])

    enum CodingKeys: String, CodingKey {
        case type, apps, except
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "apps":
            let apps = try container.decode([AppRef].self, forKey: .apps)
            self = .apps(apps)
        case "runaway":
            self = .runaway
        case "allApps":
            let except = try container.decodeIfPresent([AppRef].self, forKey: .except) ?? []
            self = .allApps(except: except)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown TargetSelector type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apps(let apps):
            try container.encode("apps", forKey: .type)
            try container.encode(apps, forKey: .apps)
        case .runaway:
            try container.encode("runaway", forKey: .type)
        case .allApps(let except):
            try container.encode("allApps", forKey: .type)
            if !except.isEmpty {
                try container.encode(except, forKey: .except)
            }
        }
    }
}

public struct AppRef: Codable, Sendable, Hashable {
    public var bundleID: String?
    public var executableName: String?
    public var displayName: String

    public init(bundleID: String? = nil, executableName: String? = nil, displayName: String) {
        self.bundleID = bundleID
        self.executableName = executableName
        self.displayName = displayName
    }

    public var appKey: AppKey {
        if let bundleID, !bundleID.isEmpty {
            return AppKey(kind: .bundleID, value: bundleID)
        } else if let executableName, !executableName.isEmpty {
            return AppKey(kind: .executableName, value: executableName)
        } else {
            return AppKey(kind: .processName, value: displayName)
        }
    }
}

public enum Action: Codable, Sendable, Hashable {
    case eCore(whileFrontmost: FrontmostPolicy = .release)
    case freeze(minHiddenSeconds: Int? = nil)
    case notify(message: String? = nil)

    enum CodingKeys: String, CodingKey {
        case type, whileFrontmost, minHiddenSeconds, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "eCore":
            let policy = try container.decodeIfPresent(FrontmostPolicy.self, forKey: .whileFrontmost) ?? .release
            self = .eCore(whileFrontmost: policy)
        case "freeze":
            let seconds = try container.decodeIfPresent(Int.self, forKey: .minHiddenSeconds)
            self = .freeze(minHiddenSeconds: seconds)
        case "notify":
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self = .notify(message: message)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown Action type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .eCore(let whileFrontmost):
            try container.encode("eCore", forKey: .type)
            if whileFrontmost != .release {
                try container.encode(whileFrontmost, forKey: .whileFrontmost)
            } else {
                try container.encode("release", forKey: .whileFrontmost)
            }
        case .freeze(let minHiddenSeconds):
            try container.encode("freeze", forKey: .type)
            if let minHiddenSeconds {
                try container.encode(minHiddenSeconds, forKey: .minHiddenSeconds)
            }
        case .notify(let message):
            try container.encode("notify", forKey: .type)
            if let message {
                try container.encode(message, forKey: .message)
            }
        }
    }
}

public struct RuleOptions: Codable, Sendable, Hashable {
    public var activateAfter: Duration?
    public var deactivateAfter: Duration?
    public var notifyCooldown: Duration = .seconds(1800)

    public init(
        activateAfter: Duration? = nil,
        deactivateAfter: Duration? = nil,
        notifyCooldown: Duration = .seconds(1800)
    ) {
        self.activateAfter = activateAfter
        self.deactivateAfter = deactivateAfter
        self.notifyCooldown = notifyCooldown
    }

    enum CodingKeys: String, CodingKey {
        case activateAfter, deactivateAfter, notifyCooldown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let act = try container.decodeIfPresent(Int.self, forKey: .activateAfter) {
            self.activateAfter = .seconds(act)
        } else {
            self.activateAfter = nil
        }
        if let deact = try container.decodeIfPresent(Int.self, forKey: .deactivateAfter) {
            self.deactivateAfter = .seconds(deact)
        } else {
            self.deactivateAfter = nil
        }
        if let cd = try container.decodeIfPresent(Int.self, forKey: .notifyCooldown) {
            self.notifyCooldown = .seconds(cd)
        } else {
            self.notifyCooldown = .seconds(1800)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let activateAfter {
            try container.encode(Int(activateAfter.components.seconds), forKey: .activateAfter)
        }
        if let deactivateAfter {
            try container.encode(Int(deactivateAfter.components.seconds), forKey: .deactivateAfter)
        }
        if notifyCooldown != .seconds(1800) {
            try container.encode(Int(notifyCooldown.components.seconds), forKey: .notifyCooldown)
        }
    }
}

public struct RulesDocument: Codable, Sendable, Hashable {
    public var schemaVersion: Int = 1
    public var rules: [Rule]

    public init(schemaVersion: Int = 1, rules: [Rule] = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

// MARK: - Evaluation Protocols & Evaluation Context (ADR 0001 § 2, ADR 0003 § 2)

public struct RuleContext: Sendable {
    public var powerSource: PowerSourceKind
    public var batteryPercent: Int
    public var thermalLevel: ThermalLevel
    public var frontmostApp: AppRef?
    public var now: Date
    public var isFocusOn: Bool
    public var activeFocusProfile: String?
    public var runawayApps: [AppRef]
    public var runningApps: [AppRef]

    public init(
        powerSource: PowerSourceKind,
        batteryPercent: Int,
        thermalLevel: ThermalLevel,
        frontmostApp: AppRef? = nil,
        now: Date = Date(),
        isFocusOn: Bool = false,
        activeFocusProfile: String? = nil,
        runawayApps: [AppRef] = [],
        runningApps: [AppRef] = []
    ) {
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.thermalLevel = thermalLevel
        self.frontmostApp = frontmostApp
        self.now = now
        self.isFocusOn = isFocusOn
        self.activeFocusProfile = activeFocusProfile
        self.runawayApps = runawayApps
        self.runningApps = runningApps
    }
}

public struct RuleNotification: Sendable, Equatable, Hashable {
    public var ruleID: UUID
    public var ruleName: String
    public var message: String?
    public var timestamp: Date

    public init(ruleID: UUID, ruleName: String, message: String?, timestamp: Date) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.message = message
        self.timestamp = timestamp
    }
}

public enum RuleRuntimeState: Sendable, Equatable {
    case inactive
    case pendingActive(since: Date, deadline: Date)
    case active
    case pendingInactive(since: Date, deadline: Date)
}

public struct RuleEvaluation: Sendable, Equatable {
    public var desiredState: DesiredState
    public var notifications: [RuleNotification]
    public var nextDeadline: Date?
    public var ruleStates: [UUID: RuleRuntimeState]

    public init(
        desiredState: DesiredState,
        notifications: [RuleNotification] = [],
        nextDeadline: Date? = nil,
        ruleStates: [UUID: RuleRuntimeState] = [:]
    ) {
        self.desiredState = desiredState
        self.notifications = notifications
        self.nextDeadline = nextDeadline
        self.ruleStates = ruleStates
    }
}

public protocol RuleEvaluating: Actor {
    func update(rules: [Rule])
    func evaluate(_ context: RuleContext) -> RuleEvaluation
}

// MARK: - NL / Draft Types (ADR 0001 § 2, ADR 0003 § 4)

public struct Clarification: Sendable, Equatable, Hashable, Codable {
    public var question: String
    public var options: [String]

    public init(question: String, options: [String] = []) {
        self.question = question
        self.options = options
    }
}

public enum RuleDraft: Sendable, Equatable {
    case ready(Rule)
    case needsClarification(Rule, questions: [Clarification])
    case unsupported(phrases: [String])
}
