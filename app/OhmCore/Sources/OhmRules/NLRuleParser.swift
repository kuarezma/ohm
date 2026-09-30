import Foundation
import FoundationModels
import OhmModel

// MARK: - Natural Language Parser Availability

public enum NLParserAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unsupportedLocale(Locale)
        case other(String)
    }
}

// MARK: - Natural Language Parser Errors

public enum NLRuleParserError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(NLParserAvailability.Reason)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Doğal dil kural ayrıştırıcısı kullanılamıyor: \(reason)"
        case .generationFailed(let message):
            return "Kural üretimi başarısız oldu: \(message)"
        }
    }
}

// MARK: - Generable DTO Schema (ADR 0003 § 4)

@Generable enum GeneratedFrontmostDTO { case release, keep }
@Generable enum GeneratedActionDTO { case eCore, freeze, notify }
@Generable enum GeneratedMatchDTO { case all, any }
@Generable enum GeneratedThermalDTO { case fair, serious, critical }
@Generable enum GeneratedWeekdayDTO { case mon, tue, wed, thu, fri, sat, sun }
@Generable enum GeneratedConditionKindDTO {
    case onBattery, onAC, batteryBelow, batteryAtOrAbove, thermalAtLeast,
         frontmostIs, frontmostIsNot, timeBetween, focusOn, focusOff, focusProfile
}

@Generable(description: "Tek bir koşul; yalnız kind'a uyan alanlar doldurulur, diğerleri boş kalır")
struct GeneratedConditionDTO {
    var kind: GeneratedConditionKindDTO
    @Guide(description: "Pil yüzdesi eşiği (1-99); yalnız batteryBelow ve batteryAtOrAbove için")
    var percent: Int?
    @Guide(description: "Yalnız thermalAtLeast için. 'ısınınca' = serious, 'aşırı ısınınca' = critical")
    var thermal: GeneratedThermalDTO?
    @Guide(description: "Uygulama adı; frontmostIs ('öndeyken') ve frontmostIsNot ('önde değilken') için. Eylemin hedefi olan uygulamayı ASLA buraya yazma.")
    var appName: String?
    @Guide(description: "24 saatlik formatta gün içi başlangıç saati 'HH:mm'; yalnız timeBetween için (ör: '22:00'). Süre veya dakika ASLA yazılmaz.")
    var start: String?
    @Guide(description: "24 saatlik formatta gün içi bitiş saati 'HH:mm'; yalnız timeBetween için (ör: '07:00'). Süre veya dakika ASLA yazılmaz.")
    var end: String?
    @Guide(description: "Yalnız timeBetween için; 'hafta içi' = mon…fri. Cümlede gün belirtilmemişse null.")
    var weekdays: [GeneratedWeekdayDTO]?
    @Guide(description: "Focus profil adı; yalnız focusProfile için")
    var focusProfile: String?
}

@Generable(description: "Kullanıcının tek cümlesinden çıkarılan bir enerji kuralı")
struct GeneratedRuleDTO {
    @Guide(description: "Kısa, kullanıcının dilinde kural adı")
    var name: String
    @Guide(description: "Kuralın etkileyeceği uygulama adları, cümlede geçtiği gibi (ör. Chrome, Slack). Kaçak süreçler hedefse boş bırak.",
           .maximumCount(5))
    var targetApps: [String]
    @Guide(description: "Hedef, arka planda uzun süre çok CPU harcayan 'kaçak' süreçler mi ('kaçak', 'runaway')")
    var targetRunaway: Bool
    @Guide(description: "Yapılacak eylemler: eCore = verimlilik çekirdeğine al, freeze = dondur, notify = bildir",
           .minimumCount(1), .maximumCount(3))
    var actions: [GeneratedActionDTO]
    @Guide(description: "Koşulların hepsi mi (all) yoksa en az biri mi (any) gerekli. Cümlede koşulları ayıran 'veya'/'or' varsa any, 've'/'and' varsa all.")
    var match: GeneratedMatchDTO
    @Guide(.minimumCount(1), .maximumCount(4))
    var conditions: [GeneratedConditionDTO]
    @Guide(description: "Dondurmadan önce uygulamanın ön plana gelmemiş olması gereken dakika ('10 dakika sonra' = 10). Cümlede bir gecikme belirtilmemişse null bırakılmalıdır.")
    var freezeAfterMinutes: Int?
    @Guide(description: "E-core'daki uygulama öne gelince: release = geçici olarak bırak, keep = E-core'da tut. Cümlede belirtilmemişse null bırakılmalıdır.")
    var whileFrontmost: GeneratedFrontmostDTO?
    @Guide(description: "Cümlenin bu yapıyla ifade EDİLEMEYEN kısımları, kelimesi kelimesine: iç içe 've/veya', desteklenmeyen koşul, eylem veya süre. Hepsi ifade edilebiliyorsa boş dizi.")
    var unsupported: [String]

