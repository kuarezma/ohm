import Foundation
import OhmModel

// MARK: - Natural Language Generated Rule Schema (ADR 0003 § 4)

public enum GeneratedFrontmost: String, Codable, Sendable, Equatable {
    case release
    case keep
}

public enum GeneratedAction: String, Codable, Sendable, Equatable {
    case eCore
    case freeze
    case notify
}

public enum GeneratedMatch: String, Codable, Sendable, Equatable {
    case all
    case any
}

public enum GeneratedThermal: String, Codable, Sendable, Equatable {
    case fair
    case serious
    case critical
}

public enum GeneratedWeekday: String, Codable, Sendable, Equatable {
    case mon, tue, wed, thu, fri, sat, sun
}

public enum GeneratedConditionKind: String, Codable, Sendable, Equatable {
    case onBattery
    case onAC
    case batteryBelow
    case batteryAtOrAbove
    case thermalAtLeast
    case frontmostIs
    case frontmostIsNot
    case timeBetween
    case focusOn
    case focusOff
    case focusProfile
}

public struct GeneratedCondition: Codable, Sendable, Equatable {
    public var kind: GeneratedConditionKind
    public var percent: Int?
    public var thermal: GeneratedThermal?
    public var appName: String?
    public var start: String?
    public var end: String?
    public var weekdays: [GeneratedWeekday]?
    public var focusProfile: String?

    public init(
        kind: GeneratedConditionKind,
        percent: Int? = nil,
        thermal: GeneratedThermal? = nil,
        appName: String? = nil,
        start: String? = nil,
        end: String? = nil,
        weekdays: [GeneratedWeekday]? = nil,
        focusProfile: String? = nil
    ) {
        self.kind = kind
        self.percent = percent
        self.thermal = thermal
        self.appName = appName
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.focusProfile = focusProfile
    }
}

public struct GeneratedRule: Codable, Sendable, Equatable {
    public var name: String
    public var targetApps: [String]
    public var targetRunaway: Bool
    public var actions: [GeneratedAction]
    public var match: GeneratedMatch
    public var conditions: [GeneratedCondition]
    public var freezeAfterMinutes: Int?
    public var whileFrontmost: GeneratedFrontmost?
    public var unsupported: [String]

    public init(
        name: String,
        targetApps: [String] = [],
        targetRunaway: Bool = false,
        actions: [GeneratedAction],
        match: GeneratedMatch,
        conditions: [GeneratedCondition],
        freezeAfterMinutes: Int? = nil,
        whileFrontmost: GeneratedFrontmost? = nil,
        unsupported: [String] = []
    ) {
        self.name = name
        self.targetApps = targetApps
        self.targetRunaway = targetRunaway
        self.actions = actions
        self.match = match
        self.conditions = conditions
        self.freezeAfterMinutes = freezeAfterMinutes
        self.whileFrontmost = whileFrontmost
        self.unsupported = unsupported
    }
}
