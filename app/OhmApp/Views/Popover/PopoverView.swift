import SwiftUI
import AppKit
import OhmModel

public struct PopoverView: View {
    @Bindable var store: OhmStore
    @State private var ruleInputText: String = ""
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: OhmStore) {
        self.store = store
    }

    private var activeRulesCount: Int {
        store.rules.filter(\.enabled).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header: System W, P/E cluster bars, Thermal
            PopoverHeaderView(store: store)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            // Battery Line
            BatteryStatusLineView(store: store)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider()

            // Main Content Area
            VStack(alignment: .leading, spacing: 10) {
                // Runaway Card (if reported)
                if let runaway = store.runawayProcess {
                    RunawayCardView(runaway: runaway, store: store)
                }

                // Today's Receipt Header
                HStack {
                    Text(OhmFormatters.localizedString("Today's receipt", locale: locale))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.top, 2)

                // App rows
                if store.todayReceipt.rows.isEmpty {
                    HStack {
                        Spacer()
                        Text(OhmFormatters.localizedString("No apps recorded yet today.", locale: locale))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(store.todayReceipt.rows) { row in
                            ReceiptRowView(row: row, store: store)
                        }

                        OtherHardwareRowView(receipt: store.todayReceipt)
                    }
                }
            }
            .padding(14)

            Divider()

            // Rules Footer
            rulesFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(.regularMaterial)
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView(onDismiss: { store.showOnboarding = false })
        }
    }

    private var rulesFooter: some View {
        HStack(spacing: 8) {
            // Active rules counter button
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("\(activeRulesCount) \(OhmFormatters.localizedString("active", locale: locale))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OhmFormatters.localizedFormat("%lld active rules, click to open settings", locale: locale, activeRulesCount))

            Spacer()

            // Describe a rule input (hidden when NL unavailable)
            if store.isNLAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)

                    TextField(OhmFormatters.localizedString("Describe a rule…", locale: locale), text: $ruleInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit {
                            submitRule()
                        }

                    if !ruleInputText.isEmpty {
                        Button(action: submitRule) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(OhmFormatters.localizedString("Add rule", locale: locale))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .frame(maxWidth: 180)
            }
        }
    }

    private func submitRule() {
        let trimmed = ruleInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addRule(description: trimmed)
        ruleInputText = ""
    }
}

// MARK: - Previews

#Preview("Popover - Normal") {
    PopoverView(store: OhmStore(dataSource: PreviewDataSource.normal))
}

#Preview("Popover - Thermal Warning") {
    PopoverView(store: OhmStore(dataSource: PreviewDataSource.hotThermal))
}

#Preview("Popover - Runaway App") {
    PopoverView(store: OhmStore(dataSource: PreviewDataSource.runaway))
}

#Preview("Popover - Empty State") {
    PopoverView(store: OhmStore(dataSource: PreviewDataSource.empty))
}