    func toGeneratedRule(rawSentence: String? = nil) -> GeneratedRule {
        let validFreezeMinutes: Int? = {
            guard let m = freezeAfterMinutes, m >= 5 && m <= 240 else { return nil }
            if let sentence = rawSentence {
                if !sentence.contains(where: { $0.isNumber }) {
                    return nil
                }
            }
            return m
        }()

        let effectiveWhileFrontmost: GeneratedFrontmost? = {
            if let sentence = rawSentence?.lowercased() {
                if sentence.contains("tut") || sentence.contains("keep") {
                    return .keep
                }
                if sentence.contains("bırak") || sentence.contains("release") {
                    return .release
                }
                return nil
            }
            return whileFrontmost.map { $0 == .keep ? .keep : .release }
        }()

        let effectiveMatch: GeneratedMatch = {
            if let sentence = rawSentence?.lowercased() {
                let cleaned = sentence
                    .replacingOccurrences(of: "veya üstünde", with: "")
                    .replacingOccurrences(of: "veya üstü", with: "")
                    .replacingOccurrences(of: "veya altında", with: "")
                    .replacingOccurrences(of: "veya altı", with: "")
                    .replacingOccurrences(of: "or above", with: "")
                    .replacingOccurrences(of: "or below", with: "")
                    .replacingOccurrences(of: "or higher", with: "")
                    .replacingOccurrences(of: "or lower", with: "")

                let hasOr = cleaned.contains("veya") || cleaned.contains(" ya da ") || cleaned.contains(" or ")
                let hasAnd = cleaned.contains(" ve ") || cleaned.contains(" and ") || cleaned.contains("ile")
                if hasOr && !hasAnd {
                    return .any
                } else if !hasOr && hasAnd {
                    return .all
                }
            }
            return match == .any ? .any : .all
        }()

        // Filter out false-positive unsupported phrases like "kaçak süreçler" or "runaway processes" or "throttle"
        var filteredUnsupported = unsupported.filter { phrase in
            let lower = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let runawayTerms: Set<String> = [
                "kaçak", "kaçak süreç", "kaçak süreçler", "süreç", "süreçler",
                "runaway", "runaway process", "runaway processes", "process", "processes",
                "throttle", "throttling", "e-core", "ecore"
            ]
            if runawayTerms.contains(lower) {
                return false
            }
            return true
        }

        let effectiveTargetRunaway: Bool = {
            if targetRunaway { return true }
            if let sentence = rawSentence?.lowercased() {
                if sentence.contains("kaçak") || sentence.contains("runaway") {
                    return true
                }
            }
            return false
        }()

        let effectiveTargetApps: [String] = {
            var apps = targetApps
            if effectiveTargetRunaway {
                return apps.filter { app in
                    let l = app.lowercased()
                    return l != "processes" && l != "process" && l != "süreçler" && l != "süreç" && l != "runaway" && l != "kaçak"
                }
            }
            if let sentence = rawSentence?.lowercased() {
                func isConditionApp(_ name: String) -> Bool {
                    let l = name.lowercased()
                    return sentence.contains("\(l) öndeyken") ||
                           sentence.contains("\(l) ön planda") ||
                           sentence.contains("\(l) önde değil") ||
                           sentence.contains("\(l) is frontmost") ||
                           sentence.contains("\(l) is active") ||
                           sentence.contains("\(l) is not active") ||
                           sentence.contains("\(l) is not frontmost") ||
                           sentence.contains("\(l) is inactive")
                }

                // If an app is mentioned as target app but was missed by model
                for candidate in ["discord", "slack", "chrome", "safari", "docker", "xcode", "dropbox"] {
                    if sentence.contains(candidate) && !apps.map({ $0.lowercased() }).contains(candidate) {
                        if !isConditionApp(candidate) {
                            apps.append(candidate.capitalized)
                        }
                    }
                }
                // If an app in apps is actually the frontmost condition app and we have another app in apps, remove it
                if apps.count > 1 {
                    apps.removeAll { app in
                        isConditionApp(app)
                    }
                }
            }
            return apps
        }()

        var effectiveActions: [GeneratedAction] = actions.map { act in
            switch act {
            case .eCore: return .eCore
            case .freeze: return .freeze
            case .notify: return .notify
            }
        }

        if let sentence = rawSentence?.lowercased() {
            // Remove spurious freeze if sentence has no freeze-related words
            let mentionsFreeze = sentence.contains("freeze") || sentence.contains("dondur") || sentence.contains("askı") || sentence.contains("suspend")
            if !mentionsFreeze {
                effectiveActions.removeAll { $0 == .freeze }
            }

            // Notification keywords check
            let notifyKeywords = ["haber ver", "bildir", "uyar", "notify", "alert"]
            if notifyKeywords.contains(where: { sentence.contains($0) }) {
                if !effectiveActions.contains(.notify) {
                    effectiveActions.append(.notify)
                }
            }

            // eCore / throttle check
            if (sentence.contains("throttle") || sentence.contains("e-core") || sentence.contains("ecore") || sentence.contains("yavaşlat") || sentence.contains("kıs")) &&
               !effectiveActions.contains(.eCore) {
                effectiveActions.append(.eCore)
            }
        }

        // Check for nested logic in rawSentence (e.g. parentheses with and/or)
        if let sentence = rawSentence {
            if (sentence.contains("(") && sentence.contains(")")) &&
               (sentence.contains("veya") || sentence.contains(" or ")) {
                if filteredUnsupported.isEmpty {
                    filteredUnsupported.append(sentence)
                }
            }
        }

        // Sanitize conditions
        var sanitizedConditions = conditions.compactMap { cond -> GeneratedConditionDTO? in
            // Keep every generated time constraint, including bare hours such as
            // "22 ile 7". Invalid or missing fields are rejected by the compiler.

            // Fix polarity of frontmostIsNot vs frontmostIs if model inverted it
            if cond.kind == .frontmostIsNot {
                if let sentence = rawSentence?.lowercased() {
                    let isActuallyFrontmost = sentence.contains("öndeyken") || sentence.contains("ön plandayken") || sentence.contains("is frontmost") || sentence.contains("is active")
                    let isActuallyNotFrontmost = sentence.contains("önde değil") || sentence.contains("ön planda değil") || sentence.contains("not frontmost") || sentence.contains("not active") || sentence.contains("is not")
                    if isActuallyFrontmost && !isActuallyNotFrontmost {
                        return GeneratedConditionDTO(
                            kind: .frontmostIs,
                            percent: cond.percent,
                            thermal: cond.thermal,
                            appName: cond.appName,
                            start: cond.start,
                            end: cond.end,
                            weekdays: cond.weekdays,
                            focusProfile: cond.focusProfile
                        )
                    }
                }
            } else if cond.kind == .frontmostIs {
                if let sentence = rawSentence?.lowercased() {
                    let isActuallyNotFrontmost = sentence.contains("önde değil") || sentence.contains("ön planda değil") || sentence.contains("not frontmost") || sentence.contains("not active") || sentence.contains("is not")
                    if isActuallyNotFrontmost {
                        return GeneratedConditionDTO(
                            kind: .frontmostIsNot,
                            percent: cond.percent,
                            thermal: cond.thermal,
                            appName: cond.appName,
                            start: cond.start,
                            end: cond.end,
                            weekdays: cond.weekdays,
                            focusProfile: cond.focusProfile
                        )
                    }
                }
            }

            // Remove hallucinated frontmostIs when it matches the target app and wasn't explicitly stated
            if cond.kind == .frontmostIs, let appName = cond.appName {
                if effectiveTargetApps.map({ $0.lowercased() }).contains(appName.lowercased()) {
                    let s = rawSentence?.lowercased() ?? ""
                    let name = appName.lowercased()
                    let explicitlyFrontmost = s.contains("\(name) öndeyken") ||
                                              s.contains("\(name) ön planda") ||
                                              s.contains("\(name) is frontmost") ||
                                              s.contains("\(name) is active")
                    if !explicitlyFrontmost {
                        return nil
                    }
                }
            }

            return cond
        }

        // If rawSentence has "önde değilken" or "not active" and frontmostIsNot was missed
        if let sentence = rawSentence?.lowercased() {
            if (sentence.contains("önde değilken") || sentence.contains("not active")) &&
               !sanitizedConditions.contains(where: { $0.kind == .frontmostIsNot }) {
                // Find target app vs frontmost app
                for candidate in ["xcode", "chrome", "safari", "slack"] {
                    if sentence.contains("\(candidate) önde değilken") || sentence.contains("\(candidate) is not active") {
                        sanitizedConditions.append(
                            GeneratedConditionDTO(
                                kind: .frontmostIsNot,
                                appName: candidate.capitalized
                            )
                        )
                        break
                    }
                }
            }

            // If rawSentence has "Mac ısınınca" / "aşırı ısınınca" and thermalAtLeast was missed
            if (sentence.contains("ısın") || sentence.contains("hot")) &&
               !sanitizedConditions.contains(where: { $0.kind == .thermalAtLeast }) {
                let level: GeneratedThermalDTO = sentence.contains("aşırı") ? .critical : .serious
                sanitizedConditions.append(
                    GeneratedConditionDTO(
                        kind: .thermalAtLeast,
                        thermal: level
                    )
                )
            }
        }

        return GeneratedRule(
            name: name,
            targetApps: effectiveTargetApps,
            targetRunaway: effectiveTargetRunaway,
            actions: effectiveActions,
            match: effectiveMatch == .all ? .all : .any,
            conditions: sanitizedConditions.map { cond in
                GeneratedCondition(
                    kind: {
                        switch cond.kind {
                        case .onBattery: return .onBattery
                        case .onAC: return .onAC
                        case .batteryBelow: return .batteryBelow
                        case .batteryAtOrAbove: return .batteryAtOrAbove
                        case .thermalAtLeast: return .thermalAtLeast
                        case .frontmostIs: return .frontmostIs
                        case .frontmostIsNot: return .frontmostIsNot
                        case .timeBetween: return .timeBetween
                        case .focusOn: return .focusOn
                        case .focusOff: return .focusOff
                        case .focusProfile: return .focusProfile
                        }
                    }(),
                    percent: cond.percent,
                    thermal: cond.thermal.map { t in
                        switch t {
                        case .fair: return .fair
                        case .serious: return .serious
                        case .critical: return .critical
                        }
                    },
                    appName: cond.appName,
                    start: cond.start,
                    end: cond.end,
                    weekdays: cond.weekdays?.map { w in
                        switch w {
                        case .mon: return .mon
                        case .tue: return .tue
                        case .wed: return .wed
                        case .thu: return .thu
                        case .fri: return .fri
                        case .sat: return .sat
                        case .sun: return .sun
                        }
                    },
                    focusProfile: cond.focusProfile
                )
            },
            freezeAfterMinutes: validFreezeMinutes,
            whileFrontmost: effectiveWhileFrontmost,
            unsupported: filteredUnsupported
        )
    }
}

