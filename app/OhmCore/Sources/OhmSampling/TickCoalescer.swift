import Foundation
import OhmModel

/// Pure, chronological aggregation. No original tick history is retained.
enum TickCoalescer {
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func measured(_ tick: SampleTick) -> SystemPower {
        var power = tick.system
        guard power.effectiveCoverage == nil else { return power }
        let load = (power.systemSource == .systemLoad ? power.systemLoad : nil)
            ?? tick.battery.systemLoad_mW.map { Double($0) / 1000 }
        let discharging = tick.battery.source == .battery && !tick.battery.isCharging
        let vi: Double? = discharging
            ? (power.systemSource == .batteryVI ? power.systemLoad : nil)
                ?? Double(tick.battery.voltage_mV) * abs(Double(tick.battery.amperage_mA)) / 1e6
            : nil
        power.systemLoadCoverage = load == nil ? .zero : tick.interval
        power.batteryVICoverage = vi == nil ? .zero : tick.interval
        power.systemLoadEnergyJ = load.map { $0 * seconds(tick.interval) }
        power.batteryVIEnergyJ = vi.map { $0 * seconds(tick.interval) }
        power.effectiveEnergyJ = (load ?? vi).map { $0 * seconds(tick.interval) }
        power.effectiveCoverage = load == nil && vi == nil ? .zero : tick.interval
        power.effectiveVICoverage = load == nil && vi != nil ? tick.interval : .zero
        return power
    }

    static func merge(_ older: SampleTick, _ newer: SampleTick) -> SampleTick {
        var result = newer
        result.interval = older.interval + newer.interval
        result.asleep = older.asleep + newer.asleep
        let duration = seconds(result.interval)
        let a = measured(older), b = measured(newer)
        func sum(_ x: Double?, _ y: Double?) -> Double? {
            x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0)
        }
        result.system.cpuP = duration > 0
            ? (a.cpuP * seconds(older.interval) + b.cpuP * seconds(newer.interval)) / duration : 0
        result.system.cpuE = duration > 0
            ? (a.cpuE * seconds(older.interval) + b.cpuE * seconds(newer.interval)) / duration : 0
        let gpuDuration = (a.gpu == nil ? Duration.zero : a.gpuInterval ?? older.interval)
            + (b.gpu == nil ? Duration.zero : b.gpuInterval ?? newer.interval)
        let gpuEnergy = sum(a.gpu.map { $0 * seconds(a.gpuInterval ?? older.interval) },
                            b.gpu.map { $0 * seconds(b.gpuInterval ?? newer.interval) })
        result.system.gpuInterval = gpuDuration
        result.system.gpu = gpuEnergy.map { seconds(gpuDuration) > 0 ? $0 / seconds(gpuDuration) : 0 }
        result.system.systemLoadCoverage = (a.systemLoadCoverage ?? .zero) + (b.systemLoadCoverage ?? .zero)
        result.system.batteryVICoverage = (a.batteryVICoverage ?? .zero) + (b.batteryVICoverage ?? .zero)
        result.system.systemLoadEnergyJ = sum(a.systemLoadEnergyJ, b.systemLoadEnergyJ)
        result.system.batteryVIEnergyJ = sum(a.batteryVIEnergyJ, b.batteryVIEnergyJ)
        result.system.effectiveEnergyJ = sum(a.effectiveEnergyJ, b.effectiveEnergyJ)
        result.system.effectiveCoverage = (a.effectiveCoverage ?? .zero) + (b.effectiveCoverage ?? .zero)
        result.system.effectiveVICoverage = (a.effectiveVICoverage ?? .zero) + (b.effectiveVICoverage ?? .zero)
        result.system.systemLoad = result.system.effectiveEnergyJ.map { duration > 0 ? $0 / duration : 0 }
        result.burst = newer.burst ?? older.burst
        var indices: [ProcessIdentity: Int] = [:]
        result.processes = older.processes
        for (index, process) in result.processes.enumerated() { indices[process.identity] = index }
        for process in newer.processes {
            if let index = indices[process.identity] {
                let previous = result.processes[index]
                var combined = process
                combined.energy_nJ += previous.energy_nJ
                combined.pEnergy_nJ += previous.pEnergy_nJ
                combined.cpuTime_ns += previous.cpuTime_ns
                result.processes[index] = combined
            } else {
                indices[process.identity] = result.processes.count
                result.processes.append(process)
            }
        }
        return result
    }
}
