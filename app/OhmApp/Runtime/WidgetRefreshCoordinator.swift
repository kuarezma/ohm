import Foundation
import Dispatch
import WidgetKit

/// A sliding hour, not a calendar-hour counter. The fifth action is coalesced and deferred.
@MainActor
final class WidgetRefreshCoordinator {
    private var reloads: [UInt64] = []
    private var day = Calendar.current.startOfDay(for: Date())
    private var deferred: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe(Date()) }
        }
    }

    func observe(_ date: Date) {
        let currentDay = Calendar.current.startOfDay(for: date)
        guard currentDay != day else { return }
        day = currentDay
        request()
    }

    func request() {
        // Wall-clock/time-zone changes must not reset WidgetKit's rolling-hour budget.
        let now = DispatchTime.now().uptimeNanoseconds
        let hour: UInt64 = 3_600_000_000_000
        reloads.removeAll { now >= $0 && now - $0 >= hour }
        if reloads.count < 4 {
            deferred?.cancel()
            deferred = nil
            reloads.append(now)
            WidgetCenter.shared.reloadTimelines(ofKind: "OhmWidget")
        } else if deferred == nil, let first = reloads.first {
            let delay = max(1, Double(hour - min(hour, now - first)) / 1e9)
            deferred = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self else { return }
                self.deferred = nil
                self.request()
            }
        }
    }

    func stop() {
        deferred?.cancel()
        deferred = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
