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
    @Bindable var store: OhmStore

    var body: some View {
        Form {
            Section(header: Text(String(localized: "Sampling interval"))) {
                LabeledContent(String(localized: "Active (popover open)")) {
                    Text("1 s")
                        .foregroundColor(.secondary)
                }
                LabeledContent(String(localized: "Ambient (popover closed)")) {
                    Text("10 s")
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
                    .accessibilityLabel("Toggle launch at login")

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
                        .accessibilityLabel("Toggle rule \(rule.name)")

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
                        .accessibilityLabel("Delete rule \(rule.name)")
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                TextField(String(localized: "Describe a rule…"), text: $newRuleText)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
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
            title = "E-core"
            tint = .blue
        case .freeze:
            title = "Freeze"
            tint = .cyan
        case .notify:
            title = "Notify"
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
    @Bindable var store: OhmStore
    @State private var newAppName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Never-Freeze List")
                .font(.headline)

            Text("Applications in this list will never be frozen by Ohm, protecting ongoing audio, screen shares, and critical workers.")
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
                        .accessibilityLabel("Remove \(app) from never freeze list")
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                TextField("Add app name…", text: $newAppName)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
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
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Ohm")
                .font(.title.bold())

            Text("Energy and core governor for Apple Silicon")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Version 0.0.1 (1)")
                .font(.footnote)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 240)

            VStack(spacing: 4) {
                Text("MIT License · Open Source")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Link("github.com/kuarezma/ohm", destination: URL(string: "https://github.com/kuarezma/ohm")!)
                    .font(.footnote)
            }

            Text("100% on-device telemetry. Zero background wakeups.")
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
