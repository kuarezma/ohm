import SwiftUI
import OhmModel

public struct SettingsView: View {
    @Bindable var store: OhmStore

    public init(store: OhmStore) {
        self.store = store
    }

    public var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }

            RulesSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "Rules"), systemImage: "checklist")
                }

            NeverFreezeSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "Never-freeze"), systemImage: "snowflake.slash")
                }

            AboutSettingsView()
                .tabItem {
                    Label(String(localized: "About"), systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: OhmStore

    var body: some View {
        Form {
            Section(header: Text(String(localized: "Sampling interval"))) {
                LabeledContent(String(localized: "Active (popover open)")) {
                    Text(OhmFormatters.localizedString("1 s", locale: locale))
                        .foregroundColor(.secondary)
                }
                LabeledContent(String(localized: "Ambient (popover closed)")) {
                    Text(OhmFormatters.localizedString("10 s", locale: locale))
                        .foregroundColor(.secondary)
                }
                LabeledContent(String(localized: "Suspended (system sleep)")) {
                    Text(String(localized: "Suspended (system sleep)"))
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text(String(localized: "Menu bar display style"))) {
                Picker(String(localized: "Menu bar display style"), selection: $store.menuBarDisplayMode) {
                    Text(String(localized: "Ring and live watts")).tag(MenuBarDisplayMode.ringAndWatts)
                    Text(String(localized: "Ring only")).tag(MenuBarDisplayMode.ringOnly)
                    Text(String(localized: "Watts only")).tag(MenuBarDisplayMode.wattsOnly)
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Toggle(String(localized: "Launch at login"), isOn: $store.launchAtLogin)
                    .accessibilityLabel(OhmFormatters.localizedString("Toggle launch at login", locale: locale))

                Button(String(localized: "Welcome Guide…")) {
                    store.showOnboarding = true
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

// MARK: - Rules Settings

struct RulesSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: OhmStore
    @State private var newRuleText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Rules"))
                    .font(.headline)
                Spacer()
            }

            List {
                ForEach(store.rules) { rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { _ in store.toggleRule(rule) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(OhmFormatters.localizedFormat("Toggle rule %@", locale: locale, rule.name))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .font(.system(size: 13, weight: .medium))

                            HStack(spacing: 4) {
                                ForEach(rule.actions, id: \.self) { action in
                                    actionBadge(for: action)
                                }
                            }
                        }

                        Spacer()

                        Button(role: .destructive, action: {
                            store.deleteRule(rule)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(OhmFormatters.localizedFormat("Delete rule %@", locale: locale, rule.name))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                TextField(String(localized: "Describe a rule…"), text: $newRuleText)
                    .textFieldStyle(.roundedBorder)

                Button(OhmFormatters.localizedString("Add", locale: locale)) {
                    let trimmed = newRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.addRule(description: trimmed)
                    newRuleText = ""
                }
                .disabled(newRuleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private func actionBadge(for action: Action) -> some View {
        let title: String
        let tint: Color
        switch action {
        case .eCore:
            title = OhmFormatters.localizedString("E-core", locale: locale)
            tint = .blue
        case .freeze:
            title = OhmFormatters.localizedString("Freeze", locale: locale)
            tint = .cyan
        case .notify:
            title = OhmFormatters.localizedString("Notify", locale: locale)
            tint = .orange
        }

        return Text(title)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundColor(tint)
    }
}

// MARK: - Never-Freeze Settings

struct NeverFreezeSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: OhmStore
    @State private var newAppName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OhmFormatters.localizedString("Never-Freeze List", locale: locale))
                .font(.headline)

            Text(OhmFormatters.localizedString("Applications in this list will never be frozen by Ohm, protecting ongoing audio, screen shares, and critical workers.", locale: locale))
                .font(.footnote)
                .foregroundColor(.secondary)

            List {
                ForEach(store.neverFreezeApps, id: \.self) { app in
                    HStack {
                        AppIconView(appName: app, size: 18)
                        Text(app)
                            .font(.system(size: 13))
                        Spacer()
                        Button(action: {
                            store.removeNeverFreezeApp(app)
                        }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(OhmFormatters.localizedFormat("Remove %@ from never freeze list", locale: locale, app))
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                TextField(OhmFormatters.localizedString("Add app name…", locale: locale), text: $newAppName)
                    .textFieldStyle(.roundedBorder)

                Button(OhmFormatters.localizedString("Add", locale: locale)) {
                    let trimmed = newAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.addNeverFreezeApp(trimmed)
                    newAppName = ""
                }
                .disabled(newAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Ohm")
                .font(.title.bold())

            Text(OhmFormatters.localizedString("Energy and core governor for Apple Silicon", locale: locale))
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(OhmFormatters.localizedString("Version 0.0.1 (1)", locale: locale))
                .font(.footnote)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 240)

            VStack(spacing: 4) {
                Text(OhmFormatters.localizedString("MIT License · Open Source", locale: locale))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Link("github.com/kuarezma/ohm", destination: URL(string: "https://github.com/kuarezma/ohm")!)
                    .font(.footnote)
            }

            Text(OhmFormatters.localizedString("Telemetry stays on your Mac.", locale: locale))
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

// MARK: - Previews

#Preview("Settings") {
    SettingsView(store: OhmStore(dataSource: PreviewDataSource.normal))
}
