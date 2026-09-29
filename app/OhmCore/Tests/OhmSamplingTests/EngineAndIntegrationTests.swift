import Foundation
import OhmModel
import Testing
@testable import OhmSampling
import OhmLedger

@Suite struct SamplingEngineTests {
    @Test func tickAssemblySplitsPAndEWatts() {
        let deltas = [delta(pid: 1, energy: 3_000_000_000, p: 2_000_000_000),
                      delta(pid: 2, energy: 1_000_000_000, p: 0)]
        let tick = SamplingEngine.makeTick(
            wallClock: Date(), interval: .seconds(2), deltas: deltas,
            unreadable: UnreadableSummary(readableCount: 2, unreadableCount: 1),
            component: (0.5, .seconds(2), nil, nil), systemLoad: (4, .systemLoad, .seconds(3)),
            battery: .unavailable, thermal: .nominal)
        #expect(tick.system.cpuP == 1.0)   // 2 J / 2 s
        #expect(tick.system.cpuE == 1.0)   // (1 J + 1 J) / 2 s
        #expect(tick.system.gpu == 0.5 && tick.system.systemLoad == 4)
        #expect(tick.processes.count == 2 && tick.unreadable.unreadableCount == 1)
    }

    @Test func zeroIntervalDoesNotDivideByZero() {
        let tick = SamplingEngine.makeTick(
            wallClock: Date(), interval: .zero, deltas: [delta(pid: 1, energy: 10, p: 5)],
            unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 0),
            component: (nil, nil, nil, nil), systemLoad: (nil, .none, nil), battery: .unavailable, thermal: .nominal)
        #expect(tick.system.cpuP == 0 && tick.system.cpuE == 0)
    }

    @Test func cadenceIntervals() {
        #expect(SamplingEngine.interval(for: .interactive) == .seconds(1))
        #expect(SamplingEngine.interval(for: .ambient) == .seconds(10))
        #expect(SamplingEngine.interval(for: .suspended) == nil)
    }

    @Test func firstCallPrimesAndSlowSourcesAreThrottled() async {
        let loadCalls = CallCounter(), batteryCalls = CallCounter()
        let engine = SamplingEngine(process: FakeProcessSampler(deltas: [delta(pid: 1, energy: 1_000, p: 500)]),
                                    component: FakeComponent(), systemLoad: FakeLoad(calls: loadCalls),
                                    battery: FakeBattery(calls: batteryCalls), thermal: { .fair })
        #expect(await engine.sampleNow() == nil)
        let tick = await engine.sampleNow()
        _ = await engine.sampleNow()
        _ = await engine.sampleNow()
        #expect(tick?.thermal == .fair)
        #expect(tick?.battery.percent == 80)
        #expect(tick?.system.systemSource == .systemLoad)
        #expect(tick?.system.clusterActive == ClusterResidency(pActiveRatio: 0.5, eActiveRatio: 0.25))
        #expect((tick?.system.systemLoadAge ?? .zero) >= .seconds(4))
        #expect(loadCalls.count == 1 && batteryCalls.count == 1)  // three ticks within 10 s → one read
        #expect(await engine.tickCount == 3)
    }

    // T-024 #8: a tick that spans system sleep must report awake time as its interval, so that
    // power × interval stays energy (1 W for 1 s awake + 1 h asleep is 1 J, not 3601 J).
    func sleepyTick() async throws -> SampleTick {
        let clocks = FakeClocks()
        let engine = SamplingEngine(
            process: FakeProcessSampler(deltas: [delta(pid: 1, energy: 2_000_000_000, p: 1_000_000_000)]),
            component: FakeComponent(gpuWatts: 1, gpuInterval: .seconds(1)),
            systemLoad: FakeLoad(calls: CallCounter()), battery: FakeBattery(calls: CallCounter()),
            clocks: clocks.sampling)
        _ = await engine.sampleNow()
        clocks.run(.milliseconds(500))
        clocks.sleep(.seconds(3600))
        clocks.run(.milliseconds(500))
        return try #require(await engine.sampleNow())
    }

    @Test func sleepInsideTickIsNotCountedAsMeasuredTime() async throws {
        let tick = try await sleepyTick()
        #expect(tick.interval == .seconds(1))
        #expect(tick.asleep == .seconds(3600))
        #expect(tick.system.cpuP == 1.0 && tick.system.cpuE == 1.0)  // 1 J each over 1 s awake
        #expect(tick.system.gpuInterval == .seconds(1))
    }

    @Test func sleepSpanningTickDoesNotInflateLedgerEnergy() async throws {
        let tick = try await sleepyTick()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("t021_sleep_\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let ledger = try EnergyLedger(path: path)
        try await ledger.record(tick)
        try await ledger.flush()
        let receipt = try LedgerReader(path: path).receipt(
            for: DateInterval(start: tick.wallClock.addingTimeInterval(-7200), end: tick.wallClock.addingTimeInterval(120)))
        #expect(receipt.gpu_uj == 1_000_000)                    // 1 W × 1 s, not × 3601 s
        #expect(receipt.measuredSystemEnergy_uj == 3_800_000)   // SystemLoad 3.8 W × 1 s awake
    }

    @Test func leavingSuspendedWakesTheLoopImmediately() async throws {
        let engine = SamplingEngine(process: FakeProcessSampler(deltas: []), component: FakeComponent(),
                                    systemLoad: FakeLoad(calls: CallCounter()),
                                    battery: FakeBattery(calls: CallCounter()), cadence: .suspended)
        await engine.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await engine.tickCount == 0)
        let clock = ContinuousClock()
        let t0 = clock.now
        await engine.setCadence(.interactive)
        var iterator = engine.ticks.makeAsyncIterator()
        let tick = await iterator.next()
        #expect(tick != nil)
        #expect(clock.now - t0 < .milliseconds(800))  // woke up, did not wait for the 1 s nap
        await engine.stop()
    }
}

