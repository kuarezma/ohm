import Foundation
import OhmModel
import Testing
@testable import OhmSampling

@Suite struct IOReportDecoderTests {
    @Test(arguments: [("mJ", 1e-3), ("uJ", 1e-6), ("nJ", 1e-9), ("J", 1.0)])
    func energyUnits(label: String, factor: Double) {
        #expect(IOReportDecoder.joulesPerUnit(label) == factor)
    }

    @Test func nonEnergyUnitsAreRejected() {
        #expect(IOReportDecoder.joulesPerUnit("") == nil)
        #expect(IOReportDecoder.joulesPerUnit("mW") == nil)
    }

    @Test func decodesM3ChannelLayout() {
        let channels = [
            IOReportChannel(group: "Energy Model", name: "GPU Energy", unit: "nJ", value: 19_327_749),
            IOReportChannel(group: "Energy Model", name: "GPU", unit: "mJ", value: 99),     // sparse, ignored
            IOReportChannel(group: "Energy Model", name: "PCPU", unit: "mJ", value: 77),    // cluster, ignored
            IOReportChannel(group: "Energy Model", name: "CPU Energy", unit: "mJ", value: 1_500),
            IOReportChannel(group: "Energy Model", name: "DRAM", unit: "mJ", value: 250),
            IOReportChannel(group: "Energy Model", name: "ANE", unit: "mJ", value: 0),
            IOReportChannel(group: "Energy Model", name: "Weird", unit: "furlong", value: 5),
            IOReportChannel(group: "CPU Stats", name: "PCPU0", unit: "", value: 0, residency: (30, 100)),
            IOReportChannel(group: "CPU Stats", name: "PCPU1", unit: "", value: 0, residency: (10, 100)),
            IOReportChannel(group: "CPU Stats", name: "ECPU0", unit: "", value: 0, residency: (100, 100)),
        ]
        let r = IOReportDecoder.decode(channels)
        #expect(abs(r.gpuJ! - 0.019327749) < 1e-12)
        #expect(abs(r.cpuJ - 1.5) < 1e-12)
        #expect(abs(r.dramJ - 0.25) < 1e-12)
        #expect(r.aneJ == 0)
        #expect(r.residency == ClusterResidency(pActiveRatio: 0.2, eActiveRatio: 1.0))
    }

    @Test func missingChannelsGiveNil() {
        let r = IOReportDecoder.decode([])
        #expect(r.gpuJ == nil && r.residency == nil)
    }

    @Test func firstBurstIsDiscardedSecondCoversWindow() {
        var catcher = BurstCatcher()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var quiet = IOReportReading()
        quiet.dramJ = 0.1                                         // DRAM published separately
        #expect(catcher.observe(quiet, at: t0) == nil)
        var first = IOReportReading()
        first.cpuJ = 2
        #expect(catcher.observe(first, at: t0.addingTimeInterval(4)) == nil)   // window start unknown
        #expect(catcher.observe(quiet, at: t0.addingTimeInterval(30)) == nil)
        var second = IOReportReading()
        second.cpuJ = 5.5
        second.dramJ = 0.4
        second.aneJ = 0.01
        let burst = catcher.observe(second, at: t0.addingTimeInterval(60))
        #expect(burst?.window == DateInterval(start: t0.addingTimeInterval(4), end: t0.addingTimeInterval(60)))
        #expect(burst?.cpu_mJ == 5_500)
        #expect(abs((burst?.dram_mJ ?? 0) - 500) < 1e-9)          // 0.1 pending + 0.4
        #expect(abs((burst?.ane_mJ ?? 0) - 10) < 1e-9)
    }
}

@Suite struct BatteryMappingTests {
    let onBattery = SmartBatterySnapshot(externalConnected: false, isCharging: false, voltage_mV: 12_000,
                                         amperage_mA: -500, currentCapacity: 79, maxCapacity: 100,
                                         remainingCapacity_mAh: 3_318, fullChargeCapacity_mAh: 4_223,
                                         systemLoad_mW: 7_430, updateTime: 1_000)

    @Test func systemLoadPreferredOnBattery() {
        let r = BatteryMapping.systemLoad(onBattery, nowUnix: 1_012)
        #expect(r.watts == 7.43 && r.source == .systemLoad && r.age == .seconds(12))
    }

    @Test func viFallbackOnlyWhileDischarging() {
        var s = onBattery
        s.systemLoad_mW = nil
        let r = BatteryMapping.systemLoad(s, nowUnix: 1_000)
        #expect(r.source == .batteryVI && abs(r.watts! - 6.0) < 1e-12)

        s.externalConnected = true                          // on AC V × I is charger power
        s.amperage_mA = 1_500
        let ac = BatteryMapping.systemLoad(s, nowUnix: 1_000)
        #expect(ac.watts == nil && ac.source == SystemEnergySource.none)
    }

    @Test func systemLoadValidOnAC() {
        var s = onBattery
        s.externalConnected = true
        s.amperage_mA = 0
        #expect(BatteryMapping.systemLoad(s, nowUnix: 1_000).source == .systemLoad)
    }

    @Test func noBattery() {
        #expect(BatteryMapping.state(nil) == .unavailable)
        #expect(BatteryMapping.systemLoad(nil, nowUnix: 0).source == SystemEnergySource.none)
    }

    @Test func stateMapping() {
        let st = BatteryMapping.state(onBattery)
        #expect(st.source == .battery && st.percent == 79 && st.voltage_mV == 12_000 && st.amperage_mA == -500)
        #expect(st.systemLoad_mW == 7_430 && st.rawCurrentCapacity_mAh == 3_318 && st.fullChargeCapacity_mAh == 4_223)
    }

    @Test func thermalMapping() {
        #expect(ThermalSampler.map(.nominal) == .nominal)
        #expect(ThermalSampler.map(.critical) == .critical)
        #expect(ThermalLevel.fair < .serious)
    }
}