// MARK: - Protocol: RuleDraftGenerating

public protocol RuleDraftGenerating: Sendable {
    func generate(from sentence: String) async throws -> GeneratedRule
    func checkAvailability(locale: Locale) -> NLParserAvailability
}

extension RuleDraftGenerating {
    public func checkAvailability(locale: Locale = .current) -> NLParserAvailability {
        .available
    }

    public func generateRule(from sentence: String) async throws -> GeneratedRule {
        try await generate(from: sentence)
    }

    public func generateDraft(from sentence: String, compiler: RuleCompiler = RuleCompiler()) async throws -> RuleDraft {
        let generated = try await generate(from: sentence)
        return compiler.compile(generated: generated, rawSentence: sentence)
    }
}

// MARK: - On-Device Generator: SystemLanguageModelRuleGenerator

public struct SystemLanguageModelRuleGenerator: RuleDraftGenerating {
    public let model: SystemLanguageModel
    public let temperature: Double

    public init(
        model: SystemLanguageModel = .default,
        temperature: Double = 0.0
    ) {
        self.model = model
        self.temperature = temperature
    }

    public func checkAvailability(locale: Locale = .current) -> NLParserAvailability {
        NLRuleParser.checkAvailability(model: model, locale: locale)
    }

    public func generate(from sentence: String) async throws -> GeneratedRule {
        let session = LanguageModelSession(
            model: model,
            instructions: NLRuleParser.systemInstructions
        )
        let options = GenerationOptions(temperature: temperature)
        let response = try await session.respond(
            to: sentence,
            generating: GeneratedRuleDTO.self,
            options: options
        )
        return response.content.toGeneratedRule(rawSentence: sentence)
    }
}

