import SwiftUI
import AppKit
import OhmModel

// MARK: - Runaway Process Information

public struct RunawayProcessInfo: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var cpuPercent: Double
    public var hiddenDurationMinutes: Int
    public var appKey: AppKey
    public var ruleNote: String?

    public init(
        pid: Int32,
        name: String,
        bundleID: String? = nil,
        cpuPercent: Double,
        hiddenDurationMinutes: Int,
        appKey: AppKey,
        ruleNote: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.cpuPercent = cpuPercent
        self.hiddenDurationMinutes = hiddenDurationMinutes
        self.appKey = appKey
        self.ruleNote = ruleNote
    }
}

// MARK: - Menu Bar Display Mode

public enum MenuBarDisplayMode: String, CaseIterable, Sendable {
    case ringAndWatts = "ringAndWatts"
    case ringOnly = "ringOnly"
    case wattsOnly = "wattsOnly"
}

// MARK: - Ohm Data Source Protocol (ADR 0001 § 2-3)

@MainActor
public protocol OhmDataSource: AnyObject {
    var systemPower: SystemPower { get }
    var batteryState: BatteryState { get }
    var batteryForecastMinutes: Double? { get }
    var thermalLevel: ThermalLevel { get }
    var todayReceipt: Receipt { get }
    var runawayProcess: RunawayProcessInfo? { get }
    var rules: [Rule] { get }
    var isNLAvailable: Bool { get }
    var neverFreezeApps: [String] { get }
    var activeEffects: [AppKey: Effect] { get }
    var ruleVetoes: [UUID: String] { get }

    func toggleECore(for appKey: AppKey)
    func toggleFreeze(for appKey: AppKey)
    func moveRunawayToECores()
    func freezeRunaway()
    func quitRunaway()
    func addRule(description: String)
    func toggleRule(_ rule: Rule)
    func deleteRule(_ rule: Rule)
    func addNeverFreezeApp(_ appName: String)
    func removeNeverFreezeApp(_ appName: String)
    func vetoReason(for rule: Rule) -> String?
}

extension OhmDataSource {
    public var ruleVetoes: [UUID: String] { [:] }
    public func vetoReason(for rule: Rule) -> String? { ruleVetoes[rule.id] }
}

// MARK: - Preview Data Source

@MainActor
public final class PreviewDataSource: OhmDataSource {
    public var systemPower: SystemPower
    public var batteryState: BatteryState
    public var batteryForecastMinutes: Double?
    public var thermalLevel: ThermalLevel
    public var todayReceipt: Receipt
    public var runawayProcess: RunawayProcessInfo?
    public var rules: [Rule]
    public var isNLAvailable: Bool
    public var neverFreezeApps: [String]
    public var activeEffects: [AppKey: Effect]
    public var ruleVetoes: [UUID: String] = [:]

    public init(
        systemPower: SystemPower,
        batteryState: BatteryState,
        batteryForecastMinutes: Double?,
        thermalLevel: ThermalLevel,
        todayReceipt: Receipt,
        runawayProcess: RunawayProcessInfo? = nil,
        rules: [Rule] = [],
        isNLAvailable: Bool = true,
        neverFreezeApps: [String] = ["Music", "Zoom", "Terminal"],
        activeEffects: [AppKey: Effect] = [:]
    ) {
        self.systemPower = systemPower
        self.batteryState = batteryState
        self.batteryForecastMinutes = batteryForecastMinutes
        self.thermalLevel = thermalLevel
        self.todayReceipt = todayReceipt
        self.runawayProcess = runawayProcess
        self.rules = rules
        self.isNLAvailable = isNLAvailable
        self.neverFreezeApps = neverFreezeApps
        self.activeEffects = activeEffects
    }

    public func toggleECore(for appKey: AppKey) {
        if activeEffects[appKey] == .eCore {
            activeEffects[appKey] = .none
        } else {
            activeEffects[appKey] = .eCore
        }
    }

    public func toggleFreeze(for appKey: AppKey) {
        if activeEffects[appKey] == .freeze {
            activeEffects[appKey] = .none
        } else {
            activeEffects[appKey] = .freeze
        }
    }

    public func moveRunawayToECores() {
        if let runaway = runawayProcess {
            activeEffects[runaway.appKey] = .eCore
            runawayProcess = nil
        }
    }

    public func freezeRunaway() {
        if let runaway = runawayProcess {
            activeEffects[runaway.appKey] = .freeze
            runawayProcess = nil
        }
    }

    public func quitRunaway() {
        runawayProcess = nil
    }

