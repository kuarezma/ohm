import Testing
import Foundation
import FoundationModels
@testable import OhmModel
@testable import OhmRules

// MARK: - Evaluation Data Model

struct NLEvalEntry: Codable, Sendable {
    var id: String
    var sentence: String
    var expectedType: String
    var expectedRule: Rule?
}

// MARK: - Test Suite

struct NLRuleParserTests {

    // MARK: - 1. Privacy Rule Test (Hard Constraint)
    // Ohm promises "nothing leaves your Mac".
    // Must ONLY use SystemLanguageModel (on-device).
    // Fails if "PrivateCloudCompute" appears in OhmRules sources.

    @Test func privacyRule_noPrivateCloudComputeInSources() throws {
        // Find sources path
        let fileURL = URL(fileURLWithPath: #filePath)
        let ohmRulesSourcesDir = fileURL
            .deletingLastPathComponent() // OhmRulesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OhmCore
            .appendingPathComponent("Sources")
            .appendingPathComponent("OhmRules")

        let forbiddenTerm = ["Private", "Cloud", "Compute"].joined()

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: ohmRulesSourcesDir, includingPropertiesForKeys: nil)
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }

        #expect(!swiftFiles.isEmpty, "Sources/OhmRules should contain Swift files")

        for url in swiftFiles {
            let fileContent = try String(contentsOf: url, encoding: .utf8)
            let containsForbidden = fileContent.contains(forbiddenTerm)
            #expect(!containsForbidden, "Forbidden term '\(forbiddenTerm)' found in \(url.lastPathComponent)")
        }
    }

    // MARK: - 2. Unit Tests with Fake Generator (Deterministic, Always Run)

    struct FakeGenerator: RuleDraftGenerating {
        var availability: NLParserAvailability = .available
        var generateClosure: @Sendable (String) async throws -> GeneratedRule

        func checkAvailability(locale: Locale = .current) -> NLParserAvailability {
            availability
        }

        func generate(from sentence: String) async throws -> GeneratedRule {
            try await generateClosure(sentence)
        }
    }

    @Test func fakeGenerator_deterministicReadyRule_enabledIsFalse() async throws {
        let fake = FakeGenerator { _ in
            GeneratedRule(
                name: "Low battery Chrome",
                targetApps: ["Chrome"],
                targetRunaway: false,
                actions: [.eCore],
                match: .all,
                conditions: [
                    GeneratedCondition(kind: .batteryBelow, percent: 30)
                ],
                freezeAfterMinutes: nil,
                whileFrontmost: nil,
                unsupported: []
            )
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        let draft = try await parser.parse("Pil %30 altındayken Chrome'u E-core'a al")

        guard case .ready(let rule) = draft else {
            Issue.record("Expected .ready draft, got \(draft)")
            return
        }

        // NL rules are NEVER activated without user confirmation
        #expect(rule.enabled == false)
        #expect(rule.actions == [.eCore(whileFrontmost: .release)])
        #expect(rule.targets == .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Google Chrome")]))
        #expect(rule.when == .all([.powerSource(.battery), .batteryPercent(.below, value: 30, hysteresis: nil)]))
    }

    @Test func fakeGenerator_unsupportedAction_neverSilentlyWeaker() async throws {
        let fake = FakeGenerator { _ in
            GeneratedRule(
                name: "Unsupported delete",
                targetApps: ["Chrome"],
                targetRunaway: false,
                actions: [.eCore],
                match: .all,
                conditions: [],
                freezeAfterMinutes: nil,
                whileFrontmost: nil,
                unsupported: ["delete cache"]
            )
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        let draft = try await parser.parse("Delete Chrome's cache")

        guard case .unsupported(let phrases) = draft else {
            Issue.record("Expected .unsupported draft, got \(draft)")
            return
        }

        #expect(phrases.contains("delete cache"))
    }

    @Test func fakeGenerator_compilerSideProtection_invalidFreezeDuration() async throws {
        let fake = FakeGenerator { _ in
            GeneratedRule(
                name: "Invalid freeze",
                targetApps: ["Slack"],
                targetRunaway: false,
                actions: [.freeze],
                match: .all,
                conditions: [GeneratedCondition(kind: .onBattery)],
                freezeAfterMinutes: 2, // invalid: < 5
                whileFrontmost: nil,
                unsupported: []
            )
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        let draft = try await parser.parse("Slack'i 2 dakika sonra dondur")

        guard case .unsupported(let phrases) = draft else {
            Issue.record("Expected .unsupported due to <5 min freeze delay, got \(draft)")
            return
        }

        #expect(phrases.contains(where: { $0.contains("5–240") }))
    }

    @Test func fakeGenerator_compilerSideProtection_freezeDurationWithoutFreezeAction() async throws {
        let fake = FakeGenerator { _ in
            GeneratedRule(
                name: "Invalid duration",
                targetApps: ["Slack"],
                targetRunaway: false,
                actions: [.eCore],
                match: .all,
                conditions: [GeneratedCondition(kind: .onBattery)],
                freezeAfterMinutes: 10,
                whileFrontmost: nil,
                unsupported: []
            )
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        let draft = try await parser.parse("Slack'i 10 dakika sonra E-core'a al")

        guard case .unsupported(let phrases) = draft else {
            Issue.record("Expected .unsupported due to freeze duration without freeze action, got \(draft)")
            return
        }

        #expect(phrases.contains(where: { $0.contains("freeze") }))
    }

    @Test func fakeGenerator_needsClarification_anyWithBatteryBelowAndAC() async throws {
        let fake = FakeGenerator { _ in
            GeneratedRule(
                name: "Ambiguous battery and AC",
                targetApps: ["Slack"],
                targetRunaway: false,
                actions: [.eCore],
                match: .any,
                conditions: [
                    GeneratedCondition(kind: .batteryBelow, percent: 20),
                    GeneratedCondition(kind: .onAC)
                ],
                freezeAfterMinutes: nil,
                whileFrontmost: nil,
                unsupported: []
            )
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        let draft = try await parser.parse("Pil %20 altındayken veya şarjdayken Slack'i E-core'a al")

        guard case .needsClarification(let rule, let questions) = draft else {
            Issue.record("Expected .needsClarification, got \(draft)")
            return
        }

        #expect(!questions.isEmpty)
        #expect(rule.enabled == false)
    }

    @Test func fakeGenerator_unavailableStatus_throwsTypedError() async throws {
        let fake = FakeGenerator(availability: .unavailable(.appleIntelligenceNotEnabled)) { _ in
            fatalError("Should not be called")
        }

        let parser = NLRuleParser(generator: fake, compiler: RuleCompiler(appResolver: confirmedTestResolver))
        #expect(parser.checkAvailability() == .unavailable(.appleIntelligenceNotEnabled))

        await #expect(throws: NLRuleParserError.unavailable(.appleIntelligenceNotEnabled)) {
            _ = try await parser.parse("Herhangi bir kural")
        }
    }

    // MARK: - 3. Live Evaluation Test (Tagged & Guarded, Runs only when SystemLanguageModel is available)

    // Opt in outside the sandbox; availability alone does not prove model-service access.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OHM_RUN_LIVE_NL_EVAL"] == "1"))
    func liveEval_nlEvalSet() async throws {
        let availability = NLRuleParser.checkAvailability()
        guard availability == .available else {
            print("SystemLanguageModel is unavailable: \(availability). Skipping live eval test.")
            return
        }

        let evalEntries = try loadEvalEntries()
        #expect(evalEntries.count == 20, "nl_eval.json must contain exactly 20 sentences")

        // Measures the model, not which apps happen to be installed on this machine.
        let parser = NLRuleParser(compiler: RuleCompiler(appResolver: confirmedTestResolver))
        var passedCount = 0
        var lessRestrictiveCount = 0
        var failureDetails: [String] = []

        for entry in evalEntries {
            do {
                let draft = try await parser.parse(entry.sentence)

                switch entry.expectedType {
                case "unsupported":
                    switch draft {
                    case .unsupported:
                        passedCount += 1
                        print("  [PASS] \(entry.id): correctly marked unsupported")
                    case .ready(let rule):
                        lessRestrictiveCount += 1
                        let detail = "\(entry.id): FAILED - expected unsupported, but generated rule: \(rule.name)"
                        failureDetails.append(detail)
                        print("  [FAIL] \(detail)")
                    case .needsClarification:
                        let detail = "\(entry.id): FAILED - expected unsupported, got needsClarification"
                        failureDetails.append(detail)
                        print("  [FAIL] \(detail)")
                    }

                case "ready":
                    guard let expectedRule = entry.expectedRule else {
                        Issue.record("\(entry.id): missing expectedRule in test data")
                        continue
                    }

                    switch draft {
                    case .ready(let actualRule):
                        let diff = compareRules(actual: actualRule, expected: expectedRule)
                        if diff == nil {
                            passedCount += 1
                            print("  [PASS] \(entry.id): matched expected rule")
                        } else {
                            let detail = "\(entry.id): FAILED mismatch - \(diff!)"
                            failureDetails.append(detail)
                            print("  [FAIL] \(detail)")
                        }
                    case .unsupported(let phrases):
                        let detail = "\(entry.id): FAILED - expected ready rule, but marked unsupported (\(phrases))"
                        failureDetails.append(detail)
                        print("  [FAIL] \(detail)")
                    case .needsClarification(_, let questions):
                        let detail = "\(entry.id): FAILED - expected ready rule, got needsClarification (\(questions.map(\.question)))"
                        failureDetails.append(detail)
                        print("  [FAIL] \(detail)")
                    }

                default:
                    Issue.record("Unknown expectedType: \(entry.expectedType)")
                }
            } catch {
                let detail = "\(entry.id): FAILED with error: \(error)"
                failureDetails.append(detail)
                print("  [FAIL] \(detail)")
            }
        }

        print("--------------------------------------------------")
        print("LIVE EVAL SCORE: \(passedCount)/20 (passed: \(passedCount >= 18))")
        if !failureDetails.isEmpty {
            print("Failures:")
            for f in failureDetails {
                print("  - \(f)")
            }
        }
        print("--------------------------------------------------")

        // PLAN gate: ≥18/20 correct
        #expect(passedCount >= 18, "PLAN gate: must achieve at least 18/20 correct (got \(passedCount)/20)")

        // ZERO cases where compiled rule is less restrictive than expected
        #expect(lessRestrictiveCount == 0, "ZERO cases where compiled rule is less restrictive than expected")
    }

    // MARK: - Helpers

    private func loadEvalEntries() throws -> [NLEvalEntry] {
        let jsonURL: URL
        if let moduleURL = Bundle.module.url(forResource: "nl_eval", withExtension: "json") {
            jsonURL = moduleURL
        } else {
            jsonURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("nl_eval.json")
        }

        let data = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        return try decoder.decode([NLEvalEntry].self, from: data)
    }

    private func compareRules(actual: Rule, expected: Rule) -> String? {
        // Compare when
        if !areConditionsSemanticallyEqual(actual.when, expected.when) {
            return "when mismatch: got \(actual.when), expected \(expected.when)"
        }

        // Compare targets
        if !areTargetsEqual(actual.targets, expected.targets) {
            return "targets mismatch: got \(actual.targets), expected \(expected.targets)"
        }

        // Compare actions
        if !areActionsEqual(actual.actions, expected.actions) {
            return "actions mismatch: got \(actual.actions), expected \(expected.actions)"
        }

        // Compare options
        if actual.options != expected.options {
            return "options mismatch: got \(actual.options), expected \(expected.options)"
        }

        return nil
    }

    private func areConditionsSemanticallyEqual(_ a: Condition, _ b: Condition) -> Bool {
        if a == b { return true }
        switch (a, b) {
        case (.all(let listA), .all(let listB)):
            guard listA.count == listB.count else { return false }
            return matchUnorderedConditions(listA, listB)
        case (.any(let listA), .any(let listB)):
            guard listA.count == listB.count else { return false }
            return matchUnorderedConditions(listA, listB)
        case (.not(let condA), .not(let condB)):
            return areConditionsSemanticallyEqual(condA, condB)
        default:
            return false
        }
    }

    private func matchUnorderedConditions(_ listA: [Condition], _ listB: [Condition]) -> Bool {
        var remainingB = listB
        for itemA in listA {
            if let idx = remainingB.firstIndex(where: { areConditionsSemanticallyEqual(itemA, $0) }) {
                remainingB.remove(at: idx)
            } else {
                return false
            }
        }
        return remainingB.isEmpty
    }

    private func areTargetsEqual(_ a: TargetSelector, _ b: TargetSelector) -> Bool {
        switch (a, b) {
        case (.runaway, .runaway):
            return true
        case (.apps(let appsA), .apps(let appsB)):
            let idsA = Set(appsA.compactMap(\.bundleID))
            let idsB = Set(appsB.compactMap(\.bundleID))
            return idsA == idsB
        case (.allApps(let exceptA), .allApps(let exceptB)):
            let idsA = Set(exceptA.compactMap(\.bundleID))
            let idsB = Set(exceptB.compactMap(\.bundleID))
            return idsA == idsB
        default:
            return false
        }
    }

    private func areActionsEqual(_ a: [Action], _ b: [Action]) -> Bool {
        guard a.count == b.count else { return false }
        let setA = Set(a)
        let setB = Set(b)
        return setA == setB
    }
}
