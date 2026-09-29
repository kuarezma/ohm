import Foundation
import OhmModel

public protocol AppResolving: Sendable {
    func resolve(appName: String) -> [AppRef]
}

public struct DefaultAppResolver: AppResolving, Sendable {
    public static let standardApps: [String: (bundleID: String, displayName: String)] = [
        "chrome": ("com.google.Chrome", "Google Chrome"),
        "google chrome": ("com.google.Chrome", "Google Chrome"),
        "slack": ("com.tinyspeck.slackmacgap", "Slack"),
        "docker": ("com.docker.docker", "Docker"),
        "discord": ("com.hnc.Discord", "Discord"),
        "dropbox": ("com.getdropbox.dropbox", "Dropbox"),
        "xcode": ("com.apple.dt.Xcode", "Xcode"),
        "safari": ("com.apple.Safari", "Safari"),
        "preview": ("com.apple.Preview", "Preview")
    ]

    public var customMappings: [String: [AppRef]]

    public init(customMappings: [String: [AppRef]] = [:]) {
        self.customMappings = customMappings
    }

    public func resolve(appName: String) -> [AppRef] {
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let custom = customMappings[key] {
            return custom
        }
        if let match = Self.standardApps[key] {
            return [AppRef(bundleID: match.bundleID, displayName: match.displayName)]
        }
        let prefixMatches = Self.standardApps.filter {
            $0.key.hasPrefix(key) || $0.value.displayName.lowercased().hasPrefix(key)
        }
        if prefixMatches.count == 1, let match = prefixMatches.first?.value {
            return [AppRef(bundleID: match.bundleID, displayName: match.displayName)]
        } else if prefixMatches.count > 1 {
            return prefixMatches.values.map { AppRef(bundleID: $0.bundleID, displayName: $0.displayName) }
        }
        return [AppRef(bundleID: nil, displayName: appName)]
    }
}

public struct RuleCompiler: Sendable {
    public let appResolver: any AppResolving

    public init(appResolver: any AppResolving = DefaultAppResolver()) {
        self.appResolver = appResolver
    }

