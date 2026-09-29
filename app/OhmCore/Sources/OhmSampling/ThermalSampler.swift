import Foundation
import OhmModel

/// `ProcessInfo.thermalState` → `ThermalLevel`.
public enum ThermalSampler {
    public static func map(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }

    @Sendable public static func current() -> ThermalLevel { map(ProcessInfo.processInfo.thermalState) }
}
