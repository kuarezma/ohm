import Foundation
import OhmLedger
import OhmModel
import SQLite3
import Testing
@testable import OhmSampling

@Suite("T-029 acceptance")
struct BackpressureTests {
    @Test func stalledConsumerRetainsTenThousandTicksInFourDeliveries() async throws {
        let clocks = FakeClocks()
        let engine = SamplingEngine(
            process: FakeProcessSampler(deltas: [delta(pid: 1, energy: 1_000_000_000, p: 500_000_000)]),
            component: FakeComponent(gpuWatts: 1, gpuInterval: .seconds(1)),
            systemLoad: FakeLoad(calls: CallCounter()), battery: FakeBattery(calls: CallCounter()),
            clocks: clocks.sampling)
        _ = await engine.sampleNow()
        for _ in 0..<10_000 {
            clocks.run(.seconds(1))
            clocks.sleep(.milliseconds(1))
            _ = await engine.sampleNow()
        }
        #expect(await engine.pendingTickCount == 4)
        await engine.stop()
        var iterator = engine.ticks.makeAsyncIterator()
        var interval = Duration.zero
        var asleep = Duration.zero
        var energy: UInt64 = 0
        var pEnergy: UInt64 = 0
        var gpuEnergy = 0.0, loadEnergy = 0.0, cpuPEnergy = 0.0, cpuEEnergy = 0.0
        for _ in 0..<4 {
            let tick = try #require(await iterator.next())
            interval += tick.interval
            asleep += tick.asleep
            energy += tick.processes.reduce(0) { $0 + $1.energy_nJ }
            pEnergy += tick.processes.reduce(0) { $0 + $1.pEnergy_nJ }
            gpuEnergy += (tick.system.gpu ?? 0) * TickCoalescer.seconds(tick.system.gpuInterval ?? tick.interval)
            loadEnergy += (tick.system.systemLoad ?? 0) * TickCoalescer.seconds(tick.interval)
            cpuPEnergy += tick.system.cpuP * TickCoalescer.seconds(tick.interval)
            cpuEEnergy += tick.system.cpuE * TickCoalescer.seconds(tick.interval)
        }
        #expect(interval == .seconds(10_000))
        #expect(asleep == .seconds(10))
        #expect(energy == 10_000_000_000_000)
        #expect(pEnergy == 5_000_000_000_000)
        #expect(abs(gpuEnergy - 10_000) <= 10_000 * 1e-9)
        #expect(abs(loadEnergy - 38_000) <= 38_000 * 1e-9)
        #expect(abs(cpuPEnergy - 5_000) <= 5_000 * 1e-9)
        #expect(abs(cpuEEnergy - 5_000) <= 5_000 * 1e-9)
        #expect(await engine.pendingTickCount == 0)
        clocks.run(.seconds(1))
        _ = await engine.sampleNow()
        #expect(try #require(await iterator.next()).interval == .seconds(1))
    }


