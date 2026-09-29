import SwiftUI
import AppKit
import OhmModel

public struct PopoverHeaderView: View {
    @Bindable var store: OhmStore
    @Environment(\.locale) private var locale

    public init(store: OhmStore) {
        self.store = store
    }

    private var liveWatts: Double {
        store.systemPower.systemLoad ?? (store.systemPower.cpuP + store.systemPower.cpuE + (store.systemPower.gpu ?? 0))
    }

    private var thermalColor: Color {
        switch store.thermalLevel {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private var thermalTooltip: String {
        switch store.thermalLevel {
        case .nominal: return OhmFormatters.localizedString("Thermal state: Nominal", locale: locale)
        case .fair: return OhmFormatters.localizedString("Thermal state: Fair", locale: locale)
        case .serious: return OhmFormatters.localizedString("Thermal state: Serious", locale: locale)
        case .critical: return OhmFormatters.localizedString("Thermal state: Critical", locale: locale)
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Live Watts
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.accentColor)
                Text("\(String(format: "%.1f", liveWatts)) W")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(String(format: "%.1f", liveWatts)) Watts system power")

            Spacer()

            // P/E Cluster Bars
            if let cluster = store.systemPower.clusterActive {
                ClusterBarView(residency: cluster)
            } else {
                ClusterBarView(residency: ClusterResidency(pActiveRatio: 0.1, eActiveRatio: 0.3))
            }

            Spacer()

            // Thermal Indicator
            Image(systemName: "thermometer.medium")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(thermalColor)
                .help(thermalTooltip)
                .accessibilityLabel(thermalTooltip)

            // Settings Button
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OhmFormatters.localizedString("Settings…", locale: locale))
        }
    }
}

public struct BatteryStatusLineView: View {
    @Bindable var store: OhmStore
    @Environment(\.locale) private var locale

    public init(store: OhmStore) {
        self.store = store
    }

    private var batteryIconName: String {
        let percent = store.batteryState.percent
        if store.batteryState.isCharging {
            return "battery.100.bolt"
        }
        if percent > 80 { return "battery.100" }
        if percent > 60 { return "battery.75" }
        if percent > 35 { return "battery.50" }
        if percent > 15 { return "battery.25" }
        return "battery.0"
    }

    private var batteryText: String {
        let pct = "\(store.batteryState.percent)%"
        if store.batteryState.isCharging {
            return "\(pct) · \(OhmFormatters.localizedString("Charging", locale: locale))"
        }
        if let minutes = store.batteryForecastMinutes {
            let forecastStr = OhmFormatters.formatDuration(minutes: minutes, locale: locale)
            return "\(pct) · \(forecastStr) \(OhmFormatters.localizedString("remaining", locale: locale))"
        }
        return pct
    }

    private var accessibilityString: String {
        let pct = "\(store.batteryState.percent) percent battery"
        if store.batteryState.isCharging {
            return "\(pct), charging"
        }
        if let minutes = store.batteryForecastMinutes {
            let wideTime = OhmFormatters.formatAccessibilityDuration(minutes: minutes, locale: locale)
            if locale.identifier.starts(with: "tr") {
                return "% \(store.batteryState.percent) pil, \(wideTime) kaldı"
            } else {
                return "\(pct), \(wideTime) remaining"
            }
        }
        return pct
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: batteryIconName)
                .font(.system(size: 12))
                .foregroundColor(store.batteryState.percent <= 20 ? .red : .secondary)

            Text(batteryText)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)

            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityString)
    }
}
