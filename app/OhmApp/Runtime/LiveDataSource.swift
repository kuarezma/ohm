import AppKit
import Observation
import OhmModel
import OhmRules
import OSLog

private enum LiveAction: Sendable {
    case toggle(Effect, AppKey)
    case response(Runaway, RunawayResponse)
    case neverFreeze([String])
    case rules([Rule])
}

@MainActor
@Observable
final class LiveDataSource: OhmDataSource, AppRuntimeLifecycle {
    private(set) var systemPower = SystemPower(cpuP: 0, cpuE: 0)
    private(set) var batteryState = BatteryState(source: .unknown, percent: 0, voltage_mV: 0, amperage_mA: 0)
    private(set) var batteryForecastMinutes: Double?
    private(set) var thermalLevel: ThermalLevel = .nominal
    private(set) var todayReceipt = Receipt(interval: DateInterval(start: Date(), duration: 0))
    private(set) var runawayProcess: RunawayProcessInfo?
    private(set) var rules: [Rule] = []
    var isNLAvailable: Bool { NLRuleParser.checkAvailability() == .available }
    private(set) var neverFreezeApps: [String] = []
    private(set) var activeEffects: [AppKey: Effect] = [:]
    private(set) var ruleVetoes: [UUID: String] = [:]
    private(set) var lastError: String?

    @ObservationIgnored let ruleStore: RuleStore
    @ObservationIgnored private var runtime: OhmRuntime?
    @ObservationIgnored private var bridge: WorkspaceBridge?
    @ObservationIgnored private var notifier: RunawayNotifier?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<LiveAction>.Continuation?
    @ObservationIgnored private var currentRunaway: Runaway?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var interactive = false
    @ObservationIgnored private var failureAlert: NSAlert?

    init(ruleStore: RuleStore? = nil) {
        if let ruleStore {
            self.ruleStore = ruleStore
        } else {
            let url = RuleStore.defaultRulesURL() ?? FileManager.default.temporaryDirectory.appendingPathComponent("rules.json")
            self.ruleStore = RuleStore(fileURL: url)
        }
    }

    func start() {
        guard startup == nil, !stopping else { return }
        let bridge = WorkspaceBridge()
        bridge.setInteractive(interactive)
        self.bridge = bridge
        let (actions, continuation) = AsyncStream.makeStream(of: LiveAction.self)
        self.continuation = continuation
        let notifier = RunawayNotifier { [weak self] runaway, response in
            self?.continuation?.yield(.response(runaway, response))
        }
        self.notifier = notifier
        startup = Task(priority: .utility) { [weak self] in
            await notifier.install()
            do {
                guard let self else { return }
                let persisted = await self.ruleStore.load()
                self.rules = persisted.rules
                self.neverFreezeApps = persisted.neverFreeze
                if let warning = await self.ruleStore.corruptWarning {
                    self.showFailure(warning)
                    await self.ruleStore.clearCorruptWarning()
                }
                let runtime = try await OhmRuntime.make(source: self, ruleStore: self.ruleStore)
                guard !self.stopping else { await runtime.shutdown(); return }
                self.runtime = runtime
                await runtime.setNeverFreeze(self.neverFreezeApps)
                await runtime.setRules(self.rules)
                await runtime.start(workspace: bridge.events)
                self.actionTask = Task { [weak self] in
                    for await action in actions {
                        guard !Task.isCancelled, self?.stopping == false else { break }
                        switch action {
                        case .toggle(let effect, let key): await runtime.toggle(effect, for: key)
                        case .response(let runaway, let response): await runtime.respond(to: runaway, response: response)
                        case .neverFreeze(let names): await runtime.setNeverFreeze(names)
                        case .rules(let newRules): await runtime.setRules(newRules)
                        }
                    }
                }
            } catch {
                // An accessory app's modeless alert can stay behind other windows; keep a log trail.
                Logger(subsystem: "dev.ohm", category: "runtime")
                    .error("runtime start failed: \(String(describing: error), privacy: .public)")
                self?.showFailure(error.localizedDescription)
            }
        }
    }

    func setInteractive(_ value: Bool) {
        interactive = value
        bridge?.setInteractive(value)
    }

