import OhmModel
import Testing
@testable import OhmSampling

@Suite struct ProcessDeltaMathTests {
    let base = ProcessCounters(energy_nJ: 1_000, pEnergy_nJ: 600, cpuTicks: 300, startAbs: 50)

    @Test func continuedIdentityIsPlainDifference() {
        let cur = ProcessCounters(energy_nJ: 4_000, pEnergy_nJ: 2_600, cpuTicks: 900, startAbs: 50)
        let (d, e) = ProcessDeltaMath.step(previous: base, current: cur, previousSampleAbs: 100)
        #expect(e == .continued)
        #expect(d == CounterDelta(energy_nJ: 3_000, pEnergy_nJ: 2_000, cpuTicks: 600))
    }

    @Test func counterGoingBackwardsYieldsZeroAndReset() {
        let cur = ProcessCounters(energy_nJ: 900, pEnergy_nJ: 600, cpuTicks: 400, startAbs: 50)
        let (d, e) = ProcessDeltaMath.step(previous: base, current: cur, previousSampleAbs: 100)
        #expect(e == .counterReset)
        #expect(d == .zero)
    }

    @Test func pidReuseStartedAfterPreviousTickCountsWholeCounter() {
        // Same pid, different start time → new identity that started after the previous scan.
        let reused = ProcessCounters(energy_nJ: 700, pEnergy_nJ: 100, cpuTicks: 30, startAbs: 150)
        let (d, e) = ProcessDeltaMath.step(previous: base, current: reused, previousSampleAbs: 120)
        #expect(e == .started)
        #expect(d == CounterDelta(energy_nJ: 700, pEnergy_nJ: 100, cpuTicks: 30))
    }

    @Test func olderProcessFirstSeenIsBaselineOnly() {
        let cur = ProcessCounters(energy_nJ: 9_999, pEnergy_nJ: 1, cpuTicks: 1, startAbs: 10)
        #expect(ProcessDeltaMath.step(previous: nil, current: cur, previousSampleAbs: 120) == (.zero, .baseline))
        // First scan ever (Ohm just started): nothing before Ohm is billed to today.
        #expect(ProcessDeltaMath.step(previous: nil, current: cur, previousSampleAbs: nil) == (.zero, .baseline))
    }

    @Test func pShareIsClampedToTotal() {
        let cur = ProcessCounters(energy_nJ: 1_100, pEnergy_nJ: 800, cpuTicks: 300, startAbs: 50)
        let (d, _) = ProcessDeltaMath.step(previous: base, current: cur, previousSampleAbs: 100)
        #expect(d.energy_nJ == 100 && d.pEnergy_nJ == 100)
    }

    @Test func machTicksToNanosecondsM3Ratio() {
        let tb = MachTimebase(numer: 125, denom: 3)
        #expect(tb.nanoseconds(24_000_000) == 1_000_000_000)  // 24 MHz tick → 1 s
        #expect(tb.nanoseconds(1) == 41)
        #expect(tb.nanoseconds(UInt64.max / 125) > 0)            // no overflow trap
        #expect(abs(tb.seconds(24_000_000) - 1.0) < 1e-12)
    }
}

@Suite struct ProcessEnergySamplerTests {
    func makeSampler(_ src: FakeCounterSource, meta: FakeMetadata = FakeMetadata()) -> ProcessEnergySampler {
        ProcessEnergySampler(source: src, resolver: AttributionResolver(meta: meta),
                             timebase: MachTimebase(numer: 1, denom: 1))
    }

    @Test func firstScanIsBaselineThenDeltas() {
        let src = FakeCounterSource()
        src.set(10, energy: 5_000, p: 5_000, cpu: 100)
        let s = makeSampler(src)
        #expect(s.sample().deltas.isEmpty)
        src.clock += 1_000
        src.set(10, energy: 9_000, p: 8_000, cpu: 400)
        let (deltas, summary) = s.sample()
        #expect(deltas.count == 1)
        #expect(deltas[0].energy_nJ == 4_000 && deltas[0].pEnergy_nJ == 3_000 && deltas[0].cpuTime_ns == 300)
        #expect(summary == UnreadableSummary(readable: 1, unreadable: 0, vanished: 0))
    }

    @Test func idleProcessesAreNotEmitted() {
        let src = FakeCounterSource()
        src.set(10, energy: 5_000)
        let s = makeSampler(src)
        _ = s.sample()
        src.clock += 1_000
        let (deltas, summary) = s.sample()
        #expect(deltas.isEmpty)
        #expect(summary.readable == 1)
    }

    @Test func epermIsCountedAndNotRetriedWhileAlive() {
        let src = FakeCounterSource()
        src.table[1] = .denied
        src.set(20, energy: 1)
        let s = makeSampler(src)
        for _ in 0..<3 {
            let (_, summary) = s.sample()
            #expect(summary.unreadable == 1 && summary.readable == 1)
            src.clock += 1_000
        }
        #expect(src.reads[1] == 1)       // one syscall, then skipped
        #expect(s.lastScanReads == 1)    // only pid 20 read
    }

    @Test func epermPidIsRetriedAfterItExits() {
        let src = FakeCounterSource()
        src.table[1] = .denied
        let s = makeSampler(src)
        _ = s.sample()
        src.table[1] = nil                // exits
        _ = s.sample()
        src.set(1, energy: 50, start: 5)  // pid reused by a readable process
        let (_, summary) = s.sample()
        #expect(summary.readable == 1 && summary.unreadable == 0)
        #expect(src.reads[1] == 2)
    }

    @Test func epermPidIsRetriedAfterRefreshInterval() {
        let src = FakeCounterSource()
        src.table[1] = .denied
        let s = makeSampler(src)  // timebase 1:1 → clock is nanoseconds
        _ = s.sample()
        src.clock += 301_000_000_000
        _ = s.sample()
        #expect(src.reads[1] == 2)
    }

    @Test func goneBetweenListAndReadIsVanished() {
        let src = FakeCounterSource()
        src.table[7] = .gone
        let (_, summary) = makeSampler(src).sample()
        #expect(summary == UnreadableSummary(readable: 0, unreadable: 0, vanished: 1))
    }

    @Test func pidReuseBetweenTicksBillsNewProcessFromZero() {
        let src = FakeCounterSource()
        src.set(30, energy: 10_000, start: 10)
        let s = makeSampler(src)
        _ = s.sample()                       // previousSampleAbs = 1_000_000
        src.clock += 1_000
        src.set(30, energy: 2_500, start: 1_000_500)  // old one died, pid reused mid-interval
        let (deltas, _) = s.sample()
        #expect(deltas.count == 1)
        #expect(deltas[0].energy_nJ == 2_500)
        #expect(deltas[0].identity == ProcessIdentity(pid: 30, startAbsTime: 1_000_500))
    }

    @Test func deltasCarryAttribution() {
        let src = FakeCounterSource()
        let meta = FakeMetadata()
        meta.paths[40] = "/opt/homebrew/Cellar/node/22.1.0/bin/node"
        src.set(40, energy: 0)
        let s = makeSampler(src, meta: meta)
        _ = s.sample()
        src.clock += 1_000
        src.set(40, energy: 3_000)
        let d = s.sample().deltas[0]
        #expect(d.app == AppKey(kind: .executableName, value: "node"))
        #expect(d.category == .userApp)
    }
}
