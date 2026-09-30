import AppKit
import Observation
import OhmControl
import OhmLedger
import OhmModel
import OhmRules
import OSLog

private enum LiveAction: Sendable {
    case toggle(Effect, AppKey, confirmedBackground: Bool)
    case response(Runaway, RunawayResponse)
    case neverFreeze([String])
    case rules([Rule])
    case thawAll
}

struct RuleAppChoice: Identifiable {
    let id: String
    let apps: [AppRef]
}

@MainActor
@Observable
final class LiveDataSource: OhmDataSource, AppRuntimeLifecycle {
    private var confirmationAlert: NSAlert?
    private var confirmationAction: (() -> Void)?
    private(set) var ruleAppChoices: [RuleAppChoice] = []
    private var generatedRule: GeneratedRule?
    private var generatedSentence = ""
    private var selectedRuleApps: [String: [AppRef]] = [:]
    private(set) static weak var intentSource: LiveDataSource?
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
    var pendingRule: Rule?
    private(set) var isRuleBusy = false
    private(set) var ruleMessage: String?
    private(set) var hasSample = false
    private(set) var manageableApps: Set<AppKey> = []
    @ObservationIgnored private var ruleTask: Task<Void, Never>?

    private(set) var isLocalStorage = false
    @ObservationIgnored private let hasInjectedRuleStore: Bool
    @ObservationIgnored private(set) var ruleStore: RuleStore
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
    @ObservationIgnored private let widgetRefresh = WidgetRefreshCoordinator()

    init(ruleStore: RuleStore? = nil) {
        hasInjectedRuleStore = ruleStore != nil
        if let ruleStore {
            self.ruleStore = ruleStore
        } else {
            let url = EnergyLedger.localDataDirectory().appendingPathComponent("rules.json")
            self.ruleStore = RuleStore(fileURL: url)
        }
        Self.intentSource = self
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
                let storage = try await RuntimeStorage.prepare()
                self.isLocalStorage = storage.mode == .local
                if !self.hasInjectedRuleStore {
                    self.ruleStore = RuleStore(fileURL: storage.directory.appendingPathComponent("rules.json"))
                }
                let persisted = await self.ruleStore.load()
                self.rules = persisted.rules
                self.neverFreezeApps = persisted.neverFreeze
                if let warning = await self.ruleStore.corruptWarning {
                    self.showFailure(warning)
                    await self.ruleStore.clearCorruptWarning()
                }
                let runtime = try await OhmRuntime.make(source: self, ruleStore: self.ruleStore, storage: storage)
                guard !self.stopping else { await runtime.shutdown(); return }
                self.runtime = runtime
                await runtime.setNeverFreeze(self.neverFreezeApps)
                await runtime.setRules(self.rules)
                await runtime.start(workspace: bridge.events)
                self.actionTask = Task { [weak self] in
                    for await action in actions {
                        guard !Task.isCancelled, self?.stopping == false else { break }
                        switch action {
                        case .toggle(let effect, let key, let confirmed):
                            await runtime.toggle(effect, for: key, confirmedBackground: confirmed)
                        case .response(let runaway, let response): await runtime.respond(to: runaway, response: response)
                        case .neverFreeze(let names): await runtime.setNeverFreeze(names)
                        case .rules(let newRules): await runtime.setRules(newRules)
                        case .thawAll:
                            let result = await runtime.handleControl(ControlRequest(operation: .thawAll), origin: .manual)
                            if !result.success { self?.showFailure(result.message) }
                        }
                        self?.reloadWidget()
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
        confirmationAlert?.window.close()
        confirmationAlert = nil
        confirmationAction = nil
        ruleTask?.cancel()
        widgetRefresh.stop()
        if Self.intentSource === self { Self.intentSource = nil }
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
        await ruleTask?.value
        ruleTask = nil
        actionTask = nil
        startup = nil
        bridge = nil
        notifier = nil
    }

    func apply(_ snapshot: DashboardSnapshot, events: [RunawayEvent]) async {
        guard !stopping else { return }
        hasSample = true
        manageableApps = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return nil }
            return AppKey(kind: .bundleID, value: bundleID)
        })
        widgetRefresh.observe(snapshot.tick.wallClock)
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

    func reloadWidget() { if !stopping { widgetRefresh.request() } }

    private func intentRuntime() async throws -> OhmRuntime {
        start()
        await startup?.value
        guard !stopping, let runtime else { throw RuntimeError.failure(lastError ?? "Ohm henüz hazır değil.") }
        return runtime
    }

    func performIntent(_ request: ControlRequest) async throws -> ControlResponse {
        let runtime = try await intentRuntime()
        return await runtime.handleControl(request, origin: .manual)
    }

    func intentReceipt() async throws -> Receipt {
        let runtime = try await intentRuntime()
        return try await runtime.intentReceipt()
    }

