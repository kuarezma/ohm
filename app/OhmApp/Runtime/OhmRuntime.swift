import AppKit
import Dispatch
import OhmForecast
import OhmControl
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
    let storage: String
    let ledgerPath: String
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
    static func shouldFlush(minute: Int64, previousMinute: Int64?, storage: RuntimeStorage.Mode) -> Bool {
        // Expose the first preview measurement immediately, even if its interval crossed :00.
        // Shared storage retains its existing minute-boundary schedule.
        previousMinute.map { $0 != minute } ?? (storage == .local)
    }

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
    let storageMode: RuntimeStorage.Mode
    private let ledgerPath: String
    private let logger = Logger(subsystem: "dev.ohm", category: "runtime")
    private var firstFlushRequested = false
    private var firstFlushCompleted = false
    private var lastFailureLogs: [String: ContinuousClock.Instant] = [:]
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
    private var controlServer: ControlServer?
    private var controlTop: ControlTop?

    private init(engine: SamplingEngine, ledger: EnergyLedger, reader: RuntimeLedgerReader,
                 governor: Governor, ruleStore: RuleStore, ruleEngine: RuleEngine,
                 contextBridge: ContextBridge?, source: LiveDataSource?, storageMode: RuntimeStorage.Mode,
                 ledgerPath: String) {
        self.storageMode = storageMode
        self.ledgerPath = ledgerPath
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
    static func make(source: LiveDataSource?, smoke: Bool = false, rulesFile: String? = nil, ruleStore: RuleStore? = nil, storage: RuntimeStorage? = nil) async throws -> OhmRuntime {
        let selectedStorage: RuntimeStorage
        if let storage { selectedStorage = storage }
        else { selectedStorage = try await RuntimeStorage.prepare() }
        let container = selectedStorage.directory
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
            let url = container.appendingPathComponent("rules.json")
            store = RuleStore(fileURL: url)
        }
        let persisted = await store.load()
        let ruleEngine = RuleEngine(rules: persisted.rules)
        let contextBridge = await MainActor.run { ContextBridge() }

        let runtime = OhmRuntime(engine: SamplingEngine.makeDefault(cadence: smoke ? .interactive : .ambient),
                                 ledger: ledger, reader: reader, governor: governor,
                                 ruleStore: store, ruleEngine: ruleEngine,
                                 contextBridge: contextBridge, source: source, storageMode: selectedStorage.mode,
                                 ledgerPath: path)
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
        let server = ControlServer { [weak self] request in
            guard let self else {
                return ControlResponse(id: request.id, message: "Ohm kapanıyor.", error: ControlFailure(code: .notReady))
            }
            return await self.handleControl(request, origin: .cli)
        }
        do {
            try await server.start()
            if stopping { await server.stop() }
            else { controlServer = server }
        } catch {
            lastError = "Kontrol soketi açılamadı: \(error.localizedDescription)"
            Logger(subsystem: "dev.ohm", category: "control").error("listener start failed: \(String(describing: error), privacy: .public)")
        }
        await evaluateRules()
        if !stopping, source != nil {
            logger.notice("runtime started storage=\(self.storageMode.rawValue, privacy: .public) protection=\(protection.rawValue, privacy: .public) ledger=\(self.ledgerPath, privacy: .public)")
        }
    }

    private func consume(_ tick: SampleTick) async {
        guard !stopping else { return }
        ticks += 1
        if ticks == 1 {
            logger.notice("runtime first tick storage=\(self.storageMode.rawValue, privacy: .public) interval=\(String(describing: tick.interval), privacy: .public) ledger=\(self.ledgerPath, privacy: .public)")
            logger.notice("runtime first record requested")
        }
        watts = tick.system.systemLoad ?? (tick.system.cpuP + tick.system.cpuE + (tick.system.gpu ?? 0))
        controlTop = ControlRouter.top(from: tick, watts: watts)
        await RuntimeTickDelivery.deliver(record: {
            var operation = "record"
            do {
                try await ledger.record(tick)
                if ticks == 1 { logger.notice("runtime first record completed") }
                let minute = Int64(floor(tick.wallClock.timeIntervalSince1970 / 60))
                if RuntimeTickDelivery.shouldFlush(minute: minute, previousMinute: recordedMinute, storage: storageMode) {
                    operation = "flush"
                    try await flushLedger()
                    // The early local flush must not move daily maintenance into startup.
                    if recordedMinute != nil,
                       lastMaintenanceAt.map({ tick.wallClock.timeIntervalSince($0) >= 86_400 }) ?? true {
                        operation = "maintain"
                        try await ledger.maintain(now: tick.wallClock)
                        lastMaintenanceAt = tick.wallClock
                    }
                }
                recordedMinute = minute
            }
            catch {
                lastError = "Enerji kaydı yazılamadı: \(error.localizedDescription)"
                logLedgerFailure(error, operation: operation)
            }
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
            if ticks == 1 { logger.notice("runtime first tick delivered") }
        })
    }

    private func flushLedger() async throws {
        if !firstFlushRequested {
            firstFlushRequested = true
            logger.notice("runtime first flush requested storage=\(self.storageMode.rawValue, privacy: .public) ledger=\(self.ledgerPath, privacy: .public)")
        }
        try await ledger.flush()
        if !firstFlushCompleted {
            firstFlushCompleted = true
            logger.notice("runtime first flush completed storage=\(self.storageMode.rawValue, privacy: .public) ledger=\(self.ledgerPath, privacy: .public)")
        }
    }

    private func logLedgerFailure(_ error: any Error, operation: String) {
        let now = ContinuousClock.now
        // At most one error per operation per minute; wall-clock changes cannot bypass the limit.
        if let previous = lastFailureLogs[operation], previous.duration(to: now) < .seconds(60) { return }
        lastFailureLogs[operation] = now
        logger.error("runtime ledger failed operation=\(operation, privacy: .public) storage=\(self.storageMode.rawValue, privacy: .public) ledger=\(self.ledgerPath, privacy: .public) error=\(String(describing: error), privacy: .public)")
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
            let previous = await engine.currentCadence
            if previous != cadence {
                logger.notice("runtime cadence changed from=\(String(describing: previous), privacy: .public) to=\(String(describing: cadence), privacy: .public)")
            }
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

    /// Both CLI and App Intents use the same Governor; intents call this directly in-process.
    func handleControl(_ request: ControlRequest, origin: EffectOrigin) async -> ControlResponse {
        guard !stopping, !Task.isCancelled else {
            return ControlRouter.failure(request, code: .notReady, message: "Ohm kapanıyor.")
        }
        do { try request.validate() }
        catch { return ControlRouter.failure(request, code: .invalidArguments, message: "Geçersiz kontrol isteği.") }
        if request.operation == .top {
            guard let controlTop else {
                return ControlRouter.failure(request, code: .notReady, message: "İlk enerji örneği henüz hazır değil.")
            }
            return ControlResponse(id: request.id, message: "Son canlı örnek.", top: controlTop)
        }
        var targetPID: Int32?
        let command: GovernorCommand
        if request.operation == .thawAll {
            command = .thawAll
        } else {
            guard let target = request.target else {
                return ControlRouter.failure(request, code: .invalidArguments, message: "Uygulama veya PID belirtin.")
            }
            let resolution = await ControlRouter.resolve(target)
            switch resolution {
            case .failure(let code, let message): return ControlRouter.failure(request, code: code, message: message)
            case .identity(let identity):
                guard !stopping, !Task.isCancelled, ProcessProbe.matches(identity) else {
                    return ControlRouter.failure(request, code: .notFound, message: "Süreç kimliği değişti; işlem uygulanmadı.")
                }
                targetPID = identity.pid
                switch request.operation {
                case .eCore: command = .eCore(pid: identity.pid, on: !request.off, origin: origin)
                case .freeze: command = .freeze(pid: identity.pid, origin: origin, confirmedBackground: false)
                case .thaw: command = .thaw(pid: identity.pid)
                case .top, .thawAll: return ControlRouter.failure(request, code: .invalidArguments, message: "Geçersiz hedef.")
                }
            }
        }
        var response: ControlResponse
        if request.operation == .thawAll {
            // Consume the result of this operation, not a later snapshot of live PID lists.
            response = ControlRouter.response(request, report: await governor.thawAll(reason: .user))
        } else {
            response = ControlRouter.response(request, outcome: await governor.perform(command))
        }
        let pending = await governor.pendingUndoPids
        let frozen = await governor.frozenRootPids
        let eCore = await governor.eCoreRootPids
        if let targetPID, pending.contains(targetPID) ||
                    (request.off && eCore.contains(targetPID)) ||
                    (request.operation == .thaw && frozen.contains(targetPID)) {
            response = ControlRouter.failure(request, code: .recoveryPending,
                                             message: "Süreç etkisi henüz geri alınamadı; Ohm yeniden deniyor.")
        }
        await publishEffects()
        if response.success { await source?.reloadWidget() }
        return response
    }

    func intentReceipt() async throws -> Receipt {
        guard !stopping else { throw RuntimeError.failure("Ohm kapanıyor.") }
        return try await reader.today(at: Date())
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
        await controlServer?.stop()
        controlServer = nil
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
        do { try await flushLedger() }
        catch {
            lastError = "Son enerji kayıtları yazılamadı: \(error.localizedDescription)"
            logLedgerFailure(error, operation: "shutdownFlush")
        }
    }

    func smokeReport() async throws -> RuntimeSmokeReport {
        if let lastError { throw RuntimeError.failure(lastError) }
        // The headless caller requests this report before shutdown; count committed data.
        do { try await flushLedger() }
        catch {
            logLedgerFailure(error, operation: "smokeFlush")
            throw error
        }
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
                // getpriority(PRIO_DARWIN_PROCESS) reads 0 for other processes; report the task's base
                // priority instead (4 under PRIO_DARWIN_BG, but App Nap can also lower GUI apps to 4).
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                let pri = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_priority) : -1
                appliedList.append("\(bundle)=eCore pid=\(pid) pri=\(pri)")
            }
        }
        appliedList.sort()

        return RuntimeSmokeReport(
            storage: storageMode.rawValue,
            ledgerPath: ledgerPath,
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
    case failure(String)
    var errorDescription: String? {
        switch self {
        case .failure(let message): message
        }
    }
}