    func shutdown() async {
        stopping = true
        failureAlert?.window.close()
        failureAlert = nil
        bridge?.stop()
        continuation?.finish()
        actionTask?.cancel()
        // Mark Governor as shutting down before awaiting an in-flight UI action.
        if let runtime { await runtime.shutdown() }
        await startup?.value
        if let runtime { await runtime.shutdown() }
        await actionTask?.value
        actionTask = nil
        startup = nil
        bridge = nil
        notifier = nil
    }

    func apply(_ snapshot: DashboardSnapshot, events: [RunawayEvent]) async {
        guard !stopping else { return }
        systemPower = snapshot.tick.system
        batteryState = snapshot.tick.battery
        batteryForecastMinutes = snapshot.forecastMinutes
        thermalLevel = snapshot.tick.thermal
        if let receipt = snapshot.receipt { todayReceipt = receipt }
        activeEffects = snapshot.activeEffects
        if let error = snapshot.error, error != lastError { showFailure(error) }
        lastError = snapshot.error
        currentRunaway = snapshot.runaways.values.sorted { $0.app.value < $1.app.value }.first
        runawayProcess = Self.processInfo(currentRunaway)
        do { try await notifier?.handle(events) }
        catch { lastError = "Kaçak süreç bildirimi gönderilemedi: \(error.localizedDescription)" }
    }

    nonisolated static func processInfo(_ runaway: Runaway?) -> RunawayProcessInfo? {
        guard let runaway, let root = runaway.processes.first else { return nil }
        let ruleNote = runaway.app.kind != .bundleID ? "kural bu süreci hedefleyemez" : nil
        return RunawayProcessInfo(pid: root.pid, name: runaway.displayName,
                                  bundleID: runaway.app.kind == .bundleID ? runaway.app.value : nil,
                                  cpuPercent: runaway.averageCPU * 100,
                                  hiddenDurationMinutes: Int(runaway.hiddenDuration.components.seconds / 60),
                                  appKey: runaway.app,
                                  ruleNote: ruleNote)
    }

    func updateEffects(_ effects: [AppKey: Effect]) { activeEffects = effects }

    func updateRuleVetoes(_ vetoes: [UUID: String]) { ruleVetoes = vetoes }

    func vetoReason(for rule: Rule) -> String? { ruleVetoes[rule.id] }

    func selectRunaway(_ runaway: Runaway) {
        currentRunaway = runaway
        runawayProcess = Self.processInfo(runaway)
        if runaway.actions.contains(.freeze(requiresConfirmation: true)) {
            showFailure("Arka plan dondurması ek onay gerektirir; onay akışı henüz kullanıma açık değil.")
        }
    }

