import Foundation
import OhmModel
import Synchronization
import Testing
@testable import OhmSampling

extension Tag {
    /// Touches the real kernel / IOReport. Skipped when `CI` or `OHM_SKIP_INTEGRATION` is set.
    @Tag static var integration: Self
}

let integrationEnabled = ProcessInfo.processInfo.environment["CI"] == nil
    && ProcessInfo.processInfo.environment["OHM_SKIP_INTEGRATION"] == nil

final class FakeCounterSource: ProcessCounterSource {
    var clock: UInt64 = 1_000_000
    var table: [Int32: ProcessReadResult] = [:]
    var reads: [Int32: Int] = [:]

    func now() -> UInt64 { clock }
    func listPIDs() -> [Int32] { table.keys.sorted() }
    func read(_ pid: Int32) -> ProcessReadResult {
        reads[pid, default: 0] += 1
        return table[pid] ?? .gone
    }

    func set(_ pid: Int32, energy: UInt64, p: UInt64 = 0, cpu: UInt64 = 0, start: UInt64 = 10) {
        table[pid] = .counters(ProcessCounters(energy_nJ: energy, pEnergy_nJ: p, cpuTicks: cpu, startAbs: start))
    }
}

final class FakeMetadata: ProcessMetadataSource {
    var paths: [Int32: String] = [:]
    var names: [Int32: String] = [:]
    var responsible: [Int32: Int32] = [:]
    var alive: Set<Int32> = []
    var bundles: [String: BundleInfo] = [:]
    var spiAvailable = true
    var pathCalls = 0

    func path(of pid: Int32) -> String? { pathCalls += 1; return paths[pid] }
    func name(of pid: Int32) -> String? { names[pid] }
    func responsiblePID(of pid: Int32) -> Int32? { spiAvailable ? responsible[pid] ?? pid : nil }
    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) || paths[pid] != nil }
    func bundleInfo(appPath: String) -> BundleInfo? { bundles[appPath] }
}

/// Sendable call counter that a test keeps while the fake itself is sent into the engine.
final class CallCounter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

final class FakeProcessSampler: ProcessEnergySampling {
    let deltas: [ProcessDelta]
    init(deltas: [ProcessDelta]) { self.deltas = deltas }
    func sample() -> (deltas: [ProcessDelta], unreadable: UnreadableSummary) {
        (deltas, UnreadableSummary(readable: deltas.count, unreadable: 3, vanished: 0))
    }
}

final class FakeComponent: ComponentSampling {
    func sample() -> (gpuWatts: Double?, residency: ClusterResidency?, burst: EnergyBurst?) {
        (0.25, ClusterResidency(pActive: 0.5, eActive: 0.25), nil)
    }
}

final class FakeLoad: SystemLoadSampling {
    let calls: CallCounter
    init(calls: CallCounter) { self.calls = calls }
    func read() -> (watts: Double?, source: SystemEnergySource, age: Duration?) {
        calls.bump()
        return (3.8, .systemLoad, .seconds(4))
    }
}

final class FakeBattery: BatterySampling {
    let calls: CallCounter
    init(calls: CallCounter) { self.calls = calls }
    func read() -> BatteryState {
        calls.bump()
        return BatteryState(source: .battery, percent: 80, voltage_mV: 12_400, amperage_mA: -300,
                            systemLoad_mW: 3_800, rawCurrentCapacity_mAh: 3_300,
                            fullChargeCapacity_mAh: 4_200, isCharging: false)
    }
}

func delta(pid: Int32, energy: UInt64, p: UInt64) -> ProcessDelta {
    ProcessDelta(identity: ProcessIdentity(pid: pid, startAbsTime: 1), app: AppKey(kind: .executableName, value: "x\(pid)"),
                 displayName: "x", bundlePath: nil, category: .userApp, energy_nJ: energy, pEnergy_nJ: p, cpuTime_ns: 0)
}