    public func compile(
        generated: GeneratedRule,
        rawSentence: String? = nil,
        id: UUID = UUID()
    ) -> RuleDraft {
        // 0. Check unsupported items from model
        var unsupportedPhrases = generated.unsupported

        // Compiler-side protection: freezeAfterMinutes
        if let minutes = generated.freezeAfterMinutes {
            if minutes < 5 || minutes > 240 {
                unsupportedPhrases.append("Dondurma süresi 5–240 dakika arasında olmalıdır (verilen: \(minutes))")
            }
            if !generated.actions.contains(.freeze) {
                unsupportedPhrases.append("Dondurma süresi 'freeze' eylemi olmadan verilemez")
            }
        }

        // Compiler-side protection: unhandled duration expressions in rawSentence
        if let sentence = rawSentence {
            let durationRegex = try? NSRegularExpression(
                pattern: #"(\d+)\s*(dk|dakika|sa|saat|min|minute|minutes|hour|hours)\b"#,
                options: [.caseInsensitive]
            )
            let nsRange = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
            if let matches = durationRegex?.matches(in: sentence, range: nsRange) {
                for match in matches {
                    guard let numRange = Range(match.range(at: 1), in: sentence),
                          let unitRange = Range(match.range(at: 2), in: sentence),
                          let fullRange = Range(match.range(at: 0), in: sentence),
                          let num = Int(sentence[numRange]) else { continue }
                    let unit = sentence[unitRange].lowercased()
                    let fullText = String(sentence[fullRange])

                    let minutes: Int
                    if unit.hasPrefix("sa") || unit.hasPrefix("hour") {
                        minutes = num * 60
                    } else {
                        minutes = num
                    }

                    // Check if accounted for by freezeAfterMinutes or timeBetween
                    let matchesFreeze = (generated.freezeAfterMinutes == minutes)
                    let hasTimeBetween = generated.conditions.contains { $0.kind == .timeBetween }

                    if !matchesFreeze && !hasTimeBetween {
                        unsupportedPhrases.append(fullText)
                    }
                }
            }
        }

        if !unsupportedPhrases.isEmpty {
            return .unsupported(phrases: unsupportedPhrases)
        }

        // Target validation & resolution
        if generated.targetApps.isEmpty && !generated.targetRunaway {
            return .unsupported(phrases: ["Hedef uygulama veya kaçak süreç belirtilmelidir"])
        }

        var clarifications: [Clarification] = []
        var resolvedApps: [AppRef] = []
        if !generated.targetRunaway {
            for appName in generated.targetApps {
                let candidates = appResolver.resolve(appName: appName)
                if candidates.count == 1 {
                    resolvedApps.append(candidates[0])
                } else if candidates.isEmpty {
                    clarifications.append(Clarification(
                        question: "'\(appName)' uygulaması bulunamadı. Lütfen hedef uygulamayı seçin.",
                        options: []
                    ))
                    resolvedApps.append(AppRef(displayName: appName))
                } else {
                    clarifications.append(Clarification(
                        question: "'\(appName)' için birden çok aday bulundu. Hangisi seçilsin?",
                        options: candidates.map(\.displayName)
                    ))
                    resolvedApps.append(candidates[0])
                }
            }
        }

        let targetSelector: TargetSelector
        if generated.targetRunaway {
            targetSelector = .runaway
        } else {
            targetSelector = .apps(resolvedApps)
        }

        // Actions translation
        let actions: [Action] = generated.actions.map { act in
            switch act {
            case .eCore:
                let policy: FrontmostPolicy = (generated.whileFrontmost == .keep) ? .keep : .release
                return .eCore(whileFrontmost: policy)
            case .freeze:
                let seconds = generated.freezeAfterMinutes.map { $0 * 60 }
                return .freeze(minHiddenSeconds: seconds)
            case .notify:
                return .notify(message: nil)
            }
        }

        // Conditions & Battery Normalization AST transform
        let hasBatteryBelow = generated.conditions.contains { $0.kind == .batteryBelow }
        let hasOnBattery = generated.conditions.contains { $0.kind == .onBattery }
        let hasOnAC = generated.conditions.contains { $0.kind == .onAC }

        // Test 4: Ambiguity when match == .any and both batteryBelow and onAC are present
        if generated.match == .any && hasBatteryBelow && hasOnAC {
            clarifications.append(Clarification(
                question: "Pil eşiği yalnız pildeyken mi geçerli olsun?",
                options: ["Yalnız pildeyken", "Her zaman"]
            ))
            let baseWhen = Condition.any(generated.conditions.map { convertCondition($0) })
            let rule = Rule(
                schemaVersion: 1,
                id: id,
                name: generated.name,
                enabled: false,
                source: .naturalLanguage(text: rawSentence ?? generated.name),
                when: baseWhen,
                targets: targetSelector,
                actions: actions,
                options: RuleOptions()
            )
            return .needsClarification(rule, questions: clarifications)
        }

        let when: Condition
        if hasBatteryBelow && !hasOnBattery && !hasOnAC {
            // Apply normalization
            if generated.match == .all {
                let convertedLeaves = generated.conditions.map { convertCondition($0) }
                when = .all([.powerSource(.battery)] + convertedLeaves)
            } else {
                // match == .any: wrap each batteryBelow leaf in all(b, powerSource(battery))
                let convertedLeaves = generated.conditions.map { cond -> Condition in
                    let converted = convertCondition(cond)
                    if cond.kind == .batteryBelow {
                        return .all([converted, .powerSource(.battery)])
                    } else {
                        return converted
                    }
                }
                when = .any(convertedLeaves)
            }
        } else {
            // No normalization needed
            if generated.conditions.count == 1 {
                when = convertCondition(generated.conditions[0])
            } else if generated.match == .all {
                when = .all(generated.conditions.map { convertCondition($0) })
            } else {
                when = .any(generated.conditions.map { convertCondition($0) })
            }
        }

        let rule = Rule(
            schemaVersion: 1,
            id: id,
            name: generated.name,
            enabled: false, // NL rules default to false per ADR 0003 § 4
            source: .naturalLanguage(text: rawSentence ?? generated.name),
            when: when,
            targets: targetSelector,
            actions: actions,
            options: RuleOptions()
        )

        if !clarifications.isEmpty {
            return .needsClarification(rule, questions: clarifications)
        }
        return .ready(rule)
    }

    private func convertCondition(_ gen: GeneratedCondition) -> Condition {
        switch gen.kind {
        case .onBattery:
            return .powerSource(.battery)
        case .onAC:
            return .powerSource(.ac)
        case .batteryBelow:
            return .batteryPercent(.below, value: gen.percent ?? 0, hysteresis: nil)
        case .batteryAtOrAbove:
            return .batteryPercent(.atOrAbove, value: gen.percent ?? 0, hysteresis: nil)
        case .thermalAtLeast:
            let level: ThermalLevel
            switch gen.thermal ?? .serious {
            case .fair: level = .fair
            case .serious: level = .serious
            case .critical: level = .critical
            }
            return .thermal(atLeast: level)
        case .frontmostIs:
            let app = appResolver.resolve(appName: gen.appName ?? "").first ?? AppRef(displayName: gen.appName ?? "")
            return .frontmostApp(app)
        case .frontmostIsNot:
            let app = appResolver.resolve(appName: gen.appName ?? "").first ?? AppRef(displayName: gen.appName ?? "")
            return .not(.frontmostApp(app))
        case .timeBetween:
            let start = LocalTime(string: gen.start ?? "00:00") ?? LocalTime(hour: 0, minute: 0)
            let end = LocalTime(string: gen.end ?? "00:00") ?? LocalTime(hour: 0, minute: 0)
            let weekdays = gen.weekdays.map { Set($0.compactMap { Weekday(rawValue: $0.rawValue) }) }
            return .timeWindow(start: start, end: end, weekdays: weekdays)
        case .focusOn:
            return .focus(isOn: true)
        case .focusOff:
            return .focus(isOn: false)
        case .focusProfile:
            return .focusProfile(gen.focusProfile ?? "")
        }
    }
}
