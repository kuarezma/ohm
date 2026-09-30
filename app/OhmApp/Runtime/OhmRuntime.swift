import AppKit
import Dispatch
import OhmForecast
import OhmGovernor
import OhmJournal
import OhmLedger
import OhmModel
import OhmRules
import OhmSampling
import OSLog

struct DashboardSnapshot: Sendable {
    let tick: SampleTick
    let forecastMinutes: Double?
    let receipt: Receipt?
    let runaways: [AppKey: Runaway]
    let activeEffects: [AppKey: Effect]
    let error: String?
}

struct RuntimeSmokeReport: Sendable, Encodable {
    let ticks: Int
    let ledgerMinuteRows: Int
    let watts: Double
    let runaways: Int
    let protection: String
    let rules: Int
    let rulesActive: Int
    let lastDesired: String
    let applied: [String]
    let vetoes: [String]
}

/// Kept separate from the main actor and from the cooperative executor for SQLite reads.
private actor RuntimeLedgerReader {
    private let queue = DispatchSerialQueue(label: "dev.ohm.runtime-reader", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let reader: LedgerReader

    init(path: String) throws { reader = try LedgerReader(path: path) }

    func today(at date: Date) throws -> Receipt {
        try reader.receipt(for: DateInterval(start: Calendar.current.startOfDay(for: date), end: date))
    }

    func minuteRows(since start: Date, until end: Date) throws -> Int {
        try reader.systemSeries(for: DateInterval(start: start, end: end), resolution: .minute).count
    }
}

/// Shared by production delivery and the executable's deterministic self-check.
nonisolated enum RuntimeTickDelivery {
    static func deliver(isolation: isolated (any Actor)? = #isolation,
                        record: () async throws -> Void, forecast: () async -> Void,
                        detect: () async -> Void, publish: () async -> Void) async rethrows {
        try await record()
        await forecast()
        await detect()
        await publish()
    }
}

actor OhmRuntime {
    private let engine: SamplingEngine
    private let ledger: EnergyLedger
    private let reader: RuntimeLedgerReader
    private let forecaster = BatteryForecaster()
    private let detector = RunawayDetector()
    private let governor: Governor
    private let ruleStore: RuleStore
    private let ruleEngine: RuleEngine
    private let contextBridge: ContextBridge?
    private weak var source: LiveDataSource?
    private var tasks: [Task<Void, Never>] = []
    private var stopping = false
    private var startRequested = false
    private var applications: [WorkspaceApplication] = []
    private var visibility = VisibilitySnapshot(apps: [:])
    private var lastReceiptAt: Date?
    private var recordedMinute: Int64?
    private var lastMaintenanceAt: Date?
    private var receiptRequested = true
    private var ticks = 0
    private var watts = 0.0
    private let startedAt = Date()
    private var lastError: String?
    private var neverFreeze: Set<String> = []
    private var lastBatteryState: BatteryState?
    private var lastThermalLevel: ThermalLevel = .nominal
    private var lastEvaluation: RuleEvaluation?
    private var lastDesiredState = DesiredState()
    private var ruleVetoes: [UUID: String] = [:]
    private var lastVetoList: [String] = []
    private var evaluationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    private init(engine: SamplingEngine, ledger: EnergyLedger, reader: RuntimeLedgerReader,
                 governor: Governor, ruleStore: RuleStore, ruleEngine: RuleEngine,
                 contextBridge: ContextBridge?, source: LiveDataSource?) {
        self.engine = engine
        self.ledger = ledger
        self.reader = reader
        self.governor = governor
        self.ruleStore = ruleStore
        self.ruleEngine = ruleEngine
        self.contextBridge = contextBridge
        self.source = source
    }

    @concurrent
    static func make(source: LiveDataSource?, smoke: Bool = false, rulesFile: String? = nil, ruleStore: RuleStore? = nil) async throws -> OhmRuntime {
        guard let group = appGroupIdentifier(),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw RuntimeError.appGroupUnavailable
        }
        let path = container.appendingPathComponent("ledger.sqlite").path
        let ledger = try EnergyLedger(path: path)
        let reader = try RuntimeLedgerReader(path: path)
        guard await MainActor.run(body: { ThawTable.installSignalHandlers() }) else {
            throw RuntimeError.failure("Sinyal kurtarma koruması kurulamadı; runtime başlatılmadı.")
        }
        let (journal, recovery) = try JournalSession.open(paths: .standard)
        guard !recovery.needsRetry else {
            // Release owner.lock on failure so an existing watcher can retry the old effects.
            throw RuntimeError.failure("Önceki süreç korumaları geri alınamadı; güvenli başlangıç için yeniden deneme gerekiyor.")
        }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ohm-thawd").path
        var config = GovernorConfig()
        config.ownPids = [getpid()]
        // Governor alone owns the non-Sendable journal and its writer lock.
        let governor = Governor(config: config, journal: journal,
                                appControl: WorkspaceAppController(),
                                protection: WatcherProtection(paths: .standard, executable: executable))

        let store: RuleStore
        if let ruleStore {
            store = ruleStore
        } else if let rulesFile {
            store = RuleStore(fileURL: URL(fileURLWithPath: rulesFile))
        } else {
            let url = RuleStore.defaultRulesURL() ?? container.appendingPathComponent("rules.json")
            store = RuleStore(fileURL: url)
        }
        let persisted = await store.load()
        let ruleEngine = RuleEngine(rules: persisted.rules)
        let contextBridge = await MainActor.run { ContextBridge() }

        let runtime = OhmRuntime(engine: SamplingEngine.makeDefault(cadence: smoke ? .interactive : .ambient),
                                 ledger: ledger, reader: reader, governor: governor,
                                 ruleStore: store, ruleEngine: ruleEngine,
                                 contextBridge: contextBridge, source: source)
        await runtime.setNeverFreeze(persisted.neverFreeze)
        return runtime
    }

    func start(workspace: AsyncStream<RuntimeWorkspaceEvent>) async {
        guard !startRequested, !stopping else { return }
        // Claim startup before the first await, including actor reentrancy during protection setup.
        startRequested = true
        let protection = await governor.startProtection()
        guard !stopping else { return }
        let engine = engine
        tasks.append(Task(priority: .utility) { [weak self] in
            for await tick in engine.ticks {
                guard !Task.isCancelled else { break }
                await self?.consume(tick)
            }
        })
        tasks.append(Task(priority: .userInitiated) { [weak self] in
            for await event in workspace {
                guard !Task.isCancelled else { break }
                await self?.workspace(event)
            }
        })
        let governor = governor
        tasks.append(Task { [weak self] in
            for await _ in governor.events {
                guard !Task.isCancelled else { break }
                await self?.publishEffects()
            }
        })
        if let contextBridge {
            tasks.append(Task { [weak self] in
                for await trigger in contextBridge.triggers {
                    guard !Task.isCancelled else { break }
                    await self?.handleContextTrigger(trigger)
                }
            })
        }
        await engine.start()
        await evaluateRules()
        if !stopping, source != nil {
            Logger(subsystem: "dev.ohm", category: "runtime")
                .notice("runtime started protection=\(protection.rawValue, privacy: .public)")
        }
    }

    private func consume(_ tick: SampleTick) async {
        guard !stopping else { return }
        ticks += 1
        watts = tick.system.systemLoad ?? (tick.system.cpuP + tick.system.cpuE + (tick.system.gpu ?? 0))
        await RuntimeTickDelivery.deliver(record: {
            do {
                try await ledger.record(tick)
                let minute = Int64(floor(tick.wallClock.timeIntervalSince1970 / 60))
                if let recordedMinute, minute != recordedMinute {
                    try await ledger.flush()
                    if lastMaintenanceAt.map({ tick.wallClock.timeIntervalSince($0) >= 86_400 }) ?? true {
                        try await ledger.maintain(now: tick.wallClock)
                        lastMaintenanceAt = tick.wallClock
                    }
                }
                recordedMinute = minute
            }
            catch { lastError = "Enerji kaydı yazılamadı: \(error.localizedDescription)" }
        }, forecast: {
            await forecaster.observe(tick)
        }, detect: {
            let candidates = Set(applications.map(\.identity) + tick.processes.map(\.identity)
                                 + visibility.apps.values.flatMap(\.processes))
            // Membership is independent of CPU deltas: zero/unreadable deltas are not exits.
            let sampled = Set(tick.processes.map(\.identity))
            let live = sampled.union(candidates.subtracting(sampled).filter { ProcessProbe.isLive($0) })
            visibility = WorkspaceBridge.visibility(applications: applications, processes: tick.processes,
                                                     previous: visibility, live: live,
                                                     visiblePids: WorkspaceBridge.visibleWindowPids())
            let events = await detector.observe(tick: tick, visibility: visibility)
            pendingRunawayEvents = events
        }, publish: {
            await governor.tick()
            var receipt: Receipt?
            if receiptRequested || lastReceiptAt.map({ tick.wallClock.timeIntervalSince($0) >= 30 }) ?? true {
                do {
                    receipt = try await reader.today(at: tick.wallClock)
                    lastReceiptAt = tick.wallClock
                    receiptRequested = false
                } catch { lastError = "Pil fişi okunamadı: \(error.localizedDescription)" }
            }
            let snapshot = DashboardSnapshot(tick: tick, forecastMinutes: await forecaster.forecast()?.remainingMinutes,
                                             receipt: receipt, runaways: await detector.currentRunaways,
                                             activeEffects: await effects(), error: lastError)
            let batteryChanged = lastBatteryState == nil ||
                lastBatteryState?.source != tick.battery.source ||
                lastBatteryState?.percent != tick.battery.percent
            lastBatteryState = tick.battery
            lastThermalLevel = tick.thermal
            if batteryChanged || !pendingRunawayEvents.isEmpty {
                triggerRuleEvaluation()
            }
            guard !stopping else { return }
            await source?.apply(snapshot, events: pendingRunawayEvents)
        })
    }

    private var pendingRunawayEvents: [RunawayEvent] = []

    private func workspace(_ event: RuntimeWorkspaceEvent) async {
        guard !stopping else { return }
        switch event {
        case .applications(let apps):
            applications = apps
            triggerRuleEvaluation()
        case .governor(let event):
            await governor.handle(event)
            if case .activated = event {
                triggerRuleEvaluation()
            } else if case .deactivated = event {
                triggerRuleEvaluation()
            }
        case .cadence(let cadence):
            receiptRequested = cadence == .interactive || receiptRequested
            await engine.setCadence(cadence)
        }
    }

    private func effects() async -> [AppKey: Effect] {
        let eCore = Set(await governor.eCoreRootPids)
        let frozen = Set(await governor.frozenRootPids)
        return visibility.apps.compactMapValues { app in
            if app.processes.contains(where: { frozen.contains($0.pid) }) { return .freeze }
            if app.processes.contains(where: { eCore.contains($0.pid) }) { return .eCore }
            return nil
        }
    }

    private func publishEffects() async {
        guard !stopping else { return }
        await source?.updateEffects(await effects())
    }

    func toggle(_ effect: Effect, for key: AppKey) async {
        guard !stopping, let app = visibility.apps[key], let root = app.processes.first else {
            await source?.showFailure("Uygulama artık çalışmıyor veya henüz örneklenmedi.")
            return
        }
        let active = await effects()[key]
        let command: GovernorCommand = effect == .freeze
            ? (active == .freeze ? .thaw(pid: root.pid) : .freeze(pid: root.pid, origin: .manual, confirmedBackground: false))
            : .eCore(pid: root.pid, on: active != .eCore, origin: .manual)
        await perform(command, identity: root, key: key)
    }

    private func perform(_ command: GovernorCommand, identity: ProcessIdentity, key: AppKey) async {
        guard !stopping, ProcessProbe.matches(identity) else {
            await source?.showFailure("Süreç kimliği değişti; işlem uygulanmadı.")
            return
        }
        if case .freeze = command {
            guard let app = visibility.apps[key], !app.requiresFreezeConfirmation else {
                await source?.showFailure("Arka plan sürecini dondurmak ek onay gerektirir. Bu ekranda onay verilmediği için işlem reddedildi.")
                return
            }
            if neverFreeze.contains(key.value) || neverFreeze.contains(app.displayName) {
                await source?.showFailure("Bu uygulama asla dondurulmayacaklar listesinde.")
                return
            }
        }
        let outcome = await governor.perform(command)
        switch outcome {
        case .vetoed(let reasons): await source?.showVetoes(reasons)
        case .rolledBack(_, let detail): await source?.showFailure("İşlem geri alındı: \(detail)")
        case .notFound: await source?.showFailure("Etkin işlem bulunamadı.")
        default: break
        }
        await publishEffects()
    }

    func respond(to runaway: Runaway, response: RunawayResponse) async {
        guard !stopping, let current = await detector.currentRunaways[runaway.app],
              current.processes == runaway.processes,
              current.processes.allSatisfy(ProcessProbe.matches) else {
            await source?.showFailure("Kaçak süreç bildirimi artık güncel değil; işlem uygulanmadı.")
            return
        }
        switch response {
        case .commands(let commands):
            for command in commands {
                guard let root = current.processes.first else { break }
                await perform(command, identity: root, key: current.app)
            }
        case .openCard:
            await source?.selectRunaway(current)
        case .quit(_, let identities):
            guard identities == current.processes else { return }
            // Terminate only roots when bundled; their helpers belong to the app's exit path.
            let roots = applications.filter { $0.key == current.app }.map(\.identity)
            for identity in roots.isEmpty ? identities : roots {
                guard ProcessProbe.matches(identity), identity.pid != getpid(),
                      ProcessProbe.uid(identity.pid) == getuid() else { continue }
                _ = await governor.perform(.thaw(pid: identity.pid))
                _ = await governor.perform(.eCore(pid: identity.pid, on: false, origin: .runaway))
                guard !stopping else { return }
                let unresolved = Set(await governor.pendingUndoPids)
                guard unresolved.isDisjoint(with: identities.map(\.pid)), !ProcessProbe.isStopped(identity.pid) else {
                    await source?.showFailure("Süreç koruması henüz geri alınamadı; çıkış işlemi uygulanmadı.")
                    return
                }
                if let app = NSRunningApplication(processIdentifier: identity.pid), app.bundleIdentifier != nil {
                    guard ProcessProbe.matches(identity) else { continue }
                    _ = app.terminate()
                } else {
                    guard ProcessProbe.matches(identity) else { continue }
                    _ = kill(identity.pid, SIGTERM)
                }
            }
        }
    }

    private func handleContextTrigger(_ trigger: ContextTrigger) async {
        guard !stopping else { return }
        switch trigger {
        case .thermal(let level):
            lastThermalLevel = level
            triggerRuleEvaluation()
        case .powerSource:
            triggerRuleEvaluation()
        case .deadline:
            triggerRuleEvaluation(delay: 0)
        }
    }

    private func triggerRuleEvaluation(delay: TimeInterval = 0.250) {
        guard !stopping else { return }
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard !Task.isCancelled else { return }
            await self?.evaluateRules()
        }
    }

    private func evaluateRules() async {
        guard !stopping else { return }
        let powerSourceKind: PowerSourceKind = switch lastBatteryState?.source {
        case .battery: .battery
        case .ac: .ac
        case .unknown, .none: .ac
        }
        let batteryPercent = lastBatteryState?.percent ?? 100
        let thermal = lastThermalLevel

        var frontmostAppRef: AppRef? = nil
        if let front = applications.first(where: \.frontmost) {
            frontmostAppRef = AppRef(
                bundleID: front.key.kind == .bundleID ? front.key.value : nil,
                executableName: front.key.kind == .executableName ? front.key.value : nil,
                displayName: front.name
            )
        }

        let runaways = await detector.currentRunaways
        let runawayApps: [AppRef] = runaways.values.compactMap { runaway in
            guard runaway.app.kind == .bundleID else { return nil }
            return AppRef(bundleID: runaway.app.value, displayName: runaway.displayName)
        }

        let runningApps: [AppRef] = applications.map { app in
            AppRef(
                bundleID: app.key.kind == .bundleID ? app.key.value : nil,
                executableName: app.key.kind == .executableName ? app.key.value : nil,
                displayName: app.name
            )
        }

        let context = RuleContext(
            powerSource: powerSourceKind,
            batteryPercent: batteryPercent,
            thermalLevel: thermal,
            frontmostApp: frontmostAppRef,
            now: Date(),
            isFocusOn: false,
            activeFocusProfile: nil,
            runawayApps: runawayApps,
            runningApps: runningApps
        )

        let evaluation = await ruleEngine.evaluate(context)
        lastEvaluation = evaluation
        lastDesiredState = evaluation.desiredState

        if let deadline = evaluation.nextDeadline {
            scheduleDeadline(deadline)
        }

        let report = await governor.reconcile(evaluation.desiredState)

        var newRuleVetoes: [UUID: String] = [:]
        var newVetoList: [String] = []
        for (appKey, outcome) in report.outcomes.sorted(by: { $0.key.value < $1.key.value }) {
            if case .vetoed(let reasons) = outcome {
                var seen = Set<String>()
                let uniqueReasons = reasons.map(LiveDataSource.vetoMessage).filter { seen.insert($0).inserted }
                let msg = uniqueReasons.joined(separator: ", ")
                newVetoList.append("\(appKey.value):\(msg)")
                if let effect = evaluation.desiredState.effects[appKey] {
                    for (_, origins) in effect.origins {
                        for origin in origins {
                            if case .rule(let ruleID) = origin {
                                newRuleVetoes[ruleID] = msg
                            }
                        }
                    }
                }
            }
        }
        ruleVetoes = newRuleVetoes
        lastVetoList = newVetoList
        await source?.updateRuleVetoes(newRuleVetoes)
        await publishEffects()
    }

    private func scheduleDeadline(_ date: Date) {
        deadlineTask?.cancel()
        let delay = date.timeIntervalSinceNow
        guard delay > 0 else {
            triggerRuleEvaluation(delay: 0)
            return
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.evaluateRules()
        }
    }

    func setRules(_ rules: [Rule]) async {
        await ruleEngine.update(rules: rules)
        triggerRuleEvaluation(delay: 0)
    }

    func setNeverFreeze(_ names: [String]) async {
        neverFreeze = Set(names)
        var bundleIDs = Set<String>()
        for name in names {
            bundleIDs.insert(name)
            for app in applications {
                if app.name.localizedCaseInsensitiveCompare(name) == .orderedSame, app.key.kind == .bundleID {
                    bundleIDs.insert(app.key.value)
                }
            }
        }
        await governor.setUserNeverFreeze(bundleIDs)
        triggerRuleEvaluation(delay: 0)
    }

    nonisolated static func formatDesired(_ desired: DesiredState) -> String {
        if desired.effects.isEmpty { return "none" }
        return desired.effects.sorted(by: { $0.key.value < $1.key.value }).map { key, effect in
            let effStr: String = switch effect.highestEffect {
            case .freeze: "freeze"
            case .eCore: "eCore"
            case .none: "none"
            }
            return "\(key.value)=\(effStr)"
        }.joined(separator: ",")
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        evaluationTask?.cancel()
        deadlineTask?.cancel()
        evaluationTask = nil
        deadlineTask = nil
        await MainActor.run { contextBridge?.stop() }
        _ = await governor.shutdown()
        await engine.stop()
        let running = tasks
        tasks.removeAll()
        running.forEach { $0.cancel() }
        for task in running { await task.value }
        do { try await ledger.flush() }
        catch { lastError = "Son enerji kayıtları yazılamadı: \(error.localizedDescription)" }
    }

    func smokeReport() async throws -> RuntimeSmokeReport {
        if let lastError { throw RuntimeError.failure(lastError) }
        let currentRules = await ruleStore.rules
        let activeCount = currentRules.filter { lastEvaluation?.ruleStates[$0.id] == .active }.count
        let desiredStr = Self.formatDesired(lastDesiredState)

        var appliedList: [String] = []
        let eCoreRoots = await governor.eCoreRootPids
        for root in eCoreRoots {
            let members = await governor.eCoreMembers(root: root) ?? [root]
            let bundle: String
            if let app = applications.first(where: { $0.identity.pid == root }) {
                bundle = app.key.value
            } else if let vis = visibility.apps.first(where: { $0.value.processes.contains { $0.pid == root } }) {
                bundle = vis.key.value
            } else if let ra = NSRunningApplication(processIdentifier: root), let bid = ra.bundleIdentifier {
                bundle = bid
            } else {
                bundle = "pid-\(root)"
            }
            for pid in members {
                let prio = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
                let bg = prio != 0 ? 1 : 0
                appliedList.append("\(bundle)=eCore pid=\(pid) bg=\(bg)")
            }
        }
        appliedList.sort()

        return RuntimeSmokeReport(
            ticks: ticks,
            ledgerMinuteRows: try await reader.minuteRows(since: startedAt, until: Date()),
            watts: watts,
            runaways: await detector.currentRunaways.count,
            protection: await governor.protectionMode.rawValue,
            rules: currentRules.count,
            rulesActive: activeCount,
            lastDesired: desiredStr,
            applied: appliedList,
            vetoes: lastVetoList
        )
    }
}

