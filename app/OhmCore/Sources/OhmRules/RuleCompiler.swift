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
    private let applicationInventory: [AppRef]

    public init(customMappings: [String: [AppRef]] = [:]) {
        self.init(customMappings: customMappings, applicationInventory: Self.installedApplications())
    }

    // A snapshot makes resolution deterministic and avoids rescanning for each name.
    init(customMappings: [String: [AppRef]] = [:], applicationInventory: [AppRef]) {
        self.customMappings = customMappings
        self.applicationInventory = applicationInventory
    }

    public func resolve(appName: String) -> [AppRef] {
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        if let custom = customMappings[key] { return custom }

        // The alias table is only a search hint; identity must come from a real bundle.
        let exact = applicationInventory.filter {
            $0.displayName.lowercased() == key
        }
        if !exact.isEmpty { return exact }
        return applicationInventory.filter {
            $0.bundleID == Self.standardApps[key]?.bundleID ||
                $0.displayName.lowercased().split(separator: " ").contains { $0.hasPrefix(key) }
        }
    }

    private static func installedApplications() -> [AppRef] {
        let fileManager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/System/Applications")]
        var appsByIdentity: [String: AppRef] = [:]
        for root in roots {
            guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                appsByIdentity[bundleID] = AppRef(bundleID: bundleID, displayName: name)
            }
        }
        return appsByIdentity.values.sorted { ($0.bundleID ?? "") < ($1.bundleID ?? "") }
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
        func resolveApp(_ appName: String) -> AppRef {
            let candidates = appResolver.resolve(appName: appName)
            if candidates.count == 1, let app = candidates.first,
               [app.bundleID, app.executableName].contains(where: {
                   !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
               }) {
                return app
            }
            let ambiguous = candidates.count > 1
            clarifications.append(Clarification(
                question: ambiguous
                    ? "'\(appName)' için birden çok aday bulundu. Hangisi seçilsin?"
                    : "'\(appName)' uygulaması bulunamadı. Lütfen uygulamayı seçin.",
                options: ambiguous ? candidates.map(\.displayName) : []
            ))
            // No candidate is selected until the user resolves the question.
            return AppRef(displayName: appName)
        }

        let resolvedApps = generated.targetRunaway ? [] : generated.targetApps.map(resolveApp)
        let convertedConditions: [Condition]
        do {
            convertedConditions = try generated.conditions.map { try convertCondition($0, resolveApp: resolveApp) }
        } catch {
            return .unsupported(phrases: [String(describing: error)])
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
            let baseWhen = Condition.any(convertedConditions)
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
            do { try RuleValidator.validate(rule: rule) }
            catch { return .unsupported(phrases: [String(describing: error)]) }
            return .needsClarification(rule, questions: clarifications)
        }

        let when: Condition
        if hasBatteryBelow && !hasOnBattery && !hasOnAC {
            // Apply normalization
            if generated.match == .all {
                let convertedLeaves = convertedConditions
                when = .all([.powerSource(.battery)] + convertedLeaves)
            } else {
                // match == .any: wrap each batteryBelow leaf in all(b, powerSource(battery))
                let convertedLeaves = zip(generated.conditions, convertedConditions).map { cond, converted -> Condition in
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
                when = convertedConditions[0]
            } else if generated.match == .all {
                when = .all(convertedConditions)
            } else {
                when = .any(convertedConditions)
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

        do { try RuleValidator.validate(rule: rule) }
        catch { return .unsupported(phrases: [String(describing: error)]) }

        if !clarifications.isEmpty {
            return .needsClarification(rule, questions: clarifications)
        }
        return .ready(rule)
    }

    private func convertCondition(_ gen: GeneratedCondition, resolveApp: (String) -> AppRef) throws -> Condition {
        switch gen.kind {
        case .onBattery:
            return .powerSource(.battery)
        case .onAC:
            return .powerSource(.ac)
        case .batteryBelow:
            guard let percent = gen.percent else { throw RuleValidationError("Pil yüzdesi belirtilmelidir") }
            return .batteryPercent(.below, value: percent, hysteresis: nil)
        case .batteryAtOrAbove:
            guard let percent = gen.percent else { throw RuleValidationError("Pil yüzdesi belirtilmelidir") }
            return .batteryPercent(.atOrAbove, value: percent, hysteresis: nil)
        case .thermalAtLeast:
            let level: ThermalLevel
            guard let thermal = gen.thermal else { throw RuleValidationError("Termal seviye belirtilmelidir") }
            switch thermal {
            case .fair: level = .fair
            case .serious: level = .serious
            case .critical: level = .critical
            }
            return .thermal(atLeast: level)
        case .frontmostIs:
            guard let name = gen.appName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuleValidationError("Ön plan koşulunda uygulama adı belirtilmelidir")
            }
            let app = resolveApp(name)
            return .frontmostApp(app)
        case .frontmostIsNot:
            guard let name = gen.appName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuleValidationError("Ön plan koşulunda uygulama adı belirtilmelidir")
            }
            let app = resolveApp(name)
            return .not(.frontmostApp(app))
        case .timeBetween:
            guard let startText = gen.start, let endText = gen.end,
                  startText.count == 5, endText.count == 5,
                  let start = LocalTime(string: startText), let end = LocalTime(string: endText),
                  start.formattedString == startText, end.formattedString == endText else {
                throw RuleValidationError("Saat aralığının başlangıcı ve bitişi HH:mm biçiminde belirtilmelidir")
            }
            let weekdays = gen.weekdays.map { Set($0.compactMap { Weekday(rawValue: $0.rawValue) }) }
            return .timeWindow(start: start, end: end, weekdays: weekdays)
        case .focusOn:
            return .focus(isOn: true)
        case .focusOff:
            return .focus(isOn: false)
        case .focusProfile:
            guard let profile = gen.focusProfile else { throw RuleValidationError("Focus profil adı belirtilmelidir") }
            return .focusProfile(profile)
        }
    }
}
