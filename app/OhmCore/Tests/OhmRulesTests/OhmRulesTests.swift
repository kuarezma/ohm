import Testing
import Foundation
@testable import OhmModel
@testable import OhmRules

struct OhmRulesTests {

    // MARK: - 1. ADR 0003 Example Rules JSON Decode + Encode

    @Test func example1_batteryPercentChrome_decodeAndReencode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "3F2A7C1E-0B6D-4E8A-9C11-2D5E8F0A6B01",
          "name": "Düşük pilde Chrome E-core",
          "enabled": true,
          "source": { "type": "naturalLanguage", "text": "Pil %30'un altındayken Chrome'u E-core'a al" },
          "when": {
            "type": "all",
            "of": [
              { "type": "powerSource", "is": "battery" },
              { "type": "batteryPercent", "op": "below", "value": 30 }
            ]
          },
          "targets": {
            "type": "apps",
            "apps": [
              { "bundleID": "com.google.Chrome", "displayName": "Google Chrome" }
            ]
          },
          "actions": [
            { "type": "eCore", "whileFrontmost": "release" }
          ]
        }
        """

        let decoder = JSONDecoder()
        let rule = try decoder.decode(Rule.self, from: Data(json.utf8))

        #expect(rule.schemaVersion == 1)
        #expect(rule.id == UUID(uuidString: "3F2A7C1E-0B6D-4E8A-9C11-2D5E8F0A6B01"))
        #expect(rule.name == "Düşük pilde Chrome E-core")
        #expect(rule.enabled == true)
        #expect(rule.source == .naturalLanguage(text: "Pil %30'un altındayken Chrome'u E-core'a al"))
        #expect(rule.when == .all([
            .powerSource(.battery),
            .batteryPercent(.below, value: 30, hysteresis: nil)
        ]))
        #expect(rule.targets == .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Google Chrome")]))
        #expect(rule.actions == [.eCore(whileFrontmost: .release)])

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rule)
        let redecodedRule = try decoder.decode(Rule.self, from: encodedData)
        #expect(redecodedRule == rule)
    }

    @Test func example2_slackFreeze_decodeAndReencode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "8C0D5B2A-6E71-4F3C-A2D4-5B9E1C7F3A02",
          "name": "Pilde Slack'i dondur",
          "enabled": true,
          "source": { "type": "manual" },
          "when": { "type": "powerSource", "is": "battery" },
          "targets": {
            "type": "apps",
            "apps": [
              { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack" }
            ]
          },
          "actions": [
            { "type": "freeze", "minHiddenSeconds": 600 },
            { "type": "eCore" }
          ]
        }
        """

        let decoder = JSONDecoder()
        let rule = try decoder.decode(Rule.self, from: Data(json.utf8))

        #expect(rule.id == UUID(uuidString: "8C0D5B2A-6E71-4F3C-A2D4-5B9E1C7F3A02"))
        #expect(rule.source == .manual)
        #expect(rule.when == .powerSource(.battery))
        #expect(rule.actions == [
            .freeze(minHiddenSeconds: 600),
            .eCore(whileFrontmost: .release)
        ])

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rule)
        let redecodedRule = try decoder.decode(Rule.self, from: encodedData)
        #expect(redecodedRule == rule)
    }

    @Test func example3_dockerThermal_decodeAndReencode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "1E9B4D7C-2A38-4B6F-8D05-7C3A9E2F1B03",
          "name": "Sıcakta Docker'ı yavaşlat",
          "enabled": true,
          "source": { "type": "naturalLanguage", "text": "Mac ısınınca Docker'ı E-core'a al ve bana haber ver" },
          "when": { "type": "thermal", "atLeast": "serious" },
          "targets": {
            "type": "apps",
            "apps": [
              { "bundleID": "com.docker.docker", "displayName": "Docker" }
            ]
          },
          "actions": [
            { "type": "eCore", "whileFrontmost": "keep" },
            { "type": "notify" }
          ],
          "options": { "notifyCooldown": 3600 }
        }
        """

        let decoder = JSONDecoder()
        let rule = try decoder.decode(Rule.self, from: Data(json.utf8))

        #expect(rule.when == .thermal(atLeast: .serious))
        #expect(rule.actions == [
            .eCore(whileFrontmost: .keep),
            .notify(message: nil)
        ])
        #expect(rule.options.notifyCooldown == .seconds(3600))

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rule)
        let redecodedRule = try decoder.decode(Rule.self, from: encodedData)
        #expect(redecodedRule == rule)
    }

    @Test func example4_xcodeCoding_decodeAndReencode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "5A6C2E8B-9D14-4C7A-B3F0-8E1D4A6C2B04",
          "name": "Odaklı kodlama",
          "enabled": true,
          "source": { "type": "manual" },
          "when": {
            "type": "frontmostApp",
            "app": { "bundleID": "com.apple.dt.Xcode", "displayName": "Xcode" }
          },
          "targets": {
            "type": "apps",
            "apps": [
              { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack" },
              { "bundleID": "com.hnc.Discord", "displayName": "Discord" }
            ]
          },
          "actions": [
            { "type": "freeze" }
          ]
        }
        """

        let decoder = JSONDecoder()
        let rule = try decoder.decode(Rule.self, from: Data(json.utf8))

        #expect(rule.when == .frontmostApp(AppRef(bundleID: "com.apple.dt.Xcode", displayName: "Xcode")))
        #expect(rule.actions == [.freeze(minHiddenSeconds: nil)])

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rule)
        let redecodedRule = try decoder.decode(Rule.self, from: encodedData)
        #expect(redecodedRule == rule)
    }

    @Test func example5_nightDropbox_decodeAndReencode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "C4B1F3A9-7E25-4D8B-9A6C-3F2E5D8B1C05",
          "name": "Gece Dropbox'ı yavaşlat",
          "enabled": true,
          "source": { "type": "naturalLanguage", "text": "Hafta içi 22:00 ile 07:00 arası Focus açıkken Dropbox'ı E-core'a al" },
          "when": {
            "type": "all",
            "of": [
              {
                "type": "timeWindow",
                "start": "22:00",
                "end": "07:00",
                "weekdays": ["mon", "tue", "wed", "thu", "fri"]
              },
              { "type": "focus", "isOn": true }
            ]
          },
          "targets": {
            "type": "apps",
            "apps": [
              { "bundleID": "com.getdropbox.dropbox", "displayName": "Dropbox" }
            ]
          },
          "actions": [
            { "type": "eCore", "whileFrontmost": "keep" }
          ]
        }
        """

        let decoder = JSONDecoder()
        let rule = try decoder.decode(Rule.self, from: Data(json.utf8))

        let expectedWeekdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]
        #expect(rule.when == .all([
            .timeWindow(start: LocalTime(hour: 22, minute: 0), end: LocalTime(hour: 7, minute: 0), weekdays: expectedWeekdays),
            .focus(isOn: true)
        ]))

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rule)
        let redecodedRule = try decoder.decode(Rule.self, from: encodedData)
        #expect(redecodedRule == rule)
    }

    @Test func rulesDocument_decodeAndEncode() throws {
        let doc = RulesDocument(schemaVersion: 1, rules: [
            Rule(
                id: UUID(),
                name: "Test Rule",
                enabled: true,
                source: .manual,
                when: .powerSource(.battery),
                targets: .apps([AppRef(bundleID: "com.test.app", displayName: "TestApp")]),
                actions: [.eCore(whileFrontmost: .release)]
            )
        ])

        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(RulesDocument.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.rules.count == 1)
        #expect(decoded.rules[0].name == "Test Rule")
    }

    // MARK: - 2. The 5 Mandatory Battery-Normalization Tests (ADR 0003 § 4)

    @Test func batteryNorm_1_allWithSingleThreshold() {
        let compiler = RuleCompiler()
        let generated = GeneratedRule(
            name: "Test 1",
            targetApps: ["Chrome"],
            actions: [.eCore],
            match: .all,
            conditions: [
                GeneratedCondition(kind: .batteryBelow, percent: 30)
            ]
        )

        let result = compiler.compile(generated: generated)
        guard case .ready(let rule) = result else {
            Issue.record("Expected .ready rule, got \(result)")
            return
        }

        #expect(rule.when == .all([
            .powerSource(.battery),
            .batteryPercent(.below, value: 30, hysteresis: nil)
        ]))
    }

    @Test func batteryNorm_2_anyWithThresholdAndThermal() {
        let compiler = RuleCompiler()
        let generated = GeneratedRule(
            name: "Test 2",
            targetApps: ["Docker"],
            actions: [.eCore],
            match: .any,
            conditions: [
                GeneratedCondition(kind: .batteryBelow, percent: 30),
                GeneratedCondition(kind: .thermalAtLeast, thermal: .serious)
            ]
        )

        let result = compiler.compile(generated: generated)
        guard case .ready(let rule) = result else {
            Issue.record("Expected .ready rule, got \(result)")
            return
        }

        #expect(rule.when == .any([
            .all([
                .batteryPercent(.below, value: 30, hysteresis: nil),
                .powerSource(.battery)
            ]),
            .thermal(atLeast: .serious)
        ]))
    }

    @Test func batteryNorm_3_anyWithTwoDistinctThresholds() {
        let compiler = RuleCompiler()
        let generated = GeneratedRule(
            name: "Test 3",
            targetApps: ["Slack"],
            actions: [.eCore],
            match: .any,
            conditions: [
                GeneratedCondition(kind: .batteryBelow, percent: 30),
                GeneratedCondition(kind: .batteryBelow, percent: 20)
            ]
        )

        let result = compiler.compile(generated: generated)
        guard case .ready(let rule) = result else {
            Issue.record("Expected .ready rule, got \(result)")
            return
        }

        #expect(rule.when == .any([
            .all([
                .batteryPercent(.below, value: 30, hysteresis: nil),
                .powerSource(.battery)
            ]),
            .all([
                .batteryPercent(.below, value: 20, hysteresis: nil),
                .powerSource(.battery)
            ])
        ]))
    }

    @Test func batteryNorm_4_anyWithThresholdAndAC_needsClarification() {
        let compiler = RuleCompiler()
        let generated = GeneratedRule(
            name: "Test 4",
            targetApps: ["Chrome"],
            actions: [.eCore],
            match: .any,
            conditions: [
                GeneratedCondition(kind: .batteryBelow, percent: 30),
                GeneratedCondition(kind: .onAC)
            ]
        )

        let result = compiler.compile(generated: generated)
        guard case .needsClarification(_, let questions) = result else {
            Issue.record("Expected .needsClarification, got \(result)")
            return
        }

        #expect(questions.contains { $0.question.contains("Pil eşiği yalnız pildeyken mi geçerli olsun?") })
    }

    @Test func batteryNorm_5_explicitOnBattery_noChange() {
        let compiler = RuleCompiler()
        let generated = GeneratedRule(
            name: "Test 5",
            targetApps: ["Chrome"],
            actions: [.eCore],
            match: .all,
            conditions: [
                GeneratedCondition(kind: .onBattery),
                GeneratedCondition(kind: .batteryBelow, percent: 30)
            ]
        )

        let result = compiler.compile(generated: generated)
        guard case .ready(let rule) = result else {
            Issue.record("Expected .ready rule, got \(result)")
            return
        }

        // Must not duplicate powerSource(battery)
        #expect(rule.when == .all([
            .powerSource(.battery),
            .batteryPercent(.below, value: 30, hysteresis: nil)
        ]))

        // Also test batteryAtOrAbove is NOT normalized
        let genAtOrAbove = GeneratedRule(
            name: "Test 5b",
            targetApps: ["Chrome"],
            actions: [.eCore],
            match: .all,
            conditions: [
                GeneratedCondition(kind: .batteryAtOrAbove, percent: 80)
            ]
        )
        let resAtOrAbove = compiler.compile(generated: genAtOrAbove)
        guard case .ready(let ruleAtOrAbove) = resAtOrAbove else {
            Issue.record("Expected .ready rule, got \(resAtOrAbove)")
            return
        }
        #expect(ruleAtOrAbove.when == .batteryPercent(.atOrAbove, value: 80, hysteresis: nil))
    }

    // MARK: - 3. Hysteresis (No Flapping Around Threshold)

    @Test func leafHysteresis_batteryPercentBelow_noFlapping() async {
        let chromeKey = AppKey(kind: .bundleID, value: "com.google.Chrome")
        let rule = Rule(
            id: UUID(),
            name: "Low Battery Rule",
            enabled: true,
            source: .manual,
            when: .batteryPercent(.below, value: 30, hysteresis: 3),
            targets: .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Chrome")]),
            actions: [.eCore(whileFrontmost: .release)],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let engine = RuleEngine(rules: [rule])

        // 1. Initial battery at 35% on battery -> inactive
        var context = RuleContext(
            powerSource: .battery,
            batteryPercent: 35,
            thermalLevel: .nominal,
            now: Date()
        )
        var eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)

        // 2. Battery drops to 30% -> strictly < 30 is false, still inactive
        context.batteryPercent = 30
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)

        // 3. Battery drops to 29% -> < 30 is true, becomes active!
        context.batteryPercent = 29
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)

        // 4. Battery rises back to 30% -> hysteresis: 30 < 30 + 3 = 33, STAYS ACTIVE!
        context.batteryPercent = 30
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)

        // 5. Battery rises to 31% -> STAYS ACTIVE!
        context.batteryPercent = 31
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)

        // 6. Battery rises to 32% -> STAYS ACTIVE!
        context.batteryPercent = 32
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)

        // 7. Battery rises to 33% -> >= 33 reached, turns OFF!
        context.batteryPercent = 33
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)

        // 8. Battery drops to 32% -> was false, must be < 30 to turn back on!
        context.batteryPercent = 32
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)

        // 9. Battery drops to 28% -> turns back on!
        context.batteryPercent = 28
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)
    }

    // MARK: - 4. Conflict Resolution & Manual Override

    @Test func conflictOrder_freezeWinsOverECore_withVetoFallback() {
        let effect = DesiredEffect(
            freeze: FreezeParams(minHiddenSeconds: 600),
            eCore: ECoreParams(whileFrontmost: .release),
            origins: [
                .freeze: [.rule(UUID())],
                .eCore: [.rule(UUID())]
            ]
        )

        // Natural order: none < eCore < freeze
        #expect(effect.highestEffect == .freeze)

        // If freeze is vetoed, eCore applies
        let vetoingFreeze: Set<Effect> = [.freeze]
        #expect(effect.effectiveEffect(vetoing: vetoingFreeze) == .eCore)

        // If both are vetoed, none applies
        let vetoingBoth: Set<Effect> = [.freeze, .eCore]
        #expect(effect.effectiveEffect(vetoing: vetoingBoth) == .none)
    }

    @Test func manualOverride_suppressesRuleUntilInactive() async {
        let chromeKey = AppKey(kind: .bundleID, value: "com.google.Chrome")
        let ruleID = UUID()
        let rule = Rule(
            id: ruleID,
            name: "Battery Rule",
            enabled: true,
            source: .manual,
            when: .powerSource(.battery),
            targets: .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Chrome")]),
            actions: [.eCore(whileFrontmost: .release)],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let engine = RuleEngine(rules: [rule])

        // 1. On battery -> Rule is active, Chrome has E-core
        var context = RuleContext(
            powerSource: .battery,
            batteryPercent: 50,
            thermalLevel: .nominal,
            now: Date()
        )
        var eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)

        // 2. User manually overrides Chrome
        await engine.recordManualOverride(for: chromeKey)

        // Next evaluation with same conditions: suppressed! Chrome has no E-core
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)

        // 3. Power changes to AC -> Rule becomes inactive
        context.powerSource = .ac
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)
        let state = await engine.getRuleState(id: ruleID)
        #expect(state == .inactive)

        // 4. Power changes back to Battery -> Rule becomes active again, suppression CLEARED!
        context.powerSource = .battery
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)
    }

    @Test func multipleRulesTargetingSameApp_remainsActiveUntilLastRuleDrops() async {
        let chromeKey = AppKey(kind: .bundleID, value: "com.google.Chrome")
        let rule1 = Rule(
            id: UUID(),
            name: "R1 Battery",
            enabled: true,
            source: .manual,
            when: .powerSource(.battery),
            targets: .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Chrome")]),
            actions: [.eCore(whileFrontmost: .release)],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )
        let rule2 = Rule(
            id: UUID(),
            name: "R2 Thermal",
            enabled: true,
            source: .manual,
            when: .thermal(atLeast: .serious),
            targets: .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Chrome")]),
            actions: [.eCore(whileFrontmost: .keep)],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let engine = RuleEngine(rules: [rule1, rule2])

        // Both active
        var context = RuleContext(
            powerSource: .battery,
            batteryPercent: 50,
            thermalLevel: .serious,
            now: Date()
        )
        var eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)
        #expect(eval.desiredState.effects[chromeKey]?.origins[.eCore]?.count == 2)

        // Rule 1 turns inactive (plugged in to AC), but Rule 2 is still active
        context.powerSource = .ac
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey]?.eCore != nil)
        #expect(eval.desiredState.effects[chromeKey]?.origins[.eCore]?.count == 1)

        // Rule 2 also turns inactive (cools down)
        context.thermalLevel = .nominal
        eval = await engine.evaluate(context)
        #expect(eval.desiredState.effects[chromeKey] == nil)
    }

    // MARK: - 5. Deterministic Merge

    @Test func deterministicMerge_freezeMaxAndECoreRelease() async {
        let appKey = AppKey(kind: .bundleID, value: "com.tinyspeck.slackmacgap")

        let r1 = Rule(
            id: UUID(),
            name: "R1",
            enabled: true,
            source: .manual,
            when: .always,
            targets: .apps([AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]),
            actions: [
                .freeze(minHiddenSeconds: 600),
                .eCore(whileFrontmost: .keep)
            ],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let r2 = Rule(
            id: UUID(),
            name: "R2",
            enabled: true,
            source: .manual,
            when: .always,
            targets: .apps([AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]),
            actions: [
                .freeze(minHiddenSeconds: 400),
                .eCore(whileFrontmost: .release)
            ],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let r3 = Rule(
            id: UUID(),
            name: "R3",
            enabled: true,
            source: .manual,
            when: .always,
            targets: .apps([AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]),
            actions: [
                .freeze(minHiddenSeconds: nil) // defaults to 300
            ],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero)
        )

        let engineOrder1 = RuleEngine(rules: [r1, r2, r3])
        let context = RuleContext(powerSource: .battery, batteryPercent: 50, thermalLevel: .nominal, now: Date())
        let eval1 = await engineOrder1.evaluate(context)

        let effect1 = eval1.desiredState.effects[appKey]
        #expect(effect1?.freeze?.minHiddenSeconds == 600) // max(600, 400, 300)
        #expect(effect1?.eCore?.whileFrontmost == .release) // .release wins over .keep

        // Reversing rules order must produce identical result
        let engineOrder2 = RuleEngine(rules: [r3, r2, r1])
        let eval2 = await engineOrder2.evaluate(context)
        let effect2 = eval2.desiredState.effects[appKey]

        #expect(effect1 == effect2)
    }

    // MARK: - 6. Unsupported Never Silently Produces Weaker Rule

    @Test func unsupported_neverProducesWeakerRule() {
        let compiler = RuleCompiler()

        // 1. Model returned unsupported phrase
        let genWithUnsupported = GeneratedRule(
            name: "Unsupported test",
            targetApps: ["Slack"],
            actions: [.freeze],
            match: .all,
            conditions: [GeneratedCondition(kind: .onBattery)],
            unsupported: ["iç içe ve/veya"]
        )
        let res1 = compiler.compile(generated: genWithUnsupported)
        guard case .unsupported(let phrases1) = res1 else {
            Issue.record("Expected .unsupported, got \(res1)")
            return
        }
        #expect(phrases1.contains("iç içe ve/veya"))

        // 2. Unmatched duration in sentence ("10 dakika sonra" without freezeAfterMinutes)
        let genDuration = GeneratedRule(
            name: "Duration test",
            targetApps: ["Slack"],
            actions: [.freeze],
            match: .all,
            conditions: [GeneratedCondition(kind: .onBattery)],
            freezeAfterMinutes: nil // Model forgot to populate freezeAfterMinutes
        )
        let res2 = compiler.compile(
            generated: genDuration,
            rawSentence: "10 dakika sonra Slack'i dondur"
        )
        guard case .unsupported(let phrases2) = res2 else {
            Issue.record("Expected .unsupported, got \(res2)")
            return
        }
        #expect(phrases2.contains { $0.contains("10 dakika") })

        // 3. Out-of-range freezeAfterMinutes (e.g. 2 minutes)
        let genLowMinutes = GeneratedRule(
            name: "Low minutes",
            targetApps: ["Slack"],
            actions: [.freeze],
            match: .all,
            conditions: [GeneratedCondition(kind: .onBattery)],
            freezeAfterMinutes: 2
        )
        let res3 = compiler.compile(generated: genLowMinutes)
        guard case .unsupported = res3 else {
            Issue.record("Expected .unsupported for 2 minutes, got \(res3)")
            return
        }

        // 4. freezeAfterMinutes without freeze action
        let genNoFreezeAction = GeneratedRule(
            name: "No freeze action",
            targetApps: ["Slack"],
            actions: [.eCore],
            match: .all,
            conditions: [GeneratedCondition(kind: .onBattery)],
            freezeAfterMinutes: 10
        )
        let res4 = compiler.compile(generated: genNoFreezeAction)
        guard case .unsupported = res4 else {
            Issue.record("Expected .unsupported for freezeAfterMinutes without freeze action, got \(res4)")
            return
        }
    }

    // MARK: - 7. "Pil %30'un altındayken Chrome'u E-core'a al" from GeneratedRule JSON

    @Test func compile_example1_fromGeneratedRuleJSON() throws {
        let json = """
        {
          "name": "Düşük pilde Chrome E-core",
          "targetApps": ["Chrome"],
          "targetRunaway": false,
          "actions": ["eCore"],
          "match": "all",
          "conditions": [
            { "kind": "batteryBelow", "percent": 30 }
          ],
          "unsupported": []
        }
        """

        let decoder = JSONDecoder()
        let generated = try decoder.decode(GeneratedRule.self, from: Data(json.utf8))
        let compiler = RuleCompiler()

        let fixedUUID = UUID(uuidString: "3F2A7C1E-0B6D-4E8A-9C11-2D5E8F0A6B01")!
        let draft = compiler.compile(
            generated: generated,
            rawSentence: "Pil %30'un altındayken Chrome'u E-core'a al",
            id: fixedUUID
        )

        guard case .ready(let rule) = draft else {
            Issue.record("Expected .ready, got \(draft)")
            return
        }

        #expect(rule.id == fixedUUID)
        #expect(rule.name == "Düşük pilde Chrome E-core")
        #expect(rule.enabled == false) // NL rules default to false
        #expect(rule.source == .naturalLanguage(text: "Pil %30'un altındayken Chrome'u E-core'a al"))
        #expect(rule.when == .all([
            .powerSource(.battery),
            .batteryPercent(.below, value: 30, hysteresis: nil)
        ]))
        #expect(rule.targets == .apps([AppRef(bundleID: "com.google.Chrome", displayName: "Google Chrome")]))
        #expect(rule.actions == [.eCore(whileFrontmost: .release)])
    }

    // MARK: - 8. RuleValidator Tests

    @Test func ruleValidator_enforcesConstraints() {
        // Depth > 3 rejected
        let deepCondition = Condition.all([
            .any([
                .all([
                    .not(.powerSource(.battery))
                ])
            ])
        ])
        let deepRule = Rule(
            name: "Deep",
            source: .manual,
            when: deepCondition,
            targets: .apps([AppRef(displayName: "Slack")]),
            actions: [.eCore()]
        )
        #expect(throws: RuleValidationError.self) {
            try RuleValidator.validate(rule: deepRule)
        }

        // Freeze with allApps rejected
        let freezeAllAppsRule = Rule(
            name: "Freeze all",
            source: .manual,
            when: .always,
            targets: .allApps(except: []),
            actions: [.freeze()]
        )
        #expect(throws: RuleValidationError.self) {
            try RuleValidator.validate(rule: freezeAllAppsRule)
        }

        // Freeze with runaway rejected
        let freezeRunawayRule = Rule(
            name: "Freeze runaway",
            source: .manual,
            when: .always,
            targets: .runaway,
            actions: [.freeze()]
        )
        #expect(throws: RuleValidationError.self) {
            try RuleValidator.validate(rule: freezeRunawayRule)
        }

        // Freeze never-freeze app rejected
        let freezeSystemAppRule = Rule(
            name: "Freeze Finder",
            source: .manual,
            when: .always,
            targets: .apps([AppRef(bundleID: "com.apple.finder", displayName: "Finder")]),
            actions: [.freeze()]
        )
        #expect(throws: RuleValidationError.self) {
            try RuleValidator.validate(rule: freezeSystemAppRule)
        }

        // Freeze Safari allowed (exception in ADR 0004)
        let freezeSafariRule = Rule(
            name: "Freeze Safari",
            source: .manual,
            when: .always,
            targets: .apps([AppRef(bundleID: "com.apple.Safari", displayName: "Safari")]),
            actions: [.freeze()]
        )
        #expect(throws: Never.self) {
            try RuleValidator.validate(rule: freezeSafariRule)
        }
    }

    // MARK: - 9. Edge-Triggered Notify & Cooldown

    @Test func edgeTriggeredNotify_andCooldown() async {
        let rule = Rule(
            id: UUID(),
            name: "Thermal Alert",
            enabled: true,
            source: .manual,
            when: .thermal(atLeast: .serious),
            targets: .apps([AppRef(bundleID: "com.docker.docker", displayName: "Docker")]),
            actions: [.notify(message: "Mac is hot!")],
            options: RuleOptions(activateAfter: .zero, deactivateAfter: .zero, notifyCooldown: .seconds(3600))
        )

        let engine = RuleEngine(rules: [rule])
        let t0 = Date()

        // 1. Nominal -> no notification
        var context = RuleContext(powerSource: .battery, batteryPercent: 50, thermalLevel: .nominal, now: t0)
        var eval = await engine.evaluate(context)
        #expect(eval.notifications.isEmpty)

        // 2. Becomes serious at t0 -> notification fires!
        context.thermalLevel = .serious
        eval = await engine.evaluate(context)
        #expect(eval.notifications.count == 1)
        #expect(eval.notifications[0].message == "Mac is hot!")

        // 3. Stays serious at t0 + 10 min -> no new notification (level-triggered would fire again, edge-triggered does not)
        context.now = t0.addingTimeInterval(600)
        eval = await engine.evaluate(context)
        #expect(eval.notifications.isEmpty)

        // 4. Cools down at t0 + 20 min -> inactive
        context.thermalLevel = .nominal
        context.now = t0.addingTimeInterval(1200)
        eval = await engine.evaluate(context)
        #expect(eval.notifications.isEmpty)

        // 5. Becomes hot again at t0 + 30 min (before 3600s cooldown) -> no notification!
        context.thermalLevel = .serious
        context.now = t0.addingTimeInterval(1800)
        eval = await engine.evaluate(context)
        #expect(eval.notifications.isEmpty)

        // 6. Cools down, then becomes hot after 3600s cooldown at t0 + 4000s -> notification fires!
        context.thermalLevel = .nominal
        context.now = t0.addingTimeInterval(3500)
        _ = await engine.evaluate(context)

        context.thermalLevel = .serious
        context.now = t0.addingTimeInterval(4000)
        eval = await engine.evaluate(context)
        #expect(eval.notifications.count == 1)
    }

    // MARK: - 10. Time Window Over Midnight

    @Test func timeWindow_midnightCrossing() {
        let start = LocalTime(hour: 22, minute: 0)
        let end = LocalTime(hour: 7, minute: 0)
        let weekdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Friday 2026-10-02 23:00 GMT (weekday: Friday)
        var fridayEveningComps = DateComponents(year: 2026, month: 10, day: 2, hour: 23, minute: 0)
        fridayEveningComps.timeZone = cal.timeZone
        let fridayNight = cal.date(from: fridayEveningComps)!
        let (matchFriNight, _) = RuleEngine.evaluateTimeWindow(start: start, end: end, weekdays: weekdays, now: fridayNight, calendar: cal)
        #expect(matchFriNight == true)

        // Saturday 2026-10-03 03:00 GMT (Saturday morning from Friday night window)
        var satMorningComps = DateComponents(year: 2026, month: 10, day: 3, hour: 3, minute: 0)
        satMorningComps.timeZone = cal.timeZone
        let satMorning = cal.date(from: satMorningComps)!
        let (matchSatMorning, _) = RuleEngine.evaluateTimeWindow(start: start, end: end, weekdays: weekdays, now: satMorning, calendar: cal)
        #expect(matchSatMorning == true)

        // Saturday 2026-10-03 23:00 GMT (Saturday night: Saturday is not in weekdays)
        var satNightComps = DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 0)
        satNightComps.timeZone = cal.timeZone
        let satNight = cal.date(from: satNightComps)!
        let (matchSatNight, _) = RuleEngine.evaluateTimeWindow(start: start, end: end, weekdays: weekdays, now: satNight, calendar: cal)
        #expect(matchSatNight == false)

        // Sunday 2026-10-04 03:00 GMT (Sunday morning from Saturday night: Saturday was not in weekdays)
        var sunMorningComps = DateComponents(year: 2026, month: 10, day: 4, hour: 3, minute: 0)
        sunMorningComps.timeZone = cal.timeZone
        let sunMorning = cal.date(from: sunMorningComps)!
        let (matchSunMorning, _) = RuleEngine.evaluateTimeWindow(start: start, end: end, weekdays: weekdays, now: sunMorning, calendar: cal)
        #expect(matchSunMorning == false)
    }
}