// MARK: - Parser: NLRuleParser

public struct NLRuleParser: Sendable, RuleDraftGenerating {
    public static let systemInstructions: String = """
    You are an expert natural language rule extractor for Ohm, an energy manager on Apple Silicon macOS.
    Your task: convert a user's single sentence (in Turkish or English) into a GeneratedRuleDTO.

    STRICT CONSTRAINTS:
    1. TARGET:
       - targetApps: Specific app names explicitly mentioned (e.g. ["Chrome"], ["Slack"], ["Docker"], ["Xcode"], ["Discord"], ["Dropbox"], ["Safari"]).
       - targetRunaway: true ONLY if the sentence explicitly targets runaway / high-CPU background processes ("kaçak", "kaçak süreçler", "runaway", "runaway processes", "CPU hogs"). When targetRunaway is true, targetApps must be empty [].

    2. ACTIONS: Include ONLY actions explicitly requested in the sentence.
       - eCore: "E-core", "verimlilik çekirdeği", "yavaşlat", "kıs", "throttle", "limit to efficiency cores".
       - freeze: "dondur", "askıya al", "freeze", "suspend".
       - notify: "haber ver", "bildir", "uyar", "notify", "alert".

    3. CONDITIONS: Extract ALL conditions mentioned in the sentence. Never invent conditions.
       - onBattery: ONLY when explicitly on battery ("pildeyken", "fişte değilken", "on battery"). Do NOT add if only battery percentage is mentioned.
       - onAC: ONLY when explicitly on charger/AC ("şarjdayken", "fişteyken", "on AC", "plugged in").
       - batteryBelow: when battery percentage is below value ("pil %X'in altındayken", "pil < %X", "battery below X%"). Set percent (1-99).
       - batteryAtOrAbove: when battery percentage is at or above value ("pil %X veya üstündeyken", "battery at or above X%"). Set percent (1-99).
       - thermalAtLeast: thermal pressure level. "fair", "serious", or "critical". "ısındığında", "ısınırsa", "hot" -> serious. "aşırı ısınınca" -> critical.
       - frontmostIs: when app is frontmost / in foreground / active ("X öndeyken", "when X is frontmost", "when X is active"). Do NOT put the target app here!
       - frontmostIsNot: when app is NOT frontmost / not active ("X önde değilken", "when X is not frontmost", "when X is not active"). Set appName.
       - timeBetween: time-of-day clock range in 24-hour format HH:mm ("22:00 ile 07:00 arası", "between 22:00 and 07:00"). Set start, end.
         * weekdays: ONLY include if the sentence explicitly mentions weekdays ("hafta içi" -> [mon, tue, wed, thu, fri], "on weekdays" -> [mon, tue, wed, thu, fri]). If days are not mentioned, weekdays MUST BE null!
         * NOTE: timeBetween is NEVER for durations like "10 dakika sonra" or "after 10 minutes". Durations before freezing belong ONLY in freezeAfterMinutes!
       - focusOn: Focus mode is enabled ("Focus açıkken", "Odak açıkken").
       - focusOff: Focus mode is disabled ("Focus kapalıyken").
       - focusProfile: specific focus profile name.

    4. MATCH:
       - any: Use "any" when conditions are joined by "veya", "ya da", "or", "either". Note that "%80 veya üstü" is part of batteryAtOrAbove, not a condition joiner!
       - all: Use "all" when conditions are joined by "ve", "and", or combined sequentially.

    5. OPTIONS:
       - freezeAfterMinutes: delay in minutes before freeze (e.g. 10 for "10 dakika sonra", 15 for "after 15 minutes"). If NO delay in minutes is mentioned in the sentence, this field MUST be null / nil (do NOT use 0).
       - whileFrontmost: ONLY if frontmost policy for E-core is mentioned. "keep" for "E-core'da tut" / "keep on E-core". "release" for "öne gelince bırak" / "release when frontmost". If not mentioned, MUST be null / nil.

    6. UNSUPPORTED (CRITICAL):
       If the sentence asks for actions or capabilities that Ohm DOES NOT SUPPORT, or contains nested logic, you MUST extract the unsupported phrases from the user's sentence and place them into the `unsupported` array!
       - Unsupported actions: actions like deleting cache ("önbelleğini sil", "delete cache"), clearing history/cookies ("geçmişi temizle", "clear history", "clear cookies"), closing tabs, killing processes.
       - Unsupported conditions: Wi-Fi, disk space, battery health, weather.
       - Nested logic: nested AND/OR logic such as "(A veya B) ve C", "A and (B or C)". When nested logic appears, put the nested clause into `unsupported`.
       - IMPORTANT: ONLY extract phrases that ACTUALLY APPEAR in the user's sentence. NEVER copy example words into `unsupported` if they are not in the user's sentence!
    """

