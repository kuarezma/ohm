import AppIntents
import Foundation
import OhmControl
import OhmModel

struct MoveToECoreIntent: AppIntent {
    static let title = LocalizedStringResource("intent.ecore.title", defaultValue: "Uygulamayı E-core'a al", table: "ControlIntents")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: LocalizedStringResource("intent.application", defaultValue: "Uygulama adı veya bundle ID", table: "ControlIntents"))
    var application: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let source = try IntentText.source()
        let response = try await source.performIntent(ControlRequest(operation: .eCore, target: application))
        try IntentText.check(response)
        let message = IntentText.english ? "The app is now on E-cores." : "Uygulama E-core'a alındı."
        return .result(dialog: IntentDialog("\(message)"))
    }
}

struct ThawAllIntent: AppIntent {
    static let title = LocalizedStringResource("intent.thaw.title", defaultValue: "Tümünü çöz", table: "ControlIntents")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await IntentText.source().performIntent(ControlRequest(operation: .thawAll))
        try IntentText.check(response)
        let message = IntentText.english ? "All Ohm freeze and E-core effects have been cleared." : "Ohm'un tüm dondurma ve E-core etkileri geri alındı."
        return .result(dialog: IntentDialog("\(message)"))
    }
}

struct TodayReceiptIntent: AppIntent {
    static let title = LocalizedStringResource("intent.receipt.title", defaultValue: "Bugünün fişi", table: "ControlIntents")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let receipt = try await IntentText.source().intentReceipt()
        let text = IntentText.receipt(receipt)
        return .result(value: text, dialog: IntentDialog("\(text)"))
    }
}

struct OhmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MoveToECoreIntent(), phrases: [
            "Uygulamayı \(.applicationName) ile E-core'a al",
            "Move an app to E-cores with \(.applicationName)"
        ], shortTitle: LocalizedStringResource("intent.ecore.short", defaultValue: "E-core'a al", table: "ControlIntents"), systemImageName: "cpu")
        AppShortcut(intent: ThawAllIntent(), phrases: [
            "\(.applicationName) ile tümünü çöz",
            "Thaw all apps with \(.applicationName)"
        ], shortTitle: LocalizedStringResource("intent.thaw.short", defaultValue: "Tümünü çöz", table: "ControlIntents"), systemImageName: "snowflake.slash")
        AppShortcut(intent: TodayReceiptIntent(), phrases: [
            "\(.applicationName) ile bugünün fişi",
            "Today's energy receipt with \(.applicationName)"
        ], shortTitle: LocalizedStringResource("intent.receipt.short", defaultValue: "Bugünün fişi", table: "ControlIntents"), systemImageName: "receipt")
    }
}

private struct IntentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum IntentText {
    static var english: Bool { Locale.preferredLanguages.first?.hasPrefix("en") == true }

    @MainActor
    static func source() throws -> LiveDataSource {
        guard let source = LiveDataSource.intentSource else {
            throw IntentFailure(message: english ? "Ohm is not ready. Open Ohm and try again." : "Ohm henüz hazır değil; uygulamayı açıp yeniden deneyin.")
        }
        return source
    }

    static func check(_ response: ControlResponse) throws {
        guard let error = response.error else { return }
        if !english { throw IntentFailure(message: response.message) }
        let message: String
        switch error.code {
        case .notFound: message = "The app or active effect was not found."
        case .ambiguousTarget: message = "Multiple apps matched. Use an exact bundle ID or PID."
        case .vetoed: message = error.vetoes.map(veto).joined(separator: "\n")
        case .recoveryPending: message = "Recovery could not be verified as complete. Some effects or journal writes failed, or unverified groups were closed without sending signals. Check Ohm before retrying."
        case .rolledBack: message = "The action was rolled back. Check Ohm for details."
        case .notReady: message = "Ohm is not ready or is shutting down."
        default: message = "Ohm rejected the request (\(error.code.rawValue))."
        }
        throw IntentFailure(message: message)
    }

    static func veto(_ reason: FreezeVeto) -> String {
        switch reason {
        case .appleBundle, .systemPath: "Protected Apple or system app."
        case .ohmItself: "Ohm cannot apply effects to itself."
        case .otherUser: "This process belongs to another user."
        case .notRunning: "The app is no longer running."
        case .notRegularApp, .backgroundNeedsConfirmation: "This background app requires additional confirmation."
        case .frontmost, .notHidden: "The app is active or has visible windows."
        case .recentlyActive, .refreezeGrace: "The app was used recently. Try again later."
        case .audio, .camera: "The app is using audio or the camera."
        case .powerAssertion: "The app has an ongoing system task."
        case .eventTap: "The app is monitoring keyboard or mouse input."
        case .outOfBundleChild: "A child process runs outside the app bundle."
        case .debugged: "The process is being debugged."
        case .userNeverList: "The app is on the never-freeze list."
        case .unsavedDocument: "The app has an unsaved document."
        case .safetyProbeFailed: "Process safety could not be verified."
        case .powerOffInProgress, .shuttingDown: "Ohm or the system is shutting down."
        case .postWakeQuiet: "Safety cooldown after wake is still active."
        case .protectionNotReady: "The recovery watcher is not ready."
        case .journalUnwritable: "The safety journal cannot be written."
        case .bootUnverified: "The boot session could not be verified."
        case .recoveryPending: "Effects from a previous session still need recovery."
        case .unstableTree: "The process tree is still changing."
        case .unsafeTopology, .unverifiedTopology: "Safe freezing of this app has not been verified."
        case .superseded, .notDesired: "The request is no longer current."
        case .busy: "Another action on this process is in progress."
        case .tableFull: "Recovery capacity is full."
        }
    }

    static func receipt(_ receipt: Receipt) -> String {
        guard !receipt.allRows.isEmpty || receipt.measuredSystemEnergy_uj > 0 else {
            return english ? "No energy recorded today yet." : "Bugün henüz enerji kaydı yok."
        }
        let total = Double(receipt.measuredSystemEnergy_uj) / 3_600_000_000
        let amount = String(format: "%.2f", locale: Locale.current, total)
        let apps = receipt.allRows.prefix(3).map { row in
            let wh = String(format: "%.2f", locale: Locale.current, Double(row.energy_uj) / 3_600_000_000)
            return "\(row.displayName): \(wh) Wh"
        }.joined(separator: "; ")
        return english ? "Today's measured system energy: \(amount) Wh. \(apps)"
            : "Bugünün ölçülen sistem enerjisi: \(amount) Wh. \(apps)"
    }
}
