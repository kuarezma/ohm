import AppKit
import Dispatch
import OhmForecast
import OhmGovernor
import OhmJournal
import OhmLedger
import OhmModel
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

    private init(engine: SamplingEngine, ledger: EnergyLedger, reader: RuntimeLedgerReader,
                 governor: Governor, source: LiveDataSource?) {
        self.engine = engine
        self.ledger = ledger
        self.reader = reader
        self.governor = governor
        self.source = source
    }

    @concurrent
    static func make(source: LiveDataSource?, smoke: Bool = false) async throws -> OhmRuntime {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.ohm") else {
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
        let runtime = OhmRuntime(engine: SamplingEngine.makeDefault(cadence: smoke ? .interactive : .ambient),
                                 ledger: ledger, reader: reader, governor: governor, source: source)
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
        await engine.start()
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
            guard !stopping else { return }
            await source?.apply(snapshot, events: pendingRunawayEvents)
        })
    }

    private var pendingRunawayEvents: [RunawayEvent] = []

    private func workspace(_ event: RuntimeWorkspaceEvent) async {
        guard !stopping else { return }
        switch event {
        case .applications(let apps): applications = apps
        case .governor(let event): await governor.handle(event)
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

    func setNeverFreeze(_ names: [String]) { neverFreeze = Set(names) }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
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
        return RuntimeSmokeReport(ticks: ticks,
                                  ledgerMinuteRows: try await reader.minuteRows(since: startedAt, until: Date()),
                                  watts: watts, runaways: await detector.currentRunaways.count,
                                  protection: await governor.protectionMode.rawValue)
    }
}

enum RuntimeError: LocalizedError {
    case appGroupUnavailable
    case failure(String)
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: "group.dev.ohm kapsayıcısı açılamadı. Uygulamanın App Group imzasını doğrulayın."
        case .failure(let message): message
        }
    }
}

extension OhmRuntime {
    /// No live sampling, notifications, files or signals; no extra test target.
    static func selfCheck() async throws {
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
    }
}