    private func tick(_ end: Double, load: Double? = 2, source: PowerSourceKind = .ac,
                      systemSource: SystemEnergySource = .systemLoad) -> SampleTick {
        SampleTick(wallClock: Date(timeIntervalSince1970: end), interval: .seconds(1),
            system: SystemPower(cpuP: 1, cpuE: 2, gpu: 3, systemLoad: load,
                                systemSource: systemSource, gpuInterval: .milliseconds(500)),
            battery: BatteryState(source: source, percent: 80, voltage_mV: 12_000, amperage_mA: -100),
            thermal: .nominal,
            processes: [ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 1),
                app: AppKey(kind: .executableName, value: "test"), energy_nJ: 1_000_000_000,
                pEnergy_nJ: 500_000_000, cpuTime_ns: 700_000_000)],
            unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 0))
    }

    @Test func mergerPreservesIdentitySleepAndLatestState() {
        var older = tick(60), newer = tick(61, load: nil, systemSource: .none)
        older.asleep = .seconds(10)
        newer.asleep = .seconds(20)
        newer.thermal = .serious
        newer.battery.percent = 70
        newer.processes.append(ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 2),
            app: AppKey(kind: .executableName, value: "new"), energy_nJ: 3, pEnergy_nJ: 1, cpuTime_ns: 2))
        older.burst = EnergyBurst(window: DateInterval(start: Date(timeIntervalSince1970: 50), duration: 10), cpu_mJ: 2)
        newer.burst = EnergyBurst(window: DateInterval(start: Date(timeIntervalSince1970: 60), duration: 1), cpu_mJ: 3)
        let merged = TickCoalescer.merge(older, newer)
        #expect(merged.interval == .seconds(2) && merged.asleep == .seconds(30))
        #expect(merged.wallClock == newer.wallClock && merged.battery == newer.battery)
        #expect(merged.thermal == .serious && merged.burst == newer.burst)
        #expect(merged.processes.count == 2)
        #expect(merged.processes[0].energy_nJ == 2_000_000_000)
        #expect(merged.processes[0].cpuTime_ns == 1_400_000_000)
        #expect(merged.system.gpu == 3 && merged.system.gpuInterval == .seconds(1))
        #expect(merged.system.systemLoadCoverage == .seconds(1))
        #expect(merged.system.effectiveEnergyJ == 2)
        older.system.gpu = nil
        let partialGPU = TickCoalescer.merge(older, newer)
        #expect(partialGPU.system.gpu == 3 && partialGPU.system.gpuInterval == .milliseconds(500))
    }

    @Test func sameSourcePairIsPreferredAndFallbackStaysOrdered() async throws {
        let buffer = TickBuffer(capacity: 3)
        buffer.offer(tick(1, source: .ac))
        buffer.offer(tick(2, source: .battery))
        buffer.offer(tick(3, source: .battery))
        buffer.offer(tick(4, source: .ac))
        #expect(buffer.count == 3)
        #expect(try #require(await buffer.next()).wallClock.timeIntervalSince1970 == 1)
        let merged = try #require(await buffer.next())
        #expect(merged.interval == .seconds(2) && merged.wallClock.timeIntervalSince1970 == 3)
        #expect(try #require(await buffer.next()).wallClock.timeIntervalSince1970 == 4)
        let fallback = TickBuffer(capacity: 1)
        fallback.offer(tick(1, source: .battery))
        fallback.offer(tick(2, source: .ac))
        let mixed = try #require(await fallback.next())
        #expect(mixed.interval == .seconds(2) && mixed.battery.source == .ac)
    }

    @Test func caughtUpConsumerReceivesUnmergedTicksInOrder() async throws {
        let buffer = TickBuffer(capacity: 2)
        for i in 1...10 {
            let produced = tick(Double(i))
            buffer.offer(produced)
            let delivered = try #require(await buffer.next())
            #expect(delivered.wallClock == produced.wallClock && delivered.interval == .seconds(1))
            #expect(delivered.system.effectiveCoverage == nil)
        }
    }

    @Test func waitingConsumerReceivesOfferedTick() async throws {
        let buffer = TickBuffer(capacity: 1)
        let task = Task { await buffer.next() }
        await Task.yield()
        buffer.offer(tick(1))
        #expect(try #require(await task.value).interval == .seconds(1))
        #expect(buffer.count == 0)
    }

    @Test func pairPreferenceChecksBothSourceKinds() async throws {
        let buffer = TickBuffer(capacity: 3)
        buffer.offer(tick(1, source: .battery, systemSource: .systemLoad))
        buffer.offer(tick(2, source: .battery, systemSource: .batteryVI))
        buffer.offer(tick(3, source: .battery, systemSource: .systemLoad))
        buffer.offer(tick(4, source: .battery, systemSource: .systemLoad))
        #expect(try #require(await buffer.next()).interval == .seconds(1))
        #expect(try #require(await buffer.next()).interval == .seconds(1))
        #expect(try #require(await buffer.next()).interval == .seconds(2))
    }

    @Test func configuredLimitsBoundEveryOffer() async throws {
        for capacity in [1, 2, 4, 8] {
            let buffer = TickBuffer(capacity: capacity)
            for i in 1...100 {
                buffer.offer(tick(Double(i)))
                #expect(buffer.count <= capacity)
            }
            var interval = Duration.zero
            for _ in 0..<capacity { interval += try #require(await buffer.next()).interval }
            #expect(interval == .seconds(100))
        }
    }

    @Test func cancelledWaiterTerminatesWithoutHanging() async {
        let buffer = TickBuffer(capacity: 1)
        let task = Task { await buffer.next() }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func coalescedLedgerPreservesPartialAndMixedCoverage() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("t029-coverage-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let ledger = try EnergyLedger(path: path)
        // Straddles a minute boundary: measured 2 J / 1 s, missing 1 s on AC.
        let partial = TickCoalescer.merge(tick(60), tick(61, load: nil, systemSource: .none))
        try await ledger.record(partial)
        // Mixed effective SystemLoad and V×I; raw V×I is also retained for both original ticks.
        let mixed = TickCoalescer.merge(tick(62, source: .battery),
            tick(63, load: 1.2, source: .battery, systemSource: .batteryVI))
        try await ledger.record(mixed)
        try await ledger.flush()
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT SUM(sys_uj), SUM(sys_cov_ms), SUM(sys_vi_ms), SUM(sysload_cov_ms), SUM(batt_vi_cov_ms), SUM(att_cov_uj) FROM system_1m", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int64(statement, 0) == 5_200_000)
        #expect(sqlite3_column_int64(statement, 1) == 3_000)
        #expect(sqlite3_column_int64(statement, 2) == 1_000)
        #expect(sqlite3_column_int64(statement, 3) == 2_000)
        #expect(sqlite3_column_int64(statement, 4) == 2_000)
        #expect(sqlite3_column_int64(statement, 5) == 3_000_000)
    }
}