    func showFailure(_ message: String) {
        lastError = message
        guard !stopping else { return }
        failureAlert?.window.close()
        let alert = NSAlert()
        failureAlert = alert
        alert.messageText = "İşlem uygulanamadı"
        alert.informativeText = message
        alert.addButton(withTitle: "Tamam")
        // Modeless: a pending confirmation must never block activation/thaw delivery.
        let window = alert.window
        window.isReleasedWhenClosed = false
        if let button = alert.buttons.first {
            button.target = self
            button.action = #selector(closeFailureAlert(_:))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func closeFailureAlert(_ sender: NSButton) {
        sender.window?.close()
        failureAlert = nil
    }

    nonisolated static func vetoMessage(_ reason: FreezeVeto) -> String {
        switch reason {
        case .backgroundNeedsConfirmation: "Arka plan süreci için ek onay gerekli."
        case .protectionNotReady: "Kurtarma izleyicisi hazır değil."
        case .journalUnwritable: "Güvenlik günlüğü yazılamıyor."
        case .bootUnverified: "Oturum kimliği doğrulanamıyor; dondurma ve E-core devre dışı."
        case .recoveryPending: "Önceki oturumdan geri alınması bekleyen etkiler var."
        case .frontmost: "Öndeki uygulama dondurulamaz."
        case .notHidden: "Uygulamanın görünür pencereleri var."
        case .userNeverList: "Uygulama asla dondurulmayacaklar listesinde."
        case .notRunning: "Uygulama artık çalışmıyor."
        case .notRegularApp: "Bu uygulama türü dondurmaya uygun değil."
        case .otherUser: "Süreç başka bir kullanıcıya ait."
        case .systemPath, .appleBundle: "Korunan sistem uygulamasına işlem uygulanamaz."
        case .ohmItself: "Ohm kendi süreçlerine işlem uygulayamaz."
        case .recentlyActive, .refreezeGrace: "Uygulama yakın zamanda kullanıldı; biraz bekleyin."
        case .audio, .camera: "Uygulama ses veya kamera kullanıyor."
        case .powerAssertion: "Uygulamanın sürdürmesi gereken bir sistem işi var."
        case .eventTap: "Uygulama klavye veya fare girdilerini yönetiyor."
        case .outOfBundleChild: "Uygulamanın paket dışında çalışan bağlı süreçleri var."
        case .debugged: "Süreç bir hata ayıklayıcı tarafından izleniyor."
        case .unsavedDocument: "Uygulamada kaydedilmemiş bir belge var."
        case .safetyProbeFailed: "Sürecin güvenli olduğu doğrulanamadı."
        case .powerOffInProgress: "Sistem kapanmaya hazırlanıyor."
        case .postWakeQuiet: "Sistem yeni uyandı; koruma bekleme süresi sürüyor."
        case .shuttingDown: "Ohm kapanıyor."
        case .unstableTree: "Uygulamanın süreç ağacı değişmeye devam ediyor."
        case .unsafeTopology, .unverifiedTopology: "Bu uygulamanın güvenli dondurulması doğrulanmadı."
        case .superseded, .notDesired: "İstek artık geçerli değil."
        case .busy: "Bu süreç için başka bir işlem sürüyor."
        case .tableFull: "Kurtarma kapasitesi dolu; yeni işlem uygulanamaz."
        }
    }

    func showVetoes(_ reasons: [FreezeVeto]) {
        let messages = reasons.map(Self.vetoMessage)
        showFailure(messages.joined(separator: "\n"))
    }

    func toggleECore(for appKey: AppKey) { continuation?.yield(.toggle(.eCore, appKey)) }
    func toggleFreeze(for appKey: AppKey) { continuation?.yield(.toggle(.freeze, appKey)) }
    func moveRunawayToECores() { respond(.eCore) }
    func freezeRunaway() { respond(.freeze(requiresConfirmation: false)) }
    func quitRunaway() { respond(.quit) }

    private func respond(_ action: RunawayAction) {
        guard let runaway = currentRunaway else { return }
        continuation?.yield(.response(runaway, runaway.response(to: action)))
    }

    func addRule(description: String) {
        guard isNLAvailable else {
            showFailure("Canlı kural yönetimi henüz kullanıma açık değil.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            do {
                let parser = NLRuleParser()
                let draft = try await parser.parse(sentence: description)
                switch draft {
                case .ready(var rule):
                    rule.enabled = false
                    try await self.ruleStore.addRule(rule)
                    self.rules = await self.ruleStore.rules
                    self.continuation?.yield(.rules(self.rules))
                case .needsClarification(_, let questions):
                    let prompt = questions.map(\.question).joined(separator: "\n")
                    self.showFailure(prompt.isEmpty ? "Kural netleştirme gerektiriyor." : prompt)
                case .unsupported(let phrases):
                    self.showFailure("Desteklenmeyen ifadeler: " + phrases.joined(separator: ", "))
                }
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }

    func toggleRule(_ rule: Rule) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try await self.ruleStore.toggleRule(id: rule.id)
                self.rules = await self.ruleStore.rules
                self.continuation?.yield(.rules(self.rules))
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }

    func deleteRule(_ rule: Rule) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try await self.ruleStore.deleteRule(id: rule.id)
                self.rules = await self.ruleStore.rules
                self.continuation?.yield(.rules(self.rules))
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }

    func addNeverFreezeApp(_ appName: String) {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !neverFreezeApps.contains(name) else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try await self.ruleStore.addNeverFreeze(name)
                self.neverFreezeApps = await self.ruleStore.neverFreeze
                self.continuation?.yield(.neverFreeze(self.neverFreezeApps))
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }

    func removeNeverFreezeApp(_ appName: String) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try await self.ruleStore.removeNeverFreeze(appName)
                self.neverFreezeApps = await self.ruleStore.neverFreeze
                self.continuation?.yield(.neverFreeze(self.neverFreezeApps))
            } catch {
                self.showFailure(error.localizedDescription)
            }
        }
    }
}
