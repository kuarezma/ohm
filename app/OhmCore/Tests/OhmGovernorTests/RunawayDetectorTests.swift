import Foundation
import OhmGovernor
import OhmModel
import Testing

@Suite("RunawayDetector")
struct RunawayDetectorTests {
    private let app = AppKey(kind: .bundleID, value: "com.example.worker")

    private func visibility(
        policy: RunawayActivationPolicy = .regular, frontmost: Bool = false,
        visible: Bool = false, hidden: Bool = true, bundled: Bool = true,
        path: String = "/Applications/Worker.app", present: Bool = true
    ) -> VisibilitySnapshot {
        VisibilitySnapshot(apps: present ? [app: AppVisibility(
            displayName: "Worker", processes: [ProcessIdentity(pid: 42, startAbs: 1)],
            activationPolicy: policy, isFrontmost: frontmost, hasVisibleWindows: visible,
            isHidden: hidden, isBundled: bundled, executablePaths: [path]
        )] : [:])
    }

    private func tick(_ seconds: Int, cpu: Double = 0.8, now: Double = 600,
                      asleep: Int = 0, pids: [Int32] = [42]) -> SampleTick {
        SampleTick(wallClock: Date(timeIntervalSince1970: now), interval: .seconds(seconds),
                   system: SystemPower(cpuP: 0, cpuE: 0),
                   battery: BatteryState(source: .ac, percent: 100, voltage_mV: 0, amperage_mA: 0),
                   thermal: .nominal,
                   processes: pids.map { ProcessDelta(identity: ProcessIdentity(pid: $0, startAbs: 1),
                       app: app, energy_nJ: 0, pEnergy_nJ: 0,
                       cpuTime_ns: UInt64(Double(seconds) * cpu * 1e9)) },
                   unreadable: UnreadableSummary(readableCount: pids.count, unreadableCount: 0),
                   asleep: .seconds(asleep))
    }

    @Test func exactTenMinuteBoundaryAndAggregation() async throws {
        let detector = RunawayDetector()
        #expect(await detector.observe(tick: tick(599, cpu: 0.4, pids: [42, 43]), visibility: visibility()).isEmpty)
        var snapshot = visibility()
        snapshot.apps[app]?.processes.append(ProcessIdentity(pid: 43, startAbs: 1))
        let events = await detector.observe(tick: tick(1, cpu: 0.4, pids: [42, 43]), visibility: snapshot)
        guard case .started(let runaway) = try #require(events.first) else { Issue.record("Missing start"); return }
        #expect(runaway.pids == [42, 43])
        #expect(runaway.averageCPU == 0.8)
        #expect(runaway.hiddenDuration == .seconds(600))
        #expect(runaway.actions.contains(.eCore))
        #expect(runaway.response(to: .eCore) == .commands([.eCore(pid: 42, on: true, origin: .runaway)]))
    }

    @Test func hysteresisAndSingleStart() async {
        let detector = RunawayDetector()
        #expect(await detector.observe(tick: tick(600), visibility: visibility()).count == 1)
        #expect(await detector.observe(tick: tick(119, cpu: 0.1), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(10), visibility: visibility()).isEmpty)
        #expect(await detector.currentRunaways.count == 1)
        #expect(await detector.observe(tick: tick(120, cpu: 0.29), visibility: visibility()) == [.ended(app)])
        #expect(await detector.currentRunaways.isEmpty)
        #expect(await detector.observe(tick: tick(600), visibility: visibility()).count == 1)
    }

    @Test func interruptedHighCPUResetsStartAndEndThresholdIsStrict() async {
        let detector = RunawayDetector()
        _ = await detector.observe(tick: tick(599), visibility: visibility())
        _ = await detector.observe(tick: tick(1, cpu: 0.79), visibility: visibility())
        #expect(await detector.observe(tick: tick(599), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(1), visibility: visibility()).count == 1)
        #expect(await detector.observe(tick: tick(120, cpu: 0.3), visibility: visibility()).isEmpty)
    }

    @Test func visibilityAndDisappearanceEndImmediately() async {
        let snapshots = [
            visibility(frontmost: true), visibility(visible: true, hidden: false), visibility(present: false)
        ]
        for snapshot in snapshots {
            let detector = RunawayDetector()
            _ = await detector.observe(tick: tick(600), visibility: visibility())
            #expect(await detector.observe(tick: tick(1), visibility: snapshot) == [.ended(app)])
        }
    }

