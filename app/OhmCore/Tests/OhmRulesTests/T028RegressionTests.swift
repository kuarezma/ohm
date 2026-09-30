import Foundation
import Testing
@testable import OhmModel
@testable import OhmRules

// Confirmed inventory keeps compiler tests independent of installed applications.
let confirmedTestResolver = DefaultAppResolver(customMappings:
    DefaultAppResolver.standardApps.mapValues {
        [AppRef(bundleID: $0.bundleID, displayName: $0.displayName)]
    }, applicationInventory: []
)

struct T028RegressionTests {
    private let compiler = RuleCompiler(appResolver: confirmedTestResolver)

    private func generated(_ conditions: [GeneratedCondition], actions: [GeneratedAction] = [.eCore]) -> GeneratedRule {
        GeneratedRule(name: "Deneme", targetApps: ["Slack"], actions: actions, match: .all, conditions: conditions)
    }

    @Test func finding5_timeWithoutColonIsNeverDropped() {
        let dto = GeneratedRuleDTO(
            name: "Gece", targetApps: ["Slack"], targetRunaway: false,
            actions: [.freeze], match: .all,
            conditions: [GeneratedConditionDTO(kind: .timeBetween, start: "22:00", end: "07:00")],
            freezeAfterMinutes: nil, whileFrontmost: nil, unsupported: []
        )
        let sentence = "22 ile 7 arasında Slack'i dondur"
        let converted = dto.toGeneratedRule(rawSentence: sentence)
        #expect(converted.conditions.contains { $0.kind == .timeBetween } || !converted.unsupported.isEmpty)
        let draft = compiler.compile(generated: converted, rawSentence: sentence)
        if case .ready(let rule) = draft {
            #expect(rule.when == .timeWindow(start: LocalTime(hour: 22, minute: 0), end: LocalTime(hour: 7, minute: 0), weekdays: nil))
        }
    }

    @Test func finding5_emptyConditionsAreRejected() {
        #expect(isUnsupported(compiler.compile(generated: generated([]))))
        for condition in [Condition.all([]), .any([]), .not(.all([]))] {
            #expect(throws: RuleValidationError.self) { try RuleValidator.validate(rule: manual(condition)) }
        }
    }

    @Test func finding6_missingAndMalformedFieldsAreRejected() {
        let invalid: [GeneratedCondition] = [
            .init(kind: .batteryBelow), .init(kind: .batteryAtOrAbove),
            .init(kind: .batteryBelow, percent: 0), .init(kind: .batteryBelow, percent: 100),
            .init(kind: .timeBetween, end: "07:00"), .init(kind: .timeBetween, start: "22:00"),
            .init(kind: .timeBetween, start: "25:00", end: "07:00"),
            .init(kind: .timeBetween, start: "22:00", end: "07:60"),
            .init(kind: .timeBetween, start: "7:00", end: "08:00"),
            .init(kind: .thermalAtLeast), .init(kind: .frontmostIs),
            .init(kind: .frontmostIsNot, appName: " "), .init(kind: .focusProfile),
            .init(kind: .focusProfile, focusProfile: " ")
        ]
        for condition in invalid {
            #expect(isUnsupported(compiler.compile(generated: generated([condition]))), "Invalid condition: \(condition)")
        }
        for percent in [1, 99] {
            guard case .ready = compiler.compile(generated: generated([.init(kind: .batteryBelow, percent: percent)])) else {
                Issue.record("Valid threshold rejected: \(percent)")
                continue
            }
        }
    }

    @Test func finding6_validatorRejectsInvalidPersistentConditions() {
        let invalid: [Condition] = [
            .batteryPercent(.below, value: 0, hysteresis: nil),
            .batteryPercent(.atOrAbove, value: 100, hysteresis: nil),
            .batteryPercent(.below, value: 30, hysteresis: 0),
            .batteryPercent(.below, value: 30, hysteresis: 11),
            .frontmostApp(AppRef(displayName: " ")), .focusProfile(" "),
            .timeWindow(start: LocalTime(hour: 24, minute: 0), end: LocalTime(hour: 7, minute: 0), weekdays: nil),
            .timeWindow(start: LocalTime(hour: 22, minute: 0), end: LocalTime(hour: 7, minute: 60), weekdays: nil)
        ]
        for condition in invalid {
            #expect(throws: RuleValidationError.self) { try RuleValidator.validate(rule: manual(condition)) }
        }
    }

    @Test func finding6_compilerRunsValidatorBeforeReadyOrClarification() {
        var rule = generated([.init(kind: .onBattery)], actions: [.freeze])
        rule.targetApps = []
        rule.targetRunaway = true
        #expect(isUnsupported(compiler.compile(generated: rule)))
        rule.targetRunaway = false
        rule.targetApps = ["Xcode"]
        #expect(isUnsupported(compiler.compile(generated: rule)))
        rule.conditions = [.init(kind: .batteryBelow, percent: 20), .init(kind: .onAC)]
        rule.match = .any
        #expect(isUnsupported(compiler.compile(generated: rule)))
    }

