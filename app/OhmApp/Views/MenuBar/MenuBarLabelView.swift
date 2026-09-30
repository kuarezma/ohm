import SwiftUI
import AppKit
import OhmModel

public struct MenuBarLabelView: View {
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
        case .nominal: return OhmFormatters.localizedString("Thermal state: Nominal", locale: locale)
        case .fair: return OhmFormatters.localizedString("Thermal state: Fair", locale: locale)
        case .serious: return OhmFormatters.localizedString("Thermal state: Serious", locale: locale)
        case .critical: return OhmFormatters.localizedString("Thermal state: Critical", locale: locale)
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
        .accessibilityLabel(OhmFormatters.localizedFormat("Ohm: %@ watts, %@", locale: locale, liveWatts.formatted(.number.precision(.fractionLength(1)).locale(locale)), thermalName))
    }

    private var wattRing: some View {
        // MenuBarExtra extracts an Image from its label; arbitrary Shape views are omitted.
        let color = NSColor(thermalColor)
        let fraction = wattFraction
        let ringImage = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            color.withAlphaComponent(0.28).setStroke()
            let track = NSBezierPath(ovalIn: NSRect(x: 1.1, y: 1.1, width: 11.8, height: 11.8))
            track.lineWidth = 2.2
            track.stroke()

            color.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: 7, y: 7), radius: 5.9,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.stroke()
            return true
        }
        return Image(nsImage: ringImage)
            .renderingMode(.original)
    }

    private var wattText: some View {
        Text(store.isReady ? "\(String(format: "%.1f", liveWatts))W" : "—W")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}