    @Test func sleepDoesNotCountOrReset() async {
        let mixedTickDetector = RunawayDetector()
        _ = await mixedTickDetector.observe(tick: tick(300), visibility: visibility())
        #expect(await mixedTickDetector.observe(tick: tick(1, asleep: 300), visibility: visibility()).isEmpty)
        #expect(await mixedTickDetector.observe(tick: tick(299), visibility: visibility()).count == 1)
        let detector = RunawayDetector()
        _ = await detector.observe(tick: tick(599), visibility: visibility())
        #expect(await detector.observe(tick: tick(0, cpu: 0, asleep: 3600, pids: []), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(1, asleep: 100), visibility: visibility()).count == 1)
        _ = await detector.observe(tick: tick(119, cpu: 0), visibility: visibility())
        _ = await detector.observe(tick: tick(0, cpu: 0, asleep: 100), visibility: visibility())
        #expect(await detector.observe(tick: tick(1, cpu: 0), visibility: visibility()) == [.ended(app)])
    }

    @Test func missingCPUCountsAsZero() async {
        let detector = RunawayDetector()
        _ = await detector.observe(tick: tick(600), visibility: visibility())
        #expect(await detector.observe(tick: tick(119, pids: []), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(1, pids: []), visibility: visibility()) == [.ended(app)])
    }

    @Test func configurableThresholdsAndLiveIgnoreUpdate() async throws {
        let detector = RunawayDetector(config: RunawayConfig(
            startCPU: 0.5, startDuration: .seconds(2), endCPU: 0.2, endDuration: .seconds(3)))
        #expect(await detector.observe(tick: tick(1, cpu: 0.5), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(1, cpu: 0.5), visibility: visibility()).count == 1)
        #expect(await detector.observe(tick: tick(1, cpu: 0.1), visibility: visibility()).isEmpty)
        let runaway = try #require(await detector.currentRunaways[app])
        #expect(abs(runaway.averageCPU - 1.1 / 3) < 1e-12)
        #expect(runaway.hiddenDuration == .seconds(3))
        #expect(await detector.setConfig(RunawayConfig(ignoredApps: [app])) == [.ended(app)])
        #expect(await detector.currentRunaways.isEmpty)
    }

    @Test func exclusionsAndIgnoreList() async {
        for path in ["/System/Library/Worker", "/usr/libexec/worker", "/usr/sbin/worker"] {
            let detector = RunawayDetector()
            #expect(await detector.observe(tick: tick(600), visibility: visibility(path: path)).isEmpty)
        }
        for name in ["dev.ohm.Ohm", "dev.ohm.helper", "ohm-thawd", "kernel_task", "WindowServer", "launchd"] {
            let key = AppKey(kind: .processName, value: name)
            var sample = tick(600)
            sample.processes[0].app = key
            var snapshot = visibility()
            snapshot.apps[key] = snapshot.apps.removeValue(forKey: app)
            #expect(await RunawayDetector().observe(tick: sample, visibility: snapshot).isEmpty)
        }
        let detector = RunawayDetector(config: RunawayConfig(ignoredApps: [app]))
        #expect(await detector.observe(tick: tick(600), visibility: visibility()).isEmpty)
    }

    @Test func snoozeEndsAndExpires() async {
        let detector = RunawayDetector()
        _ = await detector.observe(tick: tick(600), visibility: visibility())
        #expect(await detector.snooze(app, now: Date(timeIntervalSince1970: 600)) == [.ended(app)])
        #expect(await detector.observe(tick: tick(600, now: 4199), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(1, now: 4200), visibility: visibility()).isEmpty)
        #expect(await detector.observe(tick: tick(599, now: 4799), visibility: visibility()).count == 1)
    }

    @Test func backgroundFreezeRequiresConfirmation() async throws {
        let snapshots = [visibility(policy: .accessory), visibility(policy: .prohibited), visibility(bundled: false)]
        for snapshot in snapshots {
            let detector = RunawayDetector()
            let events = await detector.observe(tick: tick(600), visibility: snapshot)
            guard case .started(let runaway) = try #require(events.first) else {
                Issue.record("Missing start"); continue
            }
            #expect(runaway.actions.contains(.freeze(requiresConfirmation: true)))
            #expect(runaway.response(to: .freeze(requiresConfirmation: false)) == .openCard(app))
            #expect(runaway.actions.contains(.quit))
            #expect(RunawayAction.quit.isDestructive)
        }
        let detector = RunawayDetector()
        let events = await detector.observe(tick: tick(600), visibility: visibility())
        guard case .started(let runaway) = try #require(events.first) else { Issue.record("Missing start"); return }
        #expect(runaway.response(to: .freeze(requiresConfirmation: false)) ==
                .commands([.freeze(pid: 42, origin: .runaway, confirmedBackground: false)]))
    }
}
