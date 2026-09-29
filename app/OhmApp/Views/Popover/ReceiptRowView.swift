import SwiftUI
import AppKit
import OhmModel

public struct ReceiptRowView: View {
    public let row: ReceiptAppRow
    @Bindable var store: OhmStore
    @Environment(\.locale) private var locale

    public init(row: ReceiptAppRow, store: OhmStore) {
        self.row = row
        self.store = store
    }

    private var isECoreActive: Bool {
        store.activeEffects[row.appKey] == .eCore
    }

    private var isFrozen: Bool {
        store.activeEffects[row.appKey] == .freeze
    }

    private var formattedMinutes: String {
        guard let minutes = row.batteryMinutes else { return "" }
        return OhmFormatters.formatDuration(minutes: minutes, locale: locale)
    }

    private var accessibilityBatteryText: String {
        guard let minutes = row.batteryMinutes else { return "" }
        return OhmFormatters.formatBatteryAccessibility(minutes: minutes, locale: locale)
    }

    public var body: some View {
        HStack(spacing: 8) {
            // App Icon
            AppIconView(
                bundleID: row.appKey.kind == .bundleID ? row.appKey.value : nil,
                executablePath: row.bundlePath,
                appName: row.displayName,
                size: 20
            )

            // App Name
            Text(row.displayName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Battery Minutes
            if !formattedMinutes.isEmpty {
                Text(formattedMinutes)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .accessibilityLabel(accessibilityBatteryText)
            }

            // [E] Button
            Button(action: {
                store.toggleECore(for: row.appKey)
            }) {
                Text("E")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isECoreActive ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    )
                    .foregroundColor(isECoreActive ? .white : .primary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(isECoreActive ? 0 : 0.15), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isECoreActive ? OhmFormatters.localizedFormat("Remove %@ from efficiency cores", locale: locale, row.displayName) : OhmFormatters.localizedFormat("Move %@ to efficiency cores", locale: locale, row.displayName))

            // [❄] Button
            Button(action: {
                store.toggleFreeze(for: row.appKey)
            }) {
                Image(systemName: "snowflake")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isFrozen ? Color.cyan : Color(nsColor: .controlBackgroundColor))
                    )
                    .foregroundColor(isFrozen ? .white : .primary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(isFrozen ? 0 : 0.15), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFrozen ? OhmFormatters.localizedFormat("Unfreeze %@", locale: locale, row.displayName) : OhmFormatters.localizedFormat("Freeze %@", locale: locale, row.displayName))
        }
        .padding(.vertical, 2)
    }
}

public struct OtherHardwareRowView: View {
    public let receipt: Receipt
    @Environment(\.locale) private var locale

    public init(receipt: Receipt) {
        self.receipt = receipt
    }

    private var otherMinutes: Double {
        if let pRef = receipt.pRefWatts, pRef > 0, receipt.other_uj > 0 {
            return Double(receipt.other_uj) * 1e-6 / pRef / 60.0
        }
        return 120.0 // Default 2 hours fallback for preview
    }

    private var formattedTime: String {
        OhmFormatters.formatDuration(minutes: otherMinutes, locale: locale)
    }

    private var accessibilityText: String {
        OhmFormatters.formatBatteryAccessibility(minutes: otherMinutes, locale: locale)
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "display.and.hardware")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)

            HStack(spacing: 4) {
                Text(OhmFormatters.localizedString("Other (display, radios)", locale: locale))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)

                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .help(OhmFormatters.localizedString("Power consumed by built-in display, Wi-Fi, Bluetooth, and non-attributed system hardware.", locale: locale))

            Spacer()

            Text(formattedTime)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .accessibilityLabel(accessibilityText)
        }
        .padding(.vertical, 2)
    }
}
