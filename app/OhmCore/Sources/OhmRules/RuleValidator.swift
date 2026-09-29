import Foundation
import OhmModel

public struct RuleValidationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum RuleValidator {
    public static let maxTreeDepth = 3
    public static let maxLeafConditions = 8
    public static let maxTargetApps = 10
    public static let maxRulesCount = 50

    public static let defaultNeverFreezePrefixes = ["com.apple.", "dev.ohm."]
    public static let defaultAllowedAppleBundleIDs = ["com.apple.Safari", "com.apple.Preview"]

    public static func validate(
        rule: Rule,
        neverFreezeBundleIDs: Set<String> = []
    ) throws {
        // Target apps count (1...10)
        if case .apps(let apps) = rule.targets {
            if apps.count > maxTargetApps {
                throw RuleValidationError("Hedef uygulama sayısı en fazla \(maxTargetApps) olabilir (verilen: \(apps.count))")
            }
        }

        // Tree depth <= 3
        let depth = conditionDepth(rule.when)
        if depth > maxTreeDepth {
            throw RuleValidationError("Koşul ağacı derinliği en fazla \(maxTreeDepth) olabilir (verilen: \(depth))")
        }

        // Leaf condition count <= 8
        let leafCount = countLeaves(rule.when)
        if leafCount > maxLeafConditions {
            throw RuleValidationError("Yaprak koşul sayısı en fazla \(maxLeafConditions) olabilir (verilen: \(leafCount))")
        }

        // Freeze restrictions
        let hasFreeze = rule.actions.contains { action in
            if case .freeze = action { return true }
            return false
        }

        if hasFreeze {
            switch rule.targets {
            case .allApps:
                throw RuleValidationError("freeze eylemi 'allApps' hedefiyle kullanılamaz")
            case .runaway:
                throw RuleValidationError("freeze eylemi 'runaway' hedefiyle kullanılamaz; kaçak süreçler yalnız kullanıcı onayıyla dondurulur")
            case .apps(let apps):
                for app in apps {
                    if let bundleID = app.bundleID {
                        if neverFreezeBundleIDs.contains(bundleID) {
                            throw RuleValidationError("'\(app.displayName)' (\(bundleID)) asla dondurma listesinde yer alıyor")
                        }
                        if bundleID.hasPrefix("dev.ohm.") {
                            throw RuleValidationError("Ohm bileşenleri dondurulamaz: \(bundleID)")
                        }
                        if bundleID.hasPrefix("com.apple.") && !defaultAllowedAppleBundleIDs.contains(bundleID) {
                            throw RuleValidationError("Apple sistem uygulamaları dondurulamaz: \(bundleID)")
                        }
                    } else if app.executableName != nil {
                        throw RuleValidationError("Paketsiz süreçler ('\(app.displayName)') kurallarla dondurulamaz; yalnız elle dondurulabilir")
                    }
                }
            }
        }

        // Unsupported condition
        if hasUnsupportedCondition(rule.when) && rule.enabled {
            throw RuleValidationError("Desteklenmeyen koşul içeren kural devre dışı yüklenmelidir (enabled = false olmalı)")
        }
    }

    public static func validate(rules: [Rule], neverFreezeBundleIDs: Set<String> = []) throws {
        if rules.count > maxRulesCount {
            throw RuleValidationError("Toplam kural sayısı en fazla \(maxRulesCount) olabilir (verilen: \(rules.count))")
        }
        for rule in rules {
            try validate(rule: rule, neverFreezeBundleIDs: neverFreezeBundleIDs)
        }
    }

    public static func conditionDepth(_ condition: Condition) -> Int {
        switch condition {
        case .all(let conds), .any(let conds):
            return 1 + (conds.map { conditionDepth($0) }.max() ?? 0)
        case .not(let cond):
            return 1 + conditionDepth(cond)
        default:
            return 1
        }
    }

    public static func countLeaves(_ condition: Condition) -> Int {
        switch condition {
        case .all(let conds), .any(let conds):
            return conds.reduce(0) { $0 + countLeaves($1) }
        case .not(let cond):
            return countLeaves(cond)
        default:
            return 1
        }
    }

    public static func hasUnsupportedCondition(_ condition: Condition) -> Bool {
        switch condition {
        case .unsupported:
            return true
        case .all(let conds), .any(let conds):
            return conds.contains { hasUnsupportedCondition($0) }
        case .not(let cond):
            return hasUnsupportedCondition(cond)
        default:
            return false
        }
    }
}
