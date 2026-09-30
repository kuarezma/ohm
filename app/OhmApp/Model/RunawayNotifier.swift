import Foundation
import OhmModel
import UserNotifications

/// Retained by the future OhmRuntime. It routes intent only; it never signals a process.
@MainActor
final class RunawayNotifier: NSObject, RunawayNotifying, UNUserNotificationCenterDelegate {
    private static let regularCategory = "dev.ohm.runaway.regular"
    private static let backgroundCategory = "dev.ohm.runaway.background"
    private static let eCoreAction = "dev.ohm.runaway.ecore"
    private static let freezeAction = "dev.ohm.runaway.freeze"
    private static let quitAction = "dev.ohm.runaway.quit"

    private struct NotificationEpisode {
        let identifier: String
        let runaway: Runaway
    }

    private let center: UNUserNotificationCenter
    private let onResponse: @MainActor (Runaway, RunawayResponse) -> Void
    private var episodes: [AppKey: NotificationEpisode] = [:]
    private var sequence: UInt64 = 0

    init(center: UNUserNotificationCenter = .current(),
         onResponse: @escaping @MainActor (Runaway, RunawayResponse) -> Void) {
        self.center = center
        self.onResponse = onResponse
        super.init()
    }

    /// The composition root installs this delegate once and retains this adapter.
    func install() async {
        var categories = await center.notificationCategories()
        categories = categories.filter {
            $0.identifier != Self.regularCategory && $0.identifier != Self.backgroundCategory
        }
        for requiresConfirmation in [false, true] {
            let actions = [
                UNNotificationAction(identifier: Self.eCoreAction,
                                     title: String(localized: "Move to E-cores")),
                UNNotificationAction(identifier: Self.freezeAction,
                                     title: requiresConfirmation ? String(localized: "Freeze (confirmation required)") :
                                        String(localized: "Freeze"),
                                     options: requiresConfirmation ? [.foreground] : []),
                UNNotificationAction(identifier: Self.quitAction,
                                     title: String(localized: "Quit"), options: [.destructive])
            ]
            categories.insert(UNNotificationCategory(
                identifier: requiresConfirmation ? Self.backgroundCategory : Self.regularCategory,
                actions: actions, intentIdentifiers: [], options: []))
        }
        center.setNotificationCategories(categories)
        center.delegate = self
    }

    /// Called from onboarding/user intent, rather than prompting on every detector event.
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func handle(_ events: [RunawayEvent]) async throws {
        for event in events {
            switch event {
            case .ended(let app):
                if let episode = episodes.removeValue(forKey: app) { remove(episode.identifier) }
            case .started(let runaway):
                guard episodes[runaway.app] == nil else { continue }
                sequence += 1
                let identifier = "dev.ohm.runaway.\(sequence)"
                episodes[runaway.app] = NotificationEpisode(identifier: identifier, runaway: runaway)
                let content = UNMutableNotificationContent()
                content.title = String(localized: "High CPU usage while hidden")
                let duration = runaway.hiddenDuration.components
                let minutes = max(1, Int(duration.seconds / 60))
                let bodyFormat = String(localized: "%1$@ is using %2$.0f%% CPU while hidden for %3$d minutes.")
                content.body = String(format: bodyFormat,
                                      locale: Locale.current, runaway.displayName,
                                      runaway.averageCPU * 100, minutes)
                content.categoryIdentifier = runaway.actions.contains(.freeze(requiresConfirmation: true)) ?
                    Self.backgroundCategory : Self.regularCategory
                content.sound = .default
                do {
                    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                    try await center.add(request)
                } catch {
                    if episodes[runaway.app]?.identifier == identifier { episodes.removeValue(forKey: runaway.app) }
                    remove(identifier)
                    throw error
                }
                // An ended event can arrive while add is suspended. Never resurrect its notification.
                if episodes[runaway.app]?.identifier != identifier { remove(identifier) }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        await respond(identifier: identifier, actionIdentifier: actionIdentifier)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return category.hasPrefix("dev.ohm.runaway.") ? [.banner, .sound] : []
    }

    private func respond(identifier: String, actionIdentifier: String) {
        // Stale notification responses (ended/snoozed/previous episode) are ignored.
        guard let episode = episodes.values.first(where: { $0.identifier == identifier }) else { return }
        let response: RunawayResponse
        switch actionIdentifier {
        case Self.eCoreAction: response = episode.runaway.response(to: .eCore)
        case Self.freezeAction: response = episode.runaway.response(to: .freeze(requiresConfirmation: false))
        case Self.quitAction: response = episode.runaway.response(to: .quit)
        case UNNotificationDefaultActionIdentifier: response = .openCard(episode.runaway.app)
        default: return
        }
        onResponse(episode.runaway, response)
    }

    private func remove(_ identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
