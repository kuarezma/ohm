import SwiftUI
import AppKit
import OhmModel

public struct SettingsView: View {
    @Bindable var store: OhmStore

    public init(store: OhmStore) {
        self.store = store
    }

    public var body: some View {
        TabView(selection: $store.settingsTab) {
            GeneralSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
                .tag("general")

            RulesSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "Rules"), systemImage: "checklist")
                }
                .tag("rules")

            NeverFreezeSettingsView(store: store)
                .tabItem {
                    Label(String(localized: "Never-freeze"), systemImage: "snowflake.slash")
                }
                .tag("neverFreeze")

            AboutSettingsView()
                .tabItem {
                    Label(String(localized: "About"), systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 480)
        .frame(minHeight: 400, idealHeight: 440)
        .onAppear { store.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLoginStatus()
        }
        .onChange(of: store.rules.count) { previous, current in
            if current > previous { store.ruleInputText = "" }
        }
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView(onDismiss: { store.showOnboarding = false })
        }
        .sheet(item: $store.pendingRule) { rule in
            RuleReviewView(rule: rule, store: store)
                .interactiveDismissDisabled(store.isRuleBusy)
        }
        .alert("Ayar değiştirilemedi", isPresented: Binding(
            get: { store.preferenceError != nil },
            set: { if !$0 { store.preferenceError = nil } }
        )) {
            Button("Tamam") { store.preferenceError = nil }
        } message: { Text(store.preferenceError ?? "") }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: OhmStore

    var body: some View {
        Form {
            if (store.dataSource as? LiveDataSource)?.isLocalStorage == true {
                Text("Yerel depolama: enerji fişi ve komut satırı çalışır; widget için imzalı App Group gerekir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                if store.loginNeedsApproval {
                    Button("Sistem Ayarları’nda izin ver…") { store.openLoginSettings() }
                    Text("Otomatik açılış macOS onayını bekliyor.").font(.caption)
                }

                Button(String(localized: "Welcome Guide…")) {
                    store.showOnboarding = true
                }
                HStack {
                    Button("Tüm etkileri geri al") { store.thawAll() }
                        .disabled(store.activeEffects.isEmpty)
                    Spacer()
                    Button("Ohm’dan çık") { NSApp.terminate(nil) }
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
                            if let reason = store.vetoReason(for: rule) {
                                Text(reason).font(.caption).foregroundStyle(.orange)
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
                TextField(String(localized: "Describe a rule…"), text: $store.ruleInputText)
                    .textFieldStyle(.roundedBorder)

                Button(OhmFormatters.localizedString("Add", locale: locale)) {
                    let trimmed = store.ruleInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.addRule(description: trimmed)
                }
                .disabled(store.ruleInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.isNLAvailable || store.isRuleBusy)
            }
            .disabled(store.isRuleBusy)
            if store.isRuleBusy { ProgressView("Kural hazırlanıyor…").controlSize(.small) }
            ForEach(store.ruleAppChoices) { choice in
                Menu("\(choice.id): uygulamayı seç…") {
                    ForEach(choice.apps, id: \.self) { app in
                        Button("\(app.displayName) (\(app.bundleID ?? ""))") {
                            store.selectRuleApp(app, for: choice.id)
                        }
                    }
                }
            }
            if let message = store.ruleMessage {
                Text(message).font(.caption).textSelection(.enabled)
            } else if !store.isNLAvailable {
                Text("Doğal dil kuralları Apple Intelligence ve hazır cihaz içi model gerektirir. Mevcut kuralları yönetmeye devam edebilirsiniz.")
                    .font(.caption).foregroundStyle(.secondary)
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

            Text(String(format: OhmFormatters.localizedString("Version %@ (%@)", locale: locale),
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
                .font(.footnote)
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 240)

            VStack(spacing: 4) {
                Text("Apache-2.0 · Açık kaynak")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if let url = URL(string: "https://github.com/kuarezma/ohm") {
                Link("github.com/kuarezma/ohm", destination: url)
                    .font(.footnote)
                }
            }

            Text(OhmFormatters.localizedString("Telemetry stays on your Mac.", locale: locale))
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("Enerji fişi tüketimin pil süresi karşılığıdır; tasarruf garantisi değildir. E, macOS arka plan politikasını uygular. Dondurma işleri geçici durdurur ve güvenlik kontrollerine tabidir.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
