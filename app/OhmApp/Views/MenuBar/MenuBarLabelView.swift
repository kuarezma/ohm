import SwiftUI
import OhmModel

public struct MenuBarLabelView: View {
    @Bindable var store: OhmStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: OhmStore) {
        self.store = store
    }

    private var liveWatts: Double {
        store.systemPower.systemLoad ?? (store.systemPower.cpuP + store.systemPower.cpuE + (store.systemPower.gpu ?? 0))
    }

    private var thermalColor: Color {
        switch store.thermalLevel {
        case .nominal:
            return .green
        case .fair:
            return .yellow
        case .serious:
            return .orange
        case .critical:
            return .red
        }
    }

    private var thermalName: String {
        switch store.thermalLevel {
        case .nominal: return String(localized: "Thermal state: Nominal")
        case .fair: return String(localized: "Thermal state: Fair")
        case .serious: return String(localized: "Thermal state: Serious")
        case .critical: return String(localized: "Thermal state: Critical")
        }
    }

    private var wattFraction: Double {
        // Typical Apple Silicon range: 0 to 35W normalized
        min(max(liveWatts / 35.0, 0.08), 1.0)
    }

    public var body: some View {
        HStack(spacing: 5) {
            switch store.menuBarDisplayMode {
            case .ringAndWatts:
                wattRing
                wattText
            case .ringOnly:
                wattRing
            case .wattsOnly:
                wattText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ohm: \(String(format: "%.1f", liveWatts)) W, \(thermalName)")
    }

    private var wattRing: some View {
        ZStack {
            Circle()
                .stroke(thermalColor.opacity(0.28), lineWidth: 2.2)

            Circle()
                .trim(from: 0, to: wattFraction)
                .stroke(
                    thermalColor,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: wattFraction)
        }
        .frame(width: 14, height: 14)
    }

    private var wattText: some View {
        Text("\(String(format: "%.1f", liveWatts))W")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}