extension OhmRuntime {
    private static func checkFirstLocalFlush(directory: URL) async throws {
        // Startup at :53; a 10 s ambient timer with 10% tolerance first fires at :04.
        // Before Rev 1, this tick remained only in memory until the *next* minute boundary.
        let end = Date(timeIntervalSince1970: 64)
        let tick = SampleTick(wallClock: end, interval: .seconds(11),
                              system: SystemPower(cpuP: 0, cpuE: 0, systemLoad: 2),
                              battery: BatteryState(source: .battery, percent: 80, voltage_mV: 12_000, amperage_mA: -100),
                              thermal: .nominal,
                              processes: [ProcessDelta(identity: ProcessIdentity(pid: 1, startAbsTime: 1),
                                                       app: .bundle("example.storage"), energy_nJ: 1_000_000_000,
                                                       pEnergy_nJ: 0, cpuTime_ns: 1_000_000_000)],
                              unreadable: UnreadableSummary(readableCount: 1, unreadableCount: 0))
        let minute: Int64 = 1
        let ledger = try EnergyLedger(path: directory.appendingPathComponent("first-tick.sqlite").path)
        let reader = try RuntimeLedgerReader(path: directory.appendingPathComponent("first-tick.sqlite").path)
        try await ledger.record(tick)
        guard try await reader.minuteRows(since: .init(timeIntervalSince1970: 0), until: end) == 0 else {
            throw RuntimeError.failure("Regresyon düzeneği flush öncesi veri içeriyor.")
        }
        if RuntimeTickDelivery.shouldFlush(minute: minute, previousMinute: nil, storage: .local) {
            try await ledger.flush()
        }
        guard try await reader.minuteRows(since: .init(timeIntervalSince1970: 0), until: end) >= 1,
              try await reader.today(at: end).rows.contains(where: { $0.energy_uj > 0 }) else {
            throw RuntimeError.failure("İlk yerel tick kalıcı değil; CLI fişi dakika sınırını bekliyor.")
        }
        for mode in [RuntimeStorage.Mode.local, .appGroup] {
            guard !RuntimeTickDelivery.shouldFlush(minute: minute, previousMinute: minute, storage: mode),
                  RuntimeTickDelivery.shouldFlush(minute: minute + 1, previousMinute: minute, storage: mode) else {
                throw RuntimeError.failure("Dakikalık flush ritmi değişti.")
            }
        }
        guard !RuntimeTickDelivery.shouldFlush(minute: minute, previousMinute: nil, storage: .appGroup) else {
            throw RuntimeError.failure("İmzalı App Group ilk tick davranışı değişti.")
        }
        // :53 launch + 75 s gate = :128. With allowed 11 s timer spacing, tick endpoints
        // :64, :75, :86, :97, :108, :119 are all in minute 1; minute 2 arrives at :130.
        let sharedLedger = try EnergyLedger(path: directory.appendingPathComponent("shared-timing.sqlite").path)
        let sharedReader = try RuntimeLedgerReader(path: directory.appendingPathComponent("shared-timing.sqlite").path)
        var previousMinute: Int64?
        for seconds in stride(from: 64, through: 119, by: 11) {
            var nextTick = tick
            nextTick.wallClock = Date(timeIntervalSince1970: Double(seconds))
            try await sharedLedger.record(nextTick)
            if RuntimeTickDelivery.shouldFlush(minute: minute, previousMinute: previousMinute, storage: .appGroup) {
                try await sharedLedger.flush()
            }
            previousMinute = minute
        }
        guard try await sharedReader.minuteRows(since: .init(timeIntervalSince1970: 0),
                                               until: .init(timeIntervalSince1970: 128)) == 0 else {
            throw RuntimeError.failure("Önceki 75 saniyelik flush gecikmesi yeniden üretilemedi.")
        }
        let report = RuntimeSmokeReport(storage: "local", ledgerPath: directory.appendingPathComponent("first-tick.sqlite").path,
                                        ticks: 1, ledgerMinuteRows: 2, watts: 2, runaways: 0, protection: "none",
                                        rules: 0, rulesActive: 0, lastDesired: "", applied: [], vetoes: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        guard json?["storage"] as? String == "local", json?["ledgerPath"] as? String == report.ledgerPath else {
            throw RuntimeError.failure("Smoke JSON depolama modu veya ledger yolunu içermiyor.")
        }
    }

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

    /// No live sampling or signals; storage checks use an isolated temporary directory.
    static func selfCheck() async throws {
        // Signed builds retain their team-prefixed App Group contract.
        if let team = signedEntitlement("com.apple.developer.team-identifier") as? String,
           appGroupIdentifier() != "\(team).dev.ohm" {
            throw RuntimeError.failure("App Group takım önekli değil (\(appGroupIdentifier() ?? "yok")); LaunchServices açılışında kapsayıcı reddedilir.")
        }
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ohm-storage-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let group = storageRoot.appendingPathComponent("group")
        let local = storageRoot.appendingPathComponent("local")
        let shared = try RuntimeStorage.select(appGroup: group, local: local)
        guard shared.mode == .appGroup, shared.directory == group,
              !FileManager.default.fileExists(atPath: local.path) else {
            throw RuntimeError.failure("App Group depolama seçimi yanlış.")
        }
        let fallback = try RuntimeStorage.select(appGroup: nil, local: local)
        // Also repair permissions on an existing directory, not just a newly created one.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
        let unavailable = storageRoot.appendingPathComponent("not-a-directory")
        try Data().write(to: unavailable)
        let denied = try RuntimeStorage.select(appGroup: unavailable, local: local)
        let permissions = try FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber
        guard fallback.mode == .local, denied.mode == .local, denied.directory == local,
              permissions?.intValue == 0o700 else {
            throw RuntimeError.failure("Yerel depolama seçimi veya 0700 izinleri yanlış.")
        }
        try await checkFirstLocalFlush(directory: local)
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
