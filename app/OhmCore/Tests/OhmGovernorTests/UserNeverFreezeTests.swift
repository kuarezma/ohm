import Darwin
import Foundation
import OhmGovernor
import OhmJournal
import OhmModel
import Testing

@Suite("Rev 1 — setUserNeverFreeze regression tests")
struct UserNeverFreezeTests {
    @Test("setUserNeverFreeze: (a) new rule freeze gets .userNeverList veto, (b) active freeze is thawed, (c) E-core is preserved")
    func testSetUserNeverFreezeSemantics() async throws {
        let bag = ProcessBag()
        defer { #expect(bag.cleanup().isEmpty, "spawned processes survived teardown") }

        let rig = try Rig("t035-neverfreeze") { $0.minHiddenFloor = 0 }
        let pid = bag.spawn("/bin/sleep", ["120"])
        let bundleID = "com.apple.TextEdit"
        let key = AppKey.bundle(bundleID)

        rig.apps.add(appInfo(pid, bundleID: bundleID), hidden: true)

        // 1. Initial reconcile: apply both freeze and E-core via rule to TextEdit
        let initialDesired = DesiredState(effects: [
            key: DesiredEffect(
                freeze: FreezeParams(minHiddenSeconds: 0),
                eCore: ECoreParams(whileFrontmost: .keep),
                origins: [
                    .freeze: [.rule(UUID())],
                    .eCore: [.rule(UUID())]
                ]
            )
        ])
        let initialReport = await rig.gov.reconcile(initialDesired)
        let initialFrozenPids = await rig.gov.frozenRootPids
        let initialECorePids = await rig.gov.eCoreRootPids
        #expect(isFrozen(initialReport.outcomes[key] ?? .notFound), "TextEdit should be frozen initially")
        #expect(initialFrozenPids.contains(pid), "Governor should record pid as frozen root")
        #expect(initialECorePids.contains(pid), "Governor should record pid as eCore root")

        // 2. User adds TextEdit to never-freeze list
        await rig.gov.setUserNeverFreeze([bundleID])

        // (b) active freeze is thawed immediately
        let postFrozenPids = await rig.gov.frozenRootPids
        #expect(!isT(pid), "Process should no longer be stopped (SIGCONT sent)")
        #expect(!postFrozenPids.contains(pid), "Governor should no longer have pid in frozenRootPids")

        // (c) E-core is preserved
        let postECorePids = await rig.gov.eCoreRootPids
        #expect(postECorePids.contains(pid), "Governor must preserve E-core for pid")

        // (a) new rule freeze gets .userNeverList veto
        let newFreezeDesired = DesiredState(effects: [
            key: DesiredEffect(
                freeze: FreezeParams(minHiddenSeconds: 0),
                origins: [.freeze: [.rule(UUID())]]
            )
        ])
        let subsequentReport = await rig.gov.reconcile(newFreezeDesired)
        let outcome = subsequentReport.outcomes[key] ?? .notFound
        #expect(vetoes(outcome).contains(.userNeverList), "New rule freeze should be vetoed with .userNeverList, got: \(outcome)")
    }
}