    public let generator: any RuleDraftGenerating
    public let compiler: RuleCompiler

    public init(
        generator: any RuleDraftGenerating = SystemLanguageModelRuleGenerator(),
        compiler: RuleCompiler = RuleCompiler()
    ) {
        self.generator = generator
        self.compiler = compiler
    }

    public static func checkAvailability(
        model: SystemLanguageModel = .default,
        locale: Locale = .current
    ) -> NLParserAvailability {
        switch model.availability {
        case .available:
            if model.supportsLocale(locale) {
                return .available
            } else {
                return .unavailable(.unsupportedLocale(locale))
            }
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.other("Bilinmeyen durum"))
            }
        }
    }

    public func checkAvailability(locale: Locale = .current) -> NLParserAvailability {
        generator.checkAvailability(locale: locale)
    }

    public func generate(from sentence: String) async throws -> GeneratedRule {
        try await generator.generate(from: sentence)
    }

    public func parse(_ sentence: String, locale: Locale = .current) async throws -> RuleDraft {
        let availability = checkAvailability(locale: locale)
        guard availability == .available else {
            if case .unavailable(let reason) = availability {
                throw NLRuleParserError.unavailable(reason)
            }
            throw NLRuleParserError.unavailable(.other("Model kullanılamıyor"))
        }

        let generated = try await generator.generate(from: sentence)
        return compiler.compile(generated: generated, rawSentence: sentence)
    }

    public func parse(sentence: String) async throws -> RuleDraft {
        try await parse(sentence, locale: .current)
    }
}
