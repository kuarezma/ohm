import SwiftUI
import AppKit
import OhmModel

public struct RunawayCardView: View {
    public let runaway: RunawayProcessInfo
    @Bindable var store: OhmStore
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFreezeConfirmation = false
    @State private var showQuitConfirmation = false

    public init(runaway: RunawayProcessInfo, store: OhmStore) {
        self.runaway = runaway
        self.store = store
    }

    private var summaryText: String {
        let percentStr = OhmFormatters.formatPercent(runaway.cpuPercent, locale: locale)
        let durationStr = OhmFormatters.formatDuration(minutes: Double(runaway.hiddenDurationMinutes), locale: locale)

        return OhmFormatters.localizedFormat(
            "%1$@ using %2$@ CPU while hidden for %3$@",
            locale: locale,
            runaway.name,
            percentStr,
            durationStr
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))

                Text(summaryText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()
            }

            HStack(spacing: 6) {
                Button(action: {
                    store.moveRunawayToECores(runaway)
                }) {
                    Text(OhmFormatters.localizedString("Move to E-cores", locale: locale))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(OhmFormatters.localizedFormat("Move %@ to efficiency cores", locale: locale, runaway.name))

                Button(action: {
                    if !store.requestRunawayAction(for: runaway, quit: false) { showFreezeConfirmation = true }
                }) {
                    Text(OhmFormatters.localizedString("Freeze", locale: locale))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(OhmFormatters.localizedFormat("Freeze %@", locale: locale, runaway.name))

                Button(role: .destructive, action: {
                    if !store.requestRunawayAction(for: runaway, quit: true) { showQuitConfirmation = true }
                }) {
                    Text(OhmFormatters.localizedString("Quit", locale: locale))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(OhmFormatters.localizedFormat("Quit %@", locale: locale, runaway.name))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        )
        .alert("\(runaway.name) dondurulsun mu?", isPresented: $showFreezeConfirmation) {
            Button("Vazgeç", role: .cancel) { }
            Button("Dondur") { store.confirmRunawayFreeze(for: runaway) }
        } message: {
            Text("Devam eden işler duraklayacak. Bu onay güvenlik kontrollerini kaldırmaz; önemli çalışmalarınızı önce kaydedin.")
        }
        .alert("\(runaway.name) kapatılsın mı?", isPresented: $showQuitConfirmation) {
            Button("Vazgeç", role: .cancel) { }
            Button("Kapat", role: .destructive) { store.confirmRunawayQuit(for: runaway) }
        } message: { Text("Kaydedilmemiş çalışmalar etkilenebilir. Uygulamanın normal kapanışı istenir.") }
    }
}