    public func addRule(description: String) {
        let newRule = Rule(
            name: description,
            enabled: true,
            source: .naturalLanguage(text: description),
            when: .always,
            targets: .allApps(except: []),
            actions: [.eCore(whileFrontmost: .release)]
        )
        rules.append(newRule)
    }

    public func toggleRule(_ rule: Rule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index].enabled.toggle()
        }
    }

    public func deleteRule(_ rule: Rule) {
        rules.removeAll(where: { $0.id == rule.id })
    }

    public func addNeverFreezeApp(_ appName: String) {
        guard !appName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !neverFreezeApps.contains(appName) {
            neverFreezeApps.append(appName)
        }
    }

    public func removeNeverFreezeApp(_ appName: String) {
        neverFreezeApps.removeAll(where: { $0 == appName })
    }

    // MARK: - Factory Presets

    public static var normal: PreviewDataSource {
        let chromeKey = AppKey(kind: .bundleID, value: "com.google.Chrome")
        let slackKey = AppKey(kind: .bundleID, value: "com.tinyspeck.slackmacgap")
        let xcodeKey = AppKey(kind: .bundleID, value: "com.apple.dt.Xcode")
        let terminalKey = AppKey(kind: .bundleID, value: "com.apple.Terminal")

        let now = Date()
        let todayInterval = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)

        let rows: [ReceiptAppRow] = [
            ReceiptAppRow(
                appKey: chromeKey,
                displayName: "Chrome",
                bundlePath: "/Applications/Google Chrome.app",
                category: .userApp,
                energy_uj: 5_400_000_000,
                pEnergy_uj: 3_200_000_000,
                cpuTime_ms: 180_000,
                batteryMinutes: 72.0,
                batteryPercent: 18.0
            ),
            ReceiptAppRow(
                appKey: slackKey,
                displayName: "Slack",
                bundlePath: "/Applications/Slack.app",
                category: .userApp,
                energy_uj: 2_850_000_000,
                pEnergy_uj: 1_200_000_000,
                cpuTime_ms: 95_000,
                batteryMinutes: 38.0,
                batteryPercent: 9.5
            ),
            ReceiptAppRow(
                appKey: xcodeKey,
                displayName: "Xcode",
                bundlePath: "/Applications/Xcode.app",
                category: .userApp,
                energy_uj: 1_800_000_000,
                pEnergy_uj: 1_400_000_000,
                cpuTime_ms: 60_000,
                batteryMinutes: 24.0,
                batteryPercent: 6.0
            ),
            ReceiptAppRow(
                appKey: terminalKey,
                displayName: "Terminal",
                bundlePath: "/System/Applications/Utilities/Terminal.app",
                category: .userApp,
                energy_uj: 825_000_000,
                pEnergy_uj: 350_000_000,
                cpuTime_ms: 22_000,
                batteryMinutes: 11.0,
                batteryPercent: 2.8
            )
        ]

        let receipt = Receipt(
            interval: todayInterval,
            powerSource: .battery,
            rows: rows,
            other_uj: 9_000_000_000, // ~120 min (2 h)
            pRefWatts: 7.4
        )

        let rules = [
            Rule(
                name: "Throttle background apps on low battery",
                enabled: true,
                source: .manual,
                when: .batteryPercent(.below, value: 30, hysteresis: nil),
                targets: .allApps(except: []),
                actions: [.eCore(whileFrontmost: .release)]
            ),
            Rule(
                name: "Freeze idle Slack after 15 min hidden",
                enabled: true,
                source: .manual,
                when: .always,
                targets: .apps([AppRef(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")]),
                actions: [.freeze(minHiddenSeconds: 900)]
            ),
            Rule(
                name: "Move heavy compilers to efficiency cores",
                enabled: true,
                source: .naturalLanguage(text: "Move compiler to E-core"),
                when: .always,
                targets: .apps([AppRef(executableName: "swift-frontend", displayName: "Swift Compiler")]),
                actions: [.eCore(whileFrontmost: .release)]
            )
        ]

        return PreviewDataSource(
            systemPower: SystemPower(
                cpuP: 2.1,
                cpuE: 1.8,
                gpu: 0.9,
                systemLoad: 7.4,
                systemLoadAge: .seconds(2),
                clusterActive: ClusterResidency(pActiveRatio: 0.42, eActiveRatio: 0.78)
            ),
            batteryState: BatteryState(
                source: .battery,
                percent: 62,
                voltage_mV: 11400,
                amperage_mA: -650,
                isCharging: false
            ),
            batteryForecastMinutes: 310.0, // 5 h 10 min
            thermalLevel: .nominal,
            todayReceipt: receipt,
            runawayProcess: nil,
            rules: rules,
            isNLAvailable: true,
            neverFreezeApps: ["Music", "Zoom", "Terminal"],
            activeEffects: [slackKey: .eCore]
        )
    }

    public static var hotThermal: PreviewDataSource {
        let data = PreviewDataSource.normal
        data.thermalLevel = .serious
        data.systemPower = SystemPower(
            cpuP: 14.5,
            cpuE: 6.2,
            gpu: 3.8,
            systemLoad: 24.5,
            systemLoadAge: .seconds(1),
            clusterActive: ClusterResidency(pActiveRatio: 0.92, eActiveRatio: 0.85)
        )
        data.batteryForecastMinutes = 75.0 // 1 h 15 min
        return data
    }

    public static var runaway: PreviewDataSource {
        let data = PreviewDataSource.normal
        data.runawayProcess = RunawayProcessInfo(
            pid: 48921,
            name: "node",
            bundleID: nil,
            cpuPercent: 94.0,
            hiddenDurationMinutes: 12,
            appKey: AppKey(kind: .executableName, value: "node")
        )
        return data
    }

    public static var empty: PreviewDataSource {
        let now = Date()
        let todayInterval = DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        return PreviewDataSource(
            systemPower: SystemPower(
                cpuP: 0.4,
                cpuE: 0.6,
                gpu: 0.1,
                systemLoad: 3.2,
                systemLoadAge: .seconds(5),
                clusterActive: ClusterResidency(pActiveRatio: 0.05, eActiveRatio: 0.20)
            ),
            batteryState: BatteryState(
                source: .battery,
                percent: 95,
                voltage_mV: 12200,
                amperage_mA: -280,
                isCharging: false
            ),
            batteryForecastMinutes: 720.0,
            thermalLevel: .nominal,
            todayReceipt: Receipt(interval: todayInterval, powerSource: .battery, rows: []),
            runawayProcess: nil,
            rules: [],
            isNLAvailable: false,
            neverFreezeApps: [],
            activeEffects: [:]
        )
    }
}

// MARK: - Ohm Store (@MainActor @Observable)

@MainActor
@Observable
public final class OhmStore {
    public var dataSource: any OhmDataSource
    public var showOnboarding: Bool = false
    public var menuBarDisplayMode: MenuBarDisplayMode = .ringAndWatts
    public var launchAtLogin: Bool = false

    public init(dataSource: (any OhmDataSource)? = nil) {
        self.dataSource = dataSource ?? (CommandLine.arguments.contains("--render-previews") ||
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            ? PreviewDataSource.normal : LiveDataSource())
    }

    // Direct Forwarded Accessors
    public var systemPower: SystemPower { dataSource.systemPower }
    public var batteryState: BatteryState { dataSource.batteryState }
    public var batteryForecastMinutes: Double? { dataSource.batteryForecastMinutes }
    public var thermalLevel: ThermalLevel { dataSource.thermalLevel }
    public var todayReceipt: Receipt { dataSource.todayReceipt }
    public var runawayProcess: RunawayProcessInfo? { dataSource.runawayProcess }
    public var rules: [Rule] { dataSource.rules }
    public var isNLAvailable: Bool { dataSource.isNLAvailable }
    public var neverFreezeApps: [String] { dataSource.neverFreezeApps }
    public var activeEffects: [AppKey: Effect] { dataSource.activeEffects }
    public var ruleVetoes: [UUID: String] { dataSource.ruleVetoes }

    public func vetoReason(for rule: Rule) -> String? {
        dataSource.vetoReason(for: rule)
    }

    // User Actions
    public func toggleECore(for appKey: AppKey) {
        dataSource.toggleECore(for: appKey)
    }

    public func toggleFreeze(for appKey: AppKey) {
        dataSource.toggleFreeze(for: appKey)
    }

    public func moveRunawayToECores() {
        dataSource.moveRunawayToECores()
    }

    public func freezeRunaway() {
        dataSource.freezeRunaway()
    }

    public func quitRunaway() {
        dataSource.quitRunaway()
    }

    public func addRule(description: String) {
        dataSource.addRule(description: description)
    }

    public func toggleRule(_ rule: Rule) {
        dataSource.toggleRule(rule)
    }

    public func deleteRule(_ rule: Rule) {
        dataSource.deleteRule(rule)
    }

    public func addNeverFreezeApp(_ appName: String) {
        dataSource.addNeverFreezeApp(appName)
    }

    public func removeNeverFreezeApp(_ appName: String) {
        dataSource.removeNeverFreezeApp(appName)
    }
}