enum RuntimeError: LocalizedError {
    case appGroupUnavailable
    case failure(String)
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: "<TEAMID>.dev.ohm kapsayıcısı açılamadı. Uygulamanın App Group imzasını doğrulayın."
        case .failure(let message): message
        }
    }
}

extension OhmRuntime {
    /// Read from the signed entitlements. macOS 15+ denies a LaunchServices-launched app its
    /// `group.`-prefixed container unless a provisioning profile authorizes it; a team-prefixed
    /// group needs no profile. A terminal launch hides this because TCC attributes to the terminal.
    nonisolated static func appGroupIdentifier() -> String? {
        guard let groups = signedEntitlement("com.apple.security.application-groups") as? [String] else { return nil }
        return groups.first { $0.hasSuffix(".dev.ohm") }
    }

    private nonisolated static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    /// No live sampling, notifications, files or signals; no extra test target.
    static func selfCheck() async throws {
        // Signed builds only: an unsigned build has no team and cannot open the ledger anyway.
        if let team = signedEntitlement("com.apple.developer.team-identifier") as? String,
           appGroupIdentifier() != "\(team).dev.ohm" {
            throw RuntimeError.failure("App Group takım önekli değil (\(appGroupIdentifier() ?? "yok")); LaunchServices açılışında kapsayıcı reddedilir.")
        }
        var stages: [String] = []
        await RuntimeTickDelivery.deliver(record: { stages.append("ledger") },
                                         forecast: { stages.append("forecast") },
                                         detect: { stages.append("runaway") },
                                         publish: { stages.append("ui") })
        guard stages == ["ledger", "forecast", "runaway", "ui"] else {
            throw RuntimeError.failure("Tick dağıtım sırası yanlış.")
        }
        enum CheckFailure: Error { case expected }
        stages = []
        do {
            try await RuntimeTickDelivery.deliver(record: { throw CheckFailure.expected },
                                                 forecast: { stages.append("forecast") },
                                                 detect: { stages.append("runaway") },
                                                 publish: { stages.append("ui") })
            throw RuntimeError.failure("Başarısız kayıt kabul edildi.")
        } catch CheckFailure.expected {}
        guard stages.isEmpty else { throw RuntimeError.failure("Kayıt tamamlanmadan tick ilerledi.") }
        let key = AppKey.bundle("example.check")
        let root = ProcessIdentity(pid: 101, startAbsTime: 1)
        let helper = ProcessIdentity(pid: 102, startAbsTime: 2)
        let stale = ProcessIdentity(pid: 103, startAbsTime: 3)
        let app = WorkspaceApplication(key: key, identity: root, name: "Kontrol", policy: .regular,
                                       hidden: true, frontmost: false, executablePath: "/Applications/Kontrol.app")
        let previous = VisibilitySnapshot(apps: [key: AppVisibility(
            displayName: "Kontrol", processes: [helper, stale], activationPolicy: .regular,
            isFrontmost: false, hasVisibleWindows: false, isHidden: true, isBundled: true)])
        let mapped = WorkspaceBridge.visibility(applications: [app], processes: [], previous: previous,
                                                live: [root, helper], visiblePids: [])
        guard mapped.apps[key]?.processes == [root, helper], mapped.apps[key]?.isRunawayHidden == true else {
            throw RuntimeError.failure("Kök/helper üyelik eşlemesi yanlış.")
        }
        let unknownWindows = WorkspaceBridge.visibility(applications: [app], processes: [], previous: previous,
                                                        live: [root, helper], visiblePids: nil)
        guard unknownWindows.apps[key]?.hasVisibleWindows == true else {
            throw RuntimeError.failure("Eksik pencere bilgisi güvenli varsayılmadı.")
        }
        let runaway = Runaway(app: key, displayName: "Kontrol", processes: [root, helper], averageCPU: 0.85,
                              hiddenDuration: .seconds(600), requiresFreezeConfirmation: false)
        let info = LiveDataSource.processInfo(runaway)
        guard info?.pid == root.pid, info?.cpuPercent == 85, info?.hiddenDurationMinutes == 10,
              info?.bundleID == key.value else { throw RuntimeError.failure("UI snapshot eşlemesi yanlış.") }
        let background = Runaway(app: key, displayName: "Kontrol", processes: [helper], averageCPU: 0.85,
                                 hiddenDuration: .seconds(600), requiresFreezeConfirmation: true)
        guard background.response(to: .freeze(requiresConfirmation: false)) == .openCard(key) else {
            throw RuntimeError.failure("Arka plan dondurması onaysız açıldı.")
        }

        // Kural motoru ve DesiredState bağlam testi
        let ruleBrowser = Rule(name: "Düşük Pil E-core", enabled: true, source: .manual,
                               when: .batteryPercent(.below, value: 50, hysteresis: 3),
                               targets: .apps([AppRef(bundleID: "com.example.browser", displayName: "Tarayıcı")]),
                               actions: [.eCore(whileFrontmost: .release)])
        let ruleAC = Rule(name: "Şarjda E-core", enabled: true, source: .manual,
                          when: .powerSource(.ac),
                          targets: .apps([AppRef(bundleID: "com.example.editor", displayName: "Editör")]),
                          actions: [.eCore(whileFrontmost: .keep)])
        let ruleRunaway = Rule(name: "Kaçak E-core", enabled: true, source: .manual,
                               when: .always, targets: .runaway,
                               actions: [.eCore(whileFrontmost: .release)])

        let testEngine = RuleEngine(rules: [ruleBrowser, ruleAC, ruleRunaway])

        // Durum 1: Pilde, %80 pil, kaçak yok -> hiçbir etki olmamalı
        let ctx1 = RuleContext(powerSource: .battery, batteryPercent: 80, thermalLevel: .nominal,
                               runawayApps: [], runningApps: [])
        let eval1 = await testEngine.evaluate(ctx1)
        guard eval1.desiredState.effects.isEmpty else {
            throw RuntimeError.failure("Beklenmeyen kural etkisi üretildi.")
        }

        // Durum 2: Pilde, %40 pil, bundleID'li kaçak var -> browser ve runaway E-core almalı
        let bundledKey = AppKey.bundle("com.example.hog")
        let ctx2 = RuleContext(powerSource: .battery, batteryPercent: 40, thermalLevel: .nominal,
                               runawayApps: [AppRef(bundleID: "com.example.hog", displayName: "Hog")],
                               runningApps: [])
        let eval2 = await testEngine.evaluate(ctx2)
        guard eval2.desiredState.effects[AppKey.bundle("com.example.browser")]?.eCore != nil,
              eval2.desiredState.effects[AppKey.bundle("com.example.editor")] == nil,
              eval2.desiredState.effects[bundledKey]?.eCore != nil else {
            throw RuntimeError.failure("Bağlam olayı beklenen DesiredState'e dönüşmedi.")
        }

        // Rev 1 kuralı: Paketsiz kaçak süreç hedef Note kontrolü
        let unbundledKey = AppKey(kind: .executableName, value: "worker")
        let unbundledRunaway = Runaway(app: unbundledKey, displayName: "worker", processes: [root],
                                       averageCPU: 0.90, hiddenDuration: .seconds(300), requiresFreezeConfirmation: false)
        let unbundledInfo = LiveDataSource.processInfo(unbundledRunaway)
        guard unbundledInfo?.ruleNote == "kural bu süreci hedefleyemez" else {
            throw RuntimeError.failure("Paketsiz kaçak süreç için kural notu eksik veya yanlış.")
        }

        // Kalıcılık: Yazma, okuma ve bozuk dosya yedeği testi
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ohm-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storeURL = tmpDir.appendingPathComponent("rules.json")
        let storeA = RuleStore(fileURL: storeURL)
        try await storeA.addRule(ruleBrowser)
        try await storeA.addNeverFreeze("com.example.safari")

        let storeB = RuleStore(fileURL: storeURL)
        let loaded = await storeB.load()
        guard loaded.rules.count == 1, loaded.rules.first?.id == ruleBrowser.id,
              loaded.neverFreeze == ["com.example.safari"] else {
            throw RuntimeError.failure("Kural veya asla-dondurma kalıcılığı okunamadı.")
        }

        // Bozuk dosya testi
        try Data("BOZUK_JSON_ICERIGI".utf8).write(to: storeURL)
        let storeC = RuleStore(fileURL: storeURL)
        let corruptLoaded = await storeC.load()
        guard corruptLoaded.rules.isEmpty, corruptLoaded.neverFreeze.isEmpty else {
            throw RuntimeError.failure("Bozuk kural dosyası boş liste döndürmedi.")
        }
        guard await storeC.corruptWarning != nil else {
            throw RuntimeError.failure("Bozuk kural dosyası uyarısı üretilmedi.")
        }
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        guard dirContents.contains(where: { $0.contains("corrupt-") }) else {
            throw RuntimeError.failure("Bozuk dosya için yedek kopya oluşturulmadı.")
        }

        // NL .ready -> disabled kayıt testi (ADR 0003: kullanıcı arayüzden açar)
        let nlRule = Rule(name: "NL Kuralı", enabled: true, source: .naturalLanguage(text: "TextEdit E-core"),
                          when: .always, targets: .apps([AppRef(bundleID: "com.apple.TextEdit", displayName: "TextEdit")]),
                          actions: [.eCore()])
        let draft = RuleDraft.ready(nlRule)
        if case .ready(var r) = draft {
            r.enabled = false
            try await storeA.addRule(r)
        }
        let nlSaved = await storeA.rules.first(where: { $0.name == "NL Kuralı" })
        guard let nlSaved, !nlSaved.enabled else {
            throw RuntimeError.failure("NL .ready kuralı devre dışı olarak kaydedilmedi.")
        }
    }
}
