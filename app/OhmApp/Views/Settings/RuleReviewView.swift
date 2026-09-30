import SwiftUI
import OhmModel

struct RuleReviewView: View {
    let rule: Rule
    @Bindable var store: OhmStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kuralı gözden geçir").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(rule.name).font(.subheadline.bold())
                    if case .naturalLanguage(let sentence) = rule.source {
                        Text(sentence).foregroundStyle(.secondary)
                    }
                    LabeledContent("Hedef", value: RulePresentation.targets(rule.targets))
                    LabeledContent("Koşul", value: RulePresentation.condition(rule.when))
                    ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                        Text("• " + RulePresentation.action(action))
                    }
                    if let delay = rule.options.activateAfter {
                        Text("Etkinleşmeden önce \(delay.components.seconds) saniye beklenir.")
                    }
                    if let delay = rule.options.deactivateAfter {
                        Text("Koşul bittikten sonra \(delay.components.seconds) saniye beklenir.")
                    }
                    Text("Güvenlik kontrolleri her uygulamada geçerlidir. Bir işlem engellenirse nedeni kurallar listesinde gösterilir.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = store.ruleMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                }
                .textSelection(.enabled)
            }
            HStack {
                Button("Vazgeç") { store.pendingRule = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Kapalı kaydet") { store.savePendingRule(enabled: false) }
                Button("Kaydet ve etkinleştir") { store.savePendingRule(enabled: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(store.isRuleBusy)
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}

enum RulePresentation {
    static func targets(_ targets: TargetSelector) -> String {
        switch targets {
        case .apps(let apps): return apps.map(\.displayName).joined(separator: ", ")
        case .runaway: return "Uzun süre yüksek CPU kullanan gizli uygulamalar"
        case .allApps(let exceptions):
            return exceptions.isEmpty ? "Uygun tüm uygulamalar" : "Uygun tüm uygulamalar; hariç: " + exceptions.map(\.displayName).joined(separator: ", ")
        }
    }

    static func action(_ action: Action) -> String {
        switch action {
        case .eCore(let policy):
            return "Arka plan/E-core politikası; öne gelince " + (policy == .release ? "politikayı bırak." : "politikayı koru.")
        case .freeze(let seconds):
            return "Dondur" + (seconds.map { "; en az \($0) saniye gizli kalınca." } ?? ".")
        case .notify(let message): return "Bildirim göster" + (message.map { ": \($0)" } ?? ".")
        }
    }

    static func condition(_ condition: Condition) -> String {
        switch condition {
        case .always: return "Her zaman"
        case .all(let children): return "Hepsi: " + children.map { "(" + self.condition($0) + ")" }.joined(separator: " ve ")
        case .any(let children): return "En az biri: " + children.map { "(" + self.condition($0) + ")" }.joined(separator: " veya ")
        case .not(let child): return "Şu koşul geçerli değilken: " + self.condition(child)
        case .powerSource(let source):
            switch source {
            case .battery: return "Pille çalışırken"
            case .ac: return "Adaptöre bağlıyken"
            case .unknown: return "Güç kaynağı bilinmiyorken"
            }
        case .batteryPercent(let comparison, let value, let hysteresis):
            let threshold = "Pil %\(value) " + (comparison == .below ? "altındayken" : "ve üzerindeyken")
            return threshold + (hysteresis.map { "; geri dönüş payı \($0) yüzde puanı" } ?? "")
        case .thermal(let level):
            let names: [ThermalLevel: String] = [.nominal: "normal", .fair: "ılık", .serious: "sıcak", .critical: "kritik"]
            return "Isı durumu en az " + (names[level] ?? "bilinmiyor")
        case .frontmostApp(let app): return app.displayName + " öndeyken"
        case .timeWindow(let start, let end, let days):
            let names: [Weekday: String] = [.mon: "Pzt", .tue: "Sal", .wed: "Çar", .thu: "Per", .fri: "Cum", .sat: "Cmt", .sun: "Paz"]
            let dayText = days.map { allowed in Weekday.allCases.filter { allowed.contains($0) }.compactMap { names[$0] }.joined(separator: ", ") } ?? "Her gün"
            return "\(dayText), \(start.formattedString)–\(end.formattedString)"
        case .focus(let isOn): return isOn ? "Odak açıkken" : "Odak kapalıyken"
        case .focusProfile(let profile): return "Odak profili: " + profile
        case .unsupported: return "Desteklenmeyen koşul; etkinleştirilemez"
        }
    }
}