    @Test func finding7_pendingInactiveKeepsEffectsAndDoesNotRenotify() async {
        var rule = manual(.thermal(atLeast: .serious))
        rule.actions = [.eCore(), .freeze(), .notify(message: nil)]
        rule.options = RuleOptions(activateAfter: .zero, deactivateAfter: .seconds(60), notifyCooldown: .zero)
        let engine = RuleEngine(rules: [rule])
        let key = AppKey(kind: .bundleID, value: "com.tinyspeck.slackmacgap")
        let start = Date(timeIntervalSince1970: 1000)
        var context = RuleContext(powerSource: .battery, batteryPercent: 50, thermalLevel: .serious, now: start)
        let active = await engine.evaluate(context)
        #expect(active.notifications.count == 1)
        context.thermalLevel = .nominal
        context.now = start.addingTimeInterval(1)
        let pending = await engine.evaluate(context)
        #expect(pending.desiredState == active.desiredState)
        #expect(pending.nextDeadline == start.addingTimeInterval(61))
        context.now = start.addingTimeInterval(60)
        let beforeDeadline = await engine.evaluate(context)
        #expect(beforeDeadline.desiredState == active.desiredState)
        context.thermalLevel = .serious
        let resumed = await engine.evaluate(context)
        #expect(resumed.desiredState == active.desiredState)
        #expect(resumed.notifications.isEmpty)
        context.thermalLevel = .nominal
        context.now = start.addingTimeInterval(62)
        _ = await engine.evaluate(context)
        context.now = start.addingTimeInterval(122)
        let inactive = await engine.evaluate(context)
        #expect(inactive.ruleStates[rule.id] == .inactive)
        #expect(inactive.desiredState.effects[key] == nil)
    }

    @Test func finding7_manualOverrideDuringPendingInactiveSurvivesBounce() async {
        var rule = manual(.thermal(atLeast: .serious))
        rule.options = RuleOptions(activateAfter: .zero, deactivateAfter: .seconds(60))
        let engine = RuleEngine(rules: [rule])
        let key = AppKey(kind: .bundleID, value: "com.tinyspeck.slackmacgap")
        var context = RuleContext(powerSource: .battery, batteryPercent: 50, thermalLevel: .serious, now: Date(timeIntervalSince1970: 1000))
        _ = await engine.evaluate(context)
        context.thermalLevel = .nominal
        _ = await engine.evaluate(context)
        await engine.recordManualOverride(for: key)
        context.thermalLevel = .serious
        let bounced = await engine.evaluate(context)
        #expect(bounced.desiredState.effects[key] == nil)
        context.thermalLevel = .nominal
        _ = await engine.evaluate(context)
        context.now = context.now.addingTimeInterval(60)
        _ = await engine.evaluate(context)
        context.thermalLevel = .serious
        let rearmed = await engine.evaluate(context)
        #expect(rearmed.desiredState.effects[key]?.eCore != nil)
    }

    @Test func finding9_targetAndConditionUseSameClarificationPath() {
        let candidateSets: [[AppRef]] = [
            [], [AppRef(displayName: "Editor")],
            [AppRef(bundleID: "", executableName: " ", displayName: "Editor")],
            [AppRef(bundleID: "com.test.a", displayName: "Editor A"), AppRef(bundleID: "com.test.b", displayName: "Editor B")]
        ]
        for candidates in candidateSets {
            let resolver = DefaultAppResolver(customMappings: ["editor": candidates, "slack": [AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]])
            let compiler = RuleCompiler(appResolver: resolver)
            for kind in [GeneratedConditionKind.frontmostIs, .frontmostIsNot] {
                var target = generated([.init(kind: .onBattery)])
                target.targetApps = ["Editor"]
                let condition = generated([.init(kind: kind, appName: "Editor")])
                guard case .needsClarification(let targetRule, let targetQuestions) = compiler.compile(generated: target),
                      case .needsClarification(let conditionRule, let conditionQuestions) = compiler.compile(generated: condition) else {
                    Issue.record("Unresolved or ambiguous target and condition must both ask: \(candidates)")
                    continue
                }
                #expect(targetQuestions == conditionQuestions)
                #expect(!targetRule.enabled && !conditionRule.enabled)
                #expect(targetRule.targets == .apps([AppRef(displayName: "Editor")]))
                let placeholder = Condition.frontmostApp(AppRef(displayName: "Editor"))
                #expect(conditionRule.when == (kind == .frontmostIs ? placeholder : .not(placeholder)))
            }
        }
    }

    @Test func finding9_nameTableAloneCannotProveIdentity() {
        let draft = RuleCompiler(appResolver: DefaultAppResolver(applicationInventory: [])).compile(generated: generated([.init(kind: .frontmostIs, appName: "Chrome")]))
        guard case .needsClarification(_, let questions) = draft else {
            Issue.record("Static table must not authorize target or condition identity")
            return
        }
        #expect(questions.count == 2)
    }

    @Test func finding9_inventoryAliasesDoNotHideAmbiguity() {
        let chrome = AppRef(bundleID: "com.google.Chrome", displayName: "Google Chrome")
        let canary = AppRef(bundleID: "com.google.Chrome.canary", displayName: "Google Chrome Canary")
        let resolver = DefaultAppResolver(applicationInventory: [chrome, canary])
        #expect(resolver.resolve(appName: "Chrome") == [chrome, canary])
        #expect(resolver.resolve(appName: "Google Chrome") == [chrome])
        #expect(resolver.resolve(appName: "Missing") == [])
        let draft = RuleCompiler(appResolver: resolver).compile(generated:
            GeneratedRule(name: "Chrome", targetApps: ["Chrome"], actions: [.eCore], match: .all,
                          conditions: [.init(kind: .frontmostIsNot, appName: "Chrome")]))
        guard case .needsClarification(_, let questions) = draft else {
            Issue.record("Inventory ambiguity must reach both target and condition questions")
            return
        }
        #expect(questions.count == 2)
    }

    private func isUnsupported(_ draft: RuleDraft) -> Bool {
        if case .unsupported = draft { return true }
        return false
    }

    private func manual(_ condition: Condition) -> Rule {
        Rule(name: "Deneme", enabled: true, source: .manual, when: condition,
             targets: .apps([AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]), actions: [.eCore()])
    }
}
