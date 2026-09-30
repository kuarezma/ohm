import SwiftUI
import AppKit

public struct WidgetSmallView: View {
    public let data: ReceiptWidgetData
    @Environment(\.locale) private var locale

    public init(data: ReceiptWidgetData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(WidgetFormatter.localized("Today's receipt", locale: locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            // Top 3 Apps
            VStack(spacing: 5) {
                ForEach(Array(data.topApps.prefix(3).enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 5) {
                        Image(systemName: "\(index + 1).circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))

                        Text(app.displayName)
                            .font(.system(size: 12, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Text(WidgetFormatter.formatAppValue(app, locale: locale, compact: true))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WidgetFormatter.appAccessibilityLabel(app, rank: index + 1, locale: locale))
                }
            }

            Spacer(minLength: 2)

            Divider()
                .padding(.vertical, 3)

            // Total row
            HStack {
                Text(WidgetFormatter.localized("Total", locale: locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                Text(WidgetFormatter.formatTotalValue(data, locale: locale, compact: true))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetFormatter.totalAccessibilityLabel(data, locale: locale))
        }
        .padding(10)
    }
}

public struct WidgetMediumView: View {
    public let data: ReceiptWidgetData
    @Environment(\.locale) private var locale

    public init(data: ReceiptWidgetData) {
        self.data = data
    }

    public var body: some View {
        HStack(spacing: 14) {
            // Left Column: Total Summary
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.batteryblock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(WidgetFormatter.localized("Today's receipt", locale: locale))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(WidgetFormatter.formatTotalValue(data, locale: locale, compact: false))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(WidgetFormatter.totalCaption(data, locale: locale))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 116, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetFormatter.totalAccessibilityLabel(data, locale: locale))

            Divider()
                .padding(.vertical, 2)

            // Right Column: Top 3 Apps
            VStack(spacing: 7) {
                ForEach(Array(data.topApps.prefix(3).enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 6) {
                        Image(systemName: "\(index + 1).circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))

                        Text(app.displayName)
                            .font(.system(size: 12, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 6)

                        Text(WidgetFormatter.formatAppValue(app, locale: locale, compact: false))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WidgetFormatter.appAccessibilityLabel(app, rank: index + 1, locale: locale))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }
}

public struct WidgetEmptyView: View {
    @Environment(\.locale) private var locale

    public let storageUnavailable: Bool
    public init(storageUnavailable: Bool = false) { self.storageUnavailable = storageUnavailable }
    private var message: String {
        storageUnavailable ? "No widget data in this build" : "No data yet — open Ohm"
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(WidgetFormatter.localized(message, locale: locale))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetFormatter.localized(message, locale: locale))
    }
}