@Suite(.tags(.integration), .enabled(if: integrationEnabled), .serialized)
struct LiveIntegrationTests {
    /// Spawns its own `yes` (the only process this test signals) and expects it on top.
    @Test func ownYesIsTopConsumer() async throws {
        let yes = Process()
        yes.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        yes.standardOutput = FileHandle.nullDevice
        try yes.run()
        defer {
            yes.terminate()
            yes.waitUntilExit()
        }
        let sampler = ProcessEnergySampler()
        _ = sampler.sample()                            // baseline (yes already running)
        try await Task.sleep(for: .milliseconds(1500))
        let (deltas, summary) = sampler.sample()
        let top = try #require(deltas.max { $0.energy_nJ < $1.energy_nJ })
        #expect(top.identity.pid == yes.processIdentifier)
        #expect(top.app == AppKey(kind: .executableName, value: "yes"))
        #expect(top.category == .macOSService)         // /usr/bin
        #expect(Double(top.energy_nJ) / 1.5e9 > 0.5)    // one busy core: watts, not milliwatts
        #expect(top.cpuTime_ns > 1_000_000_000)         // ~1.5 s of CPU in 1.5 s
        #expect(summary.readableCount > 10)
        print("T-021 live: yes \(Double(top.energy_nJ) / 1.5e9) W, readable \(summary.readableCount), EPERM \(summary.unreadableCount), reads \(sampler.lastScanReads)")
    }

    /// ADR 0001 § 1: dlopen must resolve libIOReport from the dyld shared cache.
    @Test func ioreportLoadsViaDlopenAndReportsLiveChannels() async throws {
        var stage: Int32 = -1
        let sampler = try #require(IOReportSampler(error: &stage))
        #expect(stage == 0)
        try await Task.sleep(for: .milliseconds(1100))
        let (gpu, gpuInterval, residency, _) = sampler.sample()
        #expect(gpuInterval != nil)
        #expect(gpu != nil)
        #expect(residency != nil)
        print("T-021 live: gpu \(gpu ?? -1) W, P act \(residency?.pActiveRatio ?? -1), E act \(residency?.eActiveRatio ?? -1)")
    }

    @Test func batteryGaugeReadable() {
        let state = BatterySampler().read()
        let load = SystemLoadSampler().read()
        print("T-021 live: battery \(state), load \(load)")
        if state.source != .unknown { #expect(state.percent > 0) }
    }
}