    func updateRuleVetoes(_ vetoes: [UUID: String]) { ruleVetoes = vetoes }

    func vetoReason(for rule: Rule) -> String? { ruleVetoes[rule.id] }

    func selectRunaway(_ runaway: Runaway) {
        currentRunaway = runaway
        runawayProcess = Self.processInfo(runaway)
        if runaway.actions.contains(.freeze(requiresConfirmation: true)) {
            showFailure("Dondurmak için Ohm menüsündeki kaçak süreç kartında Dondur düğmesine basıp onay verin.")
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
        alert.layout()
        // Modeless: a pending confirmation must never block activation/thaw delivery.
        let window = alert.window
        window.isReleasedWhenClosed = false
        if let button = alert.buttons.first {
            button.target = self
            button.action = #selector(closeFailureAlert(_:))
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func requestConfirmation(title: String, message: String, button: String, action: @escaping () -> Void) {
        guard !stopping else { return }
        confirmationAlert?.window.close()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Vazgeç")
        alert.addButton(withTitle: button)
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(resolveConfirmation(_:))
        }
        confirmationAction = action
        confirmationAlert = alert
        alert.layout()
        alert.window.isReleasedWhenClosed = false
        alert.window.title = "İşlem onayı"
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func resolveConfirmation(_ sender: NSButton) {
        guard confirmationAlert?.buttons.contains(where: { $0 === sender }) == true else { return }
        let action = confirmationAction
        confirmationAction = nil
        confirmationAlert?.window.close()
        confirmationAlert = nil
        if sender.tag == 1, !stopping { action?() }
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

    func toggleECore(for appKey: AppKey) { continuation?.yield(.toggle(.eCore, appKey, confirmedBackground: false)) }
    func thawAll() { continuation?.yield(.thawAll) }
    func toggleFreeze(for appKey: AppKey) { continuation?.yield(.toggle(.freeze, appKey, confirmedBackground: false)) }
    func confirmFreeze(for appKey: AppKey) { continuation?.yield(.toggle(.freeze, appKey, confirmedBackground: true)) }
    func moveRunawayToECores(for app: AppKey, pid: Int32) {
        guard let runaway = currentRunaway, runaway.app == app,
              runaway.processes.first?.pid == pid else {
            showFailure("Kaçak süreç değişti; kartı yeniden kontrol edin.")
            return
        }
        continuation?.yield(.response(runaway, runaway.response(to: .eCore)))
    }
    func confirmRunawayFreeze(for app: AppKey, pid: Int32) {
        guard let runaway = currentRunaway, runaway.app == app,
              let root = runaway.processes.first, root.pid == pid else {
            showFailure("Kaçak süreç değişti; kartı yeniden kontrol edin.")
            return
        }
        continuation?.yield(.response(runaway, .commands([
            .freeze(pid: root.pid, origin: .runaway, confirmedBackground: true)
        ])))
    }
    func confirmRunawayQuit(for app: AppKey, pid: Int32) {
        guard let runaway = currentRunaway, runaway.app == app,
              runaway.processes.first?.pid == pid else {
            showFailure("Kaçak süreç değişti; kartı yeniden kontrol edin.")
            return
        }
        continuation?.yield(.response(runaway, runaway.response(to: .quit)))
    }
    func moveRunawayToECores() { respond(.eCore) }
    func freezeRunaway() { respond(.freeze(requiresConfirmation: false)) }
    func quitRunaway() { respond(.quit) }

    private func respond(_ action: RunawayAction) {
        guard let runaway = currentRunaway else { return }
        continuation?.yield(.response(runaway, runaway.response(to: action)))
    }

    func addRule(description: String) {
        guard !isRuleBusy, pendingRule == nil, !stopping else { return }
        guard isNLAvailable else {
            ruleMessage = "Doğal dil kuralları için Apple Intelligence’ın açık ve cihaz içi modelin hazır olması gerekir."
            return
        }
        isRuleBusy = true
        ruleMessage = nil
        ruleAppChoices = []
        selectedRuleApps = [:]
        generatedRule = nil
        ruleTask = Task { @MainActor [weak self] in
            guard let self, !self.stopping else { return }
            defer { self.isRuleBusy = false }
            do {
                let parser = NLRuleParser()
                let generated = try await parser.generate(from: description)
                guard !Task.isCancelled, !self.stopping else { return }
                self.generatedRule = generated
                self.generatedSentence = description
                self.prepareRuleDraft()
            } catch {
                if !Task.isCancelled { self.ruleMessage = error.localizedDescription }
            }
        }
    }

    func selectRuleApp(_ app: AppRef, for name: String, sentence: String) {
        guard !isRuleBusy, pendingRule == nil, !stopping,
              sentence == generatedSentence,
              ruleAppChoices.contains(where: { $0.id == name && $0.apps.contains(app) }) else { return }
        selectedRuleApps[name.lowercased()] = [app]
        prepareRuleDraft()
    }

    private func prepareRuleDraft() {
        guard let generated = generatedRule else { return }
        let resolver = DefaultAppResolver(customMappings: selectedRuleApps)
        let draft = RuleCompiler(appResolver: resolver).compile(generated: generated, rawSentence: generatedSentence)
        let names = Set(generated.targetApps + generated.conditions.compactMap(\.appName))
        ruleAppChoices = names.sorted().compactMap { name in
            let apps = resolver.resolve(appName: name)
            guard apps.count != 1 else { return nil }
            let candidates = apps.isEmpty ? NSWorkspace.shared.runningApplications.compactMap { application -> AppRef? in
                guard application.activationPolicy == .regular,
                      let id = application.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return AppRef(bundleID: id, displayName: application.localizedName ?? id)
            }.sorted { $0.displayName < $1.displayName } : apps
            return RuleAppChoice(id: name, apps: candidates)
        }
        switch draft {
        case .ready(var rule):
            rule.enabled = false
            self.pendingRule = rule
            self.ruleAppChoices = []
            self.ruleMessage = nil
        case .needsClarification(_, let questions):
            let prompt = Array(Set(questions.map(\.question))).sorted().joined(separator: "\n")
            self.ruleMessage = (prompt.isEmpty ? "Kural netleştirme gerektiriyor." : prompt)
                + "\nAdayı seçin veya cümlenizi netleştirin; henüz kural kaydedilmedi."
        case .unsupported(let phrases):
            self.ruleAppChoices = []
            self.ruleMessage = "Desteklenmeyen ifadeler: " + phrases.joined(separator: ", ")
        }
    }

    func savePendingRule(enabled: Bool) {
        guard var rule = pendingRule, !isRuleBusy, !stopping else { return }
        rule.enabled = enabled
        isRuleBusy = true
        ruleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRuleBusy = false }
            do {
                try await self.ruleStore.addRule(rule)
                self.rules = await self.ruleStore.rules
                self.continuation?.yield(.rules(self.rules))
                self.pendingRule = nil
                self.ruleMessage = enabled ? "Kural kaydedildi ve etkinleştirildi." : "Kural kapalı olarak kaydedildi."
            } catch {
                self.ruleMessage = "Kural kaydedilemedi: \(error.localizedDescription)"
            }
        }
    }

    static func ruleReviewSelfCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ohm-rule-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let ruleStore = RuleStore(fileURL: file)
        let source = LiveDataSource(ruleStore: ruleStore)
        let chosenApp = AppRef(bundleID: "dev.example.OhmTest", displayName: "Test")
        source.generatedSentence = "Test pildeyken E-core kullan."
        source.generatedRule = GeneratedRule(name: "Seçim testi", targetApps: ["Test"], actions: [.eCore],
                                             match: .all, conditions: [GeneratedCondition(kind: .onBattery)])
        source.ruleAppChoices = [RuleAppChoice(id: "Test", apps: [chosenApp])]
        source.selectRuleApp(chosenApp, for: "Test", sentence: "Değişmiş cümle")
        guard source.pendingRule == nil else { throw RuntimeError.failure("Eski cümleye ait aday uygulandı.") }
        source.selectRuleApp(chosenApp, for: "Test", sentence: source.generatedSentence)
        guard let selected = source.pendingRule, selected.targets == .apps([chosenApp]),
              selected.when == .powerSource(.battery), !selected.enabled else {
            throw RuntimeError.failure("Uygulama seçiminde koşul veya hedef korunmadı.")
        }
        var draft = Rule(name: "Onay testi", enabled: false, source: .manual, when: .always,
                         targets: .apps([AppRef(bundleID: "dev.example.OhmTest", displayName: "Test")]),
                         actions: [.eCore()])
        source.pendingRule = draft
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw RuntimeError.failure("Onaylanmamış taslak diske yazıldı.")
        }
        source.savePendingRule(enabled: true)
        await source.ruleTask?.value
        draft.enabled = true
        let persisted = await RuleStore(fileURL: file).load()
        guard persisted.rules == [draft], source.pendingRule == nil, source.rules == [draft] else {
            throw RuntimeError.failure("Kullanıcı onayından sonra kural etkin kaydedilemedi.")
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        draft.id = UUID()
        source.pendingRule = draft
        source.savePendingRule(enabled: false)
        await source.ruleTask?.value
        guard source.pendingRule?.id == draft.id, source.rules.count == 1,
              source.ruleMessage?.contains("kaydedilemedi") == true else {
            throw RuntimeError.failure("Kaydetme hatasında taslak korunmadı veya başarı bildirildi.")
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
