import Foundation
import OhmModel

/// Pure tick-driven state machine. No process control, sampling, wall-clock reads or timers.
public actor RunawayDetector {
    private struct Episode {
        var highDuration: Duration = .zero
        var lowDuration: Duration = .zero
        var hiddenDuration: Duration = .zero
        var cpuNanoseconds: Double = 0
        var isStarted = false
        var runaway: Runaway?
    }

    private var config: RunawayConfig
    private var episodes: [AppKey: Episode] = [:]
    private var snoozedUntil: [AppKey: Date] = [:]

    public init(config: RunawayConfig = RunawayConfig()) { self.config = config }

    public var currentRunaways: [AppKey: Runaway] {
        episodes.compactMapValues { $0.isStarted ? $0.runaway : nil }
    }

    public func setConfig(_ config: RunawayConfig) -> [RunawayEvent] {
        self.config = config
        return config.ignoredApps.compactMap { end($0) }
    }

    public func snooze(_ app: AppKey, now: Date, duration: Duration? = nil) -> [RunawayEvent] {
        let duration = max(.zero, duration ?? config.snoozeDuration)
        snoozedUntil[app] = now.addingTimeInterval(seconds(duration))
        return end(app).map { [$0] } ?? []
    }

    public func observe(tick: SampleTick, visibility: VisibilitySnapshot) -> [RunawayEvent] {
        // interval already excludes asleep (SampleTick contract). A pure sleep tick pauses everything.
        guard tick.interval > .zero else { return [] }
        let elapsed = seconds(tick.interval)
        snoozedUntil = snoozedUntil.filter { $0.value > tick.wallClock }
        let deltas = Dictionary(grouping: tick.processes, by: \.app)
        let disappearedApps = episodes.keys.filter { visibility.apps[$0] == nil }
        var events = disappearedApps.compactMap { end($0) }
        for (app, info) in visibility.apps {
            let processes = deltas[app] ?? []
            guard !info.processes.isEmpty, info.isRunawayHidden,
                  !isExcluded(app, info: info, processes: processes), snoozedUntil[app] == nil else {
                if let event = end(app) { events.append(event) }
                continue
            }
            let cpuNanoseconds = processes.reduce(0.0) { $0 + Double($1.cpuTime_ns) }
            let cpu = cpuNanoseconds / (elapsed * 1e9)
            var episode = episodes[app] ?? Episode()
            if !episode.isStarted {
                guard cpu >= config.startCPU else { episodes.removeValue(forKey: app); continue }
                episode.highDuration += tick.interval
            } else {
                episode.lowDuration = cpu < config.endCPU ? episode.lowDuration + tick.interval : .zero
                if episode.lowDuration >= config.endDuration {
                    if let event = end(app) { events.append(event) }
                    continue
                }
            }
            episode.hiddenDuration += tick.interval
            episode.cpuNanoseconds += cpuNanoseconds
            let runaway = Runaway(app: app, displayName: info.displayName,
                                  processes: info.processes,
                                  averageCPU: episode.cpuNanoseconds / (seconds(episode.hiddenDuration) * 1e9),
                                  hiddenDuration: episode.hiddenDuration,
                                  requiresFreezeConfirmation: info.requiresFreezeConfirmation)
            episode.runaway = runaway
            if !episode.isStarted && episode.highDuration >= config.startDuration {
                episode.isStarted = true
                events.append(.started(runaway))
            }
            episodes[app] = episode
        }
        return events
    }

    private func end(_ app: AppKey) -> RunawayEvent? {
        let episode = episodes.removeValue(forKey: app)
        return episode?.isStarted == true ? .ended(app) : nil
    }

    private func isExcluded(_ app: AppKey, info: AppVisibility, processes: [ProcessDelta]) -> Bool {
        if config.ignoredApps.contains(app) || app.value.hasPrefix("dev.ohm.") { return true }
        let excludedNames: Set<String> = ["ohm-thawd", "kernel_task", "WindowServer", "launchd"]
        if excludedNames.contains(app.value) || excludedNames.contains(info.displayName) { return true }
        if processes.contains(where: { $0.category == .macOSService }) { return true }
        let paths = info.executablePaths + processes.compactMap(\.bundlePath)
        return paths.contains { path in
            excludedNames.contains(URL(fileURLWithPath: path).lastPathComponent) ||
                ["/System/", "/usr/libexec/", "/usr/sbin/"].contains { path.hasPrefix($0) }
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
