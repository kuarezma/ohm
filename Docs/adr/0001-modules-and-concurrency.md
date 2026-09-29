# ADR 0001: Modül sınırları ve eşzamanlılık modeli

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü bekleniyor. Faz 0 spike sonuçları işlendi (`spikes/README.md`, `main` 5773b60).
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0002 (ledger), ADR 0003 (kural DSL'i), ADR 0004 (dondurma güvenliği), `Docs/PLAN.md` § Mimari

## Bağlam

Ohm; menü çubuğu uygulaması, widget, `ohm` CLI ve dondurma güvenliği için bir izleyici süreçten oluşuyor. Bunların hepsi aynı çekirdek mantığı paylaşıyor. Kısıtlar şunlar:

- **Hafiflik (kabul ölçütü):** Boştayken bellek <40 MB ve CPU ortalaması <%0,5. Popover açıkken örnekleme 1 sn, kapalıyken 10 sn. Ohm'un kendi işi `.utility` veya `.background` QoS ile yapılır.
- **Swift 6 strict concurrency** (araç zinciri Swift 6.4). Veri yarışı derleme hatasıdır.
- **Özel API riski gerçekleşti (T-010 PARTIAL).** macOS 27'de IOReport "Energy Model" grubundaki CPU, DRAM ve ANE sayaçları saniyelik güncellenmiyor; yalnız seyrek "patlamalar" halinde yayımlanıyor. Saniyelik canlı olanlar iki kanal: `GPU Energy` (nJ) ve "CPU Stats" küme doluluğu (residency). Sistem gücü `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` (mW) ile hem pilde hem adaptörde okunabiliyor, ama ~20 sn'de bir güncelleniyor. `Voltage × Amperage` yalnız deşarjda sistem gücüdür. Özel API'ye bağlı kod tek bir modülde ve protokollerin arkasında durmalı.
- **Sandbox sınırı:** WidgetKit uzantısı sandbox'lı çalışmak zorunda. Ana uygulama başka süreçlere sinyal gönderdiği için sandbox'sız, Developer ID ile imzalı. Widget özel API'lere ve sinyal koduna bağlanmamalı.
- **Tek yazar:** SQLite ledger'ına ve dondurma journal'ına yalnız bir süreç yazmalı. Aksi halde kilit çekişmesi ve bozulma riski doğar.
- **Dağıtım hedefi (kullanıcı kararı, 2026-09-29):** En düşük sürüm **macOS 26**, yalnız Apple Silicon. `Package.swift` içinde `platforms: [.macOS(.v26)]`, `project.yml` içinde `MACOSX_DEPLOYMENT_TARGET = 26.0`. Planın "macOS 15+" satırı bu kararla değişti (site ve README buna göre güncellenmeli).

## Karar

### 1. Paket ve hedef yapısı

`app/OhmCore/Package.swift` tek bir SwiftPM paketi. Plandaki beş klasör ayrı **target** olur. Böylece bağımlılık yönü derleyici tarafından zorlanır.

| Target | Tür | İçerik | Bağımlılıklar |
|---|---|---|---|
| `OhmModel` | Swift | Yalnız değer tipleri: kimlikler, örnekler, fiş satırları, `Rule` modeli, komutlar. Hepsi `Sendable`, çoğu `Codable`. | – |
| `COhmSys` | C | IOReport prototipleri; `responsibility_get_pid_responsible_for_pid` (`dlsym`, libquarantine); async-signal-safe çözme tablosu (ADR 0004). IOReport, `dlopen("/usr/lib/libIOReport.dylib")` ve `dlsym` ile yüklenir. Kütüphane dosya olarak yok, dyld paylaşımlı önbelleğinde; spike, SDK'daki `libIOReport.tbd` ile `-lIOReport` bağlamanın çalıştığını gösterdi. Yine de gelecekteki bir macOS'ta sembol kalkarsa uygulama açılışta çökmesin, yalnız IOReport özellikleri kapansın diye sert bağlama yapılmaz. `dlopen`'ın paylaşımlı önbellekteki yolu çözdüğü T-021'de doğrulanır; çözmezse zayıf bağlama (`-weak-lIOReport`) kullanılır. | – |
| `OhmSampling` | Swift | `ProcessEnergySampler` (`ri_energy_nj`), `SystemLoadSampler` (`PowerTelemetryData.SystemLoad`, deşarjda `V × I` yedeği), `IOReportSampler` (canlı `GPU Energy` ve küme doluluğu; CPU, DRAM ve ANE için patlama yakalayıcı), `BatterySampler`, `ThermalSampler`, `AttributionResolver`, `SamplingEngine` | `OhmModel`, `COhmSys` |
| `OhmLedger` | Swift | `EnergyLedger` (yazar), `LedgerReader` (salt okunur), migration'lar | `OhmModel` (sistem `sqlite3`) |
| `OhmJournal` | Swift | `FreezeJournal`, `JournalRecovery`, `ProcessIdentity` doğrulama | `OhmModel`, `COhmSys` |
| `OhmGovernor` | Swift | `Governor`, `ECoreLane`, `Freezer`, `SafetyPolicy`, `RunawayDetector` | `OhmModel`, `OhmJournal`, `COhmSys` |
| `OhmRules` | Swift | `RuleEngine`, `RuleCompiler`, `NLRuleParser` (FoundationModels; derleme zamanı koşulu yok) | `OhmModel` |
| `OhmForecast` | Swift | `BatteryForecaster` | `OhmModel` |
| `OhmControl` | Swift | CLI ile uygulama arasındaki kontrol soketinin mesajları ve istemcisi | `OhmModel` |

Ürünler (products) ve tüketiciler:

| Tüketici | Hedef | Bağlandığı target'lar | Neden |
|---|---|---|---|
| `OhmApp` | Xcode app, sandbox'sız, Developer ID | Hepsi | Kompozisyon kökü |
| `OhmWidget` | WidgetKit uzantısı, sandbox'lı | `OhmModel`, `OhmLedger` (yalnız `LedgerReader`) | Özel API ve sinyal kodu widget'a girmez |
| `ohm-cli` | Komut satırı, `Ohm.app/Contents/MacOS/ohm` | `OhmModel`, `OhmLedger` (okuyucu), `OhmControl`, `OhmJournal` (acil `thaw --all`) | Canlı değişiklikler uygulama üzerinden geçer |
| `ohm-thawd` | LaunchAgent, `Ohm.app/Contents/MacOS/ohm-thawd` | `OhmJournal`, `COhmSys` | ADR 0004'teki izleyici; mümkün olan en küçük süreç |

Kurallar:
- Target'lar arasında döngü yok. `OhmRules`, `OhmGovernor`'ı import etmez: kural motoru "istenen durumu" (`DesiredState`) üretir, `Governor` uygular. `OhmGovernor` de `OhmSampling`'i import etmez; `RunawayDetector` örnekleri `OhmModel` tipleriyle alır.
- Özel API (IOReport, responsibility SPI) yalnız `COhmSys` ve `OhmSampling` içinde bulunur. Widget'ın ikili dosyasında bu semboller yer almaz.
- Yeni bir üçüncü taraf bağımlılık eklenmez (plan: yalnız Sparkle ve swift-argument-parser).
- **Tek kod yolu:** Hedef macOS 26 olduğu için FoundationModels, Liquid Glass ve App Intents için `#available` veya `#if canImport` dalı yazılmaz. Tek çalışma zamanı kontrolü Apple Intelligence içindir: `SystemLanguageModel.default.availability` ve `supportsLocale(_:)`. Apple Intelligence kullanıcı tarafından kapatılmış olabilir, cihazda hazır olmayabilir veya kullanıcının dilini desteklemeyebilir; bu durumlarda yalnız doğal dilde kural girişi gizlenir (ADR 0003).

### 2. Modüller arası protokoller

Protokoller `OhmModel` içinde tanımlanır; somut tipler kendi target'larında yaşar. Testler sahte (fake) uygulamaları bu protokoller üzerinden verir.

```swift
// MARK: OhmModel — değer tipleri (özet)
public struct ProcessIdentity: Hashable, Sendable, Codable {        // pid yeniden kullanımına karşı
    public var pid: Int32
    public var startAbs: UInt64                                      // ri_proc_start_abstime (mach abs); önyükleme
                                                                     // oturumu (kern.bootsessionuuid) ile birlikte geçerli
}
public enum AttributionKind: Int, Sendable, Codable { case bundleID = 0, executableName = 1, processName = 2 }
public struct AppKey: Hashable, Sendable, Codable {                  // ADR 0002'deki kalıcı atıf anahtarı
    public var kind: AttributionKind
    public var value: String
}
public enum PowerSourceKind: String, Sendable, Codable { case battery, ac, unknown }
public enum ThermalLevel: Int, Sendable, Codable, Comparable { case nominal, fair, serious, critical }

public struct SystemPower: Sendable {                                // bir aralığın ortalaması, watt
    public var cpuP: Double, cpuE: Double          // Σ okunabilen süreçlerin Δri_penergy_nj ve Δ(ri_energy_nj − ri_penergy_nj)
    public var gpu: Double?                        // IOReport "GPU Energy" (nJ, canlı); yoksa nil
    public var systemLoad: Double?                 // PowerTelemetryData.SystemLoad (~20 sn tazelik); yoksa deşarjda V × I
    public var systemLoadAge: Duration?            // son SystemLoad güncellemesinden beri geçen süre
    public var clusterActive: ClusterResidency?    // IOReport "CPU Stats" P/E doluluğu (canlı)
}
public struct EnergyBurst: Sendable {             // IOReport "Energy Model" patlaması: seyrek, uzun pencere
    public var window: DateInterval               // önceki patlamadan bu patlamaya
    public var cpu_mJ: Double?, dram_mJ: Double?, ane_mJ: Double?
}
public struct BatteryState: Sendable, Codable {
    public var source: PowerSourceKind
    public var percent: Int
    public var voltage_mV: Int, amperage_mA: Int
    public var systemLoad_mW: Int?                // PowerTelemetryData.SystemLoad; pilde ve adaptörde geçerli
    public var rawCurrentCapacity_mAh: Int?, fullChargeCapacity_mAh: Int?
    public var isCharging: Bool
}
public struct ProcessDelta: Sendable {
    public var identity: ProcessIdentity
    public var app: AppKey                                            // atıf sonrası (helper → ana uygulama)
    public var energy_nJ: UInt64, pEnergy_nJ: UInt64, cpuTime_ns: UInt64
}
public struct SampleTick: Sendable {
    public var wallClock: Date
    public var interval: Duration                                     // bir önceki tick'ten beri, monotonik
    public var system: SystemPower
    public var burst: EnergyBurst?                                    // bu tick'te bir IOReport patlaması geldiyse
    public var battery: BatteryState
    public var thermal: ThermalLevel
    public var processes: [ProcessDelta]
    public var unreadable: UnreadableSummary                          // okunamayan süreç sayısı (root vb.)
}

public enum SamplingCadence: Sendable, Equatable {
    case interactive        // popover açık: 1 sn
    case ambient            // popover kapalı: 10 sn
    case suspended          // ekran uykuda / sistem uykuda: sayaç okuması yok
}

// MARK: Örnekleme
public protocol SystemLoadSampling: Sendable {                       // SystemLoadSampler; yedek: deşarjda V × I
    func read() async -> (watts: Double?, age: Duration?)
}
public protocol ComponentSampling: Sendable {                        // IOReportSampler; yoksa NullComponentSampler
    func sample() async -> (gpuWatts: Double?, residency: ClusterResidency?, burst: EnergyBurst?)
}
public protocol ProcessEnergySampling: Sendable {
    func sample() async -> (deltas: [ProcessDelta], unreadable: UnreadableSummary)
}
public protocol BatterySampling: Sendable { func read() async -> BatteryState }

public protocol SamplingEngineProtocol: Actor {
    func setCadence(_ cadence: SamplingCadence)
    nonisolated var ticks: AsyncStream<SampleTick> { get }            // tek tüketici: OhmRuntime
}

// MARK: Ledger (ADR 0002)
public protocol EnergyLedgerWriting: Actor {
    func record(_ tick: SampleTick) async throws                      // bellekte dakika kovasına ekler
    func flush() async throws                                          // dakika sınırında tek transaction
    func maintain(now: Date) async throws                             // rollup + budama + incremental_vacuum
}
public protocol EnergyLedgerReading: Sendable {                       // widget ve CLI için eşzamanlı (sync)
    func receipt(for interval: DateInterval, source: PowerSourceKind?) throws -> Receipt
    func systemSeries(for interval: DateInterval, resolution: LedgerResolution) throws -> [SystemPoint]
}

// MARK: Governor (ADR 0004)
public enum Effect: Int, Sendable, Codable, Comparable { case none = 0, eCore = 1, freeze = 2 }
public enum EffectOrigin: Sendable, Hashable, Codable { case manual, rule(UUID), runaway, cli }
public struct DesiredEffect: Sendable, Equatable {
    public var requested: Set<Effect>          // Governor, güvenlik vetosundan geçen en yüksek etkiyi uygular
    public var origins: [Effect: Set<EffectOrigin>]
}
public struct DesiredState: Sendable, Equatable {                     // kural motorunun çıktısı
    public var effects: [AppKey: DesiredEffect]
}
public protocol Governing: Actor {
    func reconcile(_ desired: DesiredState) async -> ReconcileReport  // kurallardan gelen katman
    func perform(_ command: GovernorCommand) async -> GovernorOutcome // elle / CLI / kaçak süreç kartı
    func thawAll(reason: ThawReason) async -> ThawReport
    nonisolated var events: AsyncStream<GovernorEvent> { get }
}

// MARK: Kurallar (ADR 0003)
public protocol RuleEvaluating: Actor {
    func update(rules: [Rule])
    func evaluate(_ context: RuleContext) -> RuleEvaluation            // DesiredState + bildirim kenarları
}
public protocol NaturalLanguageRuleParsing: Sendable {
    func parse(_ text: String, locale: Locale) async throws -> RuleDraft   // her zaman kullanıcı onayına gider
}

// MARK: Tahmin
public protocol BatteryForecasting: Actor {
    func observe(_ tick: SampleTick)
    func forecast() -> BatteryForecast?
}
```

Kompozisyon kökü `OhmApp` içinde bir `actor OhmRuntime`'dır. `ticks` akışını tek başına tüketir ve her tick'i sırayla dağıtır: önce `ledger.record` çağrılır (kayıp olmaması için `await` edilir, doğal geri basınç sağlar). Ardından `forecaster.observe` ve `runawayDetector.observe` çalışır. Son olarak UI'a `DashboardSnapshot` gider. Kural değerlendirmesi tick'e değil bağlam olaylarına bağlıdır (ADR 0003).

### 3. Eşzamanlılık modeli (Swift 6)

| Tip | İzolasyon | Yürütücü (executor) ve QoS | Gerekçe |
|---|---|---|---|
| `SamplingEngine` | `actor` | Özel `DispatchSerialQueue(label: "dev.ohm.sampling", qos: .utility)` | IOReport ve `proc_pid_rusage` çağrıları eşzamanlı (sync) ve kısa süre bloklayabilir. İş işbirlikçi (cooperative) havuzu bloklamamalı. `.utility` işi E-core'a yönlendirir. |
| `IOReportSampler`, `ProcessEnergySampler` | `SamplingEngine`'e ait, `Sendable` olmayan `final class` | Aktörün içinde | CF nesneleri (`IOReportSubscriptionRef`, `CFDictionary`) aktörü hiç terk etmez. Bu yüzden `@unchecked Sendable` kullanılmaz. |
| `EnergyLedger` | `actor` | `DispatchSerialQueue(label: "dev.ohm.ledger", qos: .utility)`; bakım işleri `.background` | Tek `sqlite3*` yazma bağlantısı. Bloklayan G/Ç işbirlikçi havuzun dışında kalır. |
| `LedgerReader` | `final class`, `Sendable` değil | Çağıranın bağlamı (widget timeline provider, CLI ana iş parçacığı) | Salt okunur bağlantı, kısa ömürlü. Süreçler arası paylaşılmaz. |
| `Governor` | `actor` | `DispatchSerialQueue(label: "dev.ohm.governor", qos: .userInitiated)` | Çözme yolu gecikmeye duyarlı (hedef: aktivasyondan <300 ms). Dondurma işleri seyrek ve kısa. Journal G/Ç'si de bu kuyrukta. |
| `RuleEngine`, `BatteryForecaster`, `RunawayDetector` | `actor` (varsayılan yürütücü) | Çağrı `Task(priority: .utility)` içinden | Saf hesap, bloklamaz. |
| `NLRuleParser` | `Sendable` `struct` | `Task(priority: .userInitiated)` | Kullanıcı sonucu bekliyor. `LanguageModelSession` çağrı başına kurulur, sonra bırakılır. |
| `OhmRuntime` | `actor` | Varsayılan | Yalnız bağlantı ve dağıtım işi yapar. |
| `WorkspaceObserver` | `@MainActor final class` | Ana iş parçacığı | `NSWorkspace` bildirimleri ana kuyruğa gelir. Bunlar `AsyncStream<WorkspaceEvent>`'e çevrilip `Governor` ve `RuleEngine`'e iletilir. |
| `AppModel` ve bütün görünüm durumu | `@MainActor @Observable final class` | Ana | Yalnız `DashboardSnapshot` (değer tipi) alır. |

- **App target'ı** Swift 6.2'deki varsayılan izolasyonu kullanır (`defaultIsolation(MainActor.self)`). **OhmCore target'ları** varsayılan olarak `nonisolated` kalır; izolasyon açıkça `actor` ile verilir. Böylece çekirdek kodun yanlışlıkla ana iş parçacığında çalışması engellenir.
- **Sınırı geçen her tip değer tipidir** (`struct` veya `enum`, `Sendable`). Sınırı sınıf geçmez. `@unchecked Sendable` ve `nonisolated(unsafe)` yalnız `COhmSys` sarmalayıcısında, gerekçe yorumuyla birlikte kullanılabilir. Tek istisna ADR 0004'teki sinyal tablosu: C tarafında `_Atomic` dizi olarak durur.
- **Akış politikaları:** `ticks` kaybetmez (`.unbounded`; tick'ler seyrek, tüketici `await` ederek ilerliyor). UI'a giden `DashboardSnapshot` akışı `.bufferingNewest(1)` kullanır, çünkü eski kareler çizilmez. `GovernorEvent` akışı `.bufferingNewest(64)` kullanır.
- **İptal:** Her uzun döngü `Task.isCancelled` kontrol eder. Uygulama kapanışında ADR 0004'teki `thawAll` çalışır; bu çağrı iptal edilmeden, eşzamanlı olarak ve süre sınırı içinde tamamlanır.

### 4. Uyarlamalı örnekleme

- **Durum makinesi:** Popover içeriğinin `onAppear` olayı `interactive` (1 sn), `onDisappear` olayı `ambient` (10 sn) durumuna geçirir. `NSWorkspace.screensDidSleepNotification` ve `willSleepNotification` `suspended` durumuna, `screensDidWake` ve `didWake` önceki duruma döndürür.
- **Zamanlayıcı:** `ContinuousClock` ile `sleep(for: interval, tolerance: interval / 10)`. Toleransın amacı çekirdeğin uyanmaları birleştirebilmesi (timer coalescing). Periyodik bir `Timer` kullanılmaz.
- **Kaynaklar ve tazelikleri (Faz 0'da ölçüldü, M3 ve macOS 27):**

| Gösterilen değer | Kaynak | Tazelik | Not |
|---|---|---|---|
| Canlı CPU watt'ı, P ve E ayrı | Okunabilen süreçlerin `Δri_penergy_nj` ve `Δ(ri_energy_nj − ri_penergy_nj)` toplamı | Her tick | Root ve başka kullanıcıların süreçleri dahil değil (~668 pid'in ~268'i `EPERM`). Arayüz bu değeri "uygulamaların CPU gücü" diye adlandırır, "CPU gücü" demez. |
| Canlı GPU watt'ı | IOReport "Energy Model" → `GPU Energy` (nJ) | Her tick | macOS 27'de saniyelik güncellenen tek enerji kanalı |
| P/E küme doluluğu | IOReport "CPU Stats" / "CPU Core Performance States" durum yerleşimi | Her tick | `IDLE`, `OFF` ve `DOWN` dışındaki durumlar aktif sayılır |
| Sistem toplamı (menü çubuğu halkası) | `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` (mW) | ~20 sn | Pilde ve adaptörde geçerli. Yoksa yalnız deşarjda `V × I` kullanılır. Arayüz değerin yaşını 20 sn'den eskiyse gösterir. |
| CPU, DRAM ve ANE bileşen enerjisi | IOReport "Energy Model" patlamaları | Seyrek (sn'ler ile dk'lar arası; bazı koşularda hiç gelmedi) | **Canlı watt olarak hiç gösterilmez.** Yalnız bir patlama iki uç arasındaki pencereyi kapsadığında uzun pencere ortalaması olarak kullanılır (ADR 0002). |

- `SamplingEngine` her tick'te süreç taramasını, `GPU Energy`'yi ve küme doluluğunu okur. `SystemLoad` ve pil alanları, kaynak zaten ~20 sn'de bir güncellendiği için 10 sn'de bir okunur. IOReport aboneliği hem `interactive` hem `ambient` durumda açık kalır, böylece bir patlama kaçırılmaz.
- **Sayaçlar kümülatif olduğu için** (IOReport enerji sayaçları, `ri_energy_nj`) aralığın uzaması ölçülen enerjiyi değiştirmez. Değişen iki şey var: zaman çözünürlüğü ve iki örnek arasında doğup ölen süreçlerin kaybı (ADR 0002 § Dürüst sınırlar). `suspended` durumdan çıkıldığında ilk delta normal şekilde hesaplanır. Aradaki boşluk bir `sampling_gap` satırı olarak ledger'a yazılır.
- **Popover açıkken bile süreç taraması 1 sn'de yapılır**, çünkü canlı CPU watt'ının tek kaynağı bu tarama. Yük ~670 pid için `proc_listallpids` artı `proc_pid_rusage` çağrısı. `EPERM` dönen pid'ler bir sonraki atıf önbelleği yenilemesine kadar yeniden denenmez. Tarama maliyeti T-021'de ölçülür. Tick başına 5 ms CPU'yu aşarsa kabul kapısı kırmızı sayılır ve optimizasyon (ör. yalnız değişen pid kümesini yeniden çözmek) T-021'in işi olur. Canlı değer 2 sn'ye düşürülmez.
- CPU zamanı alanları (`ri_user_time`, `ri_system_time`) mach tick cinsindendir ve `mach_timebase_info` ile ns'ye çevrilir. M3'te oran 125/3; sabit kodlanmaz.
- **Atıf önbelleği:** pid'den `AppKey`'e çözüm (ADR 0002) `ProcessIdentity` anahtarıyla önbelleğe alınır. Böylece `proc_pidpath` ve `Info.plist` okuması her süreç için yalnız bir kez yapılır. Ölen süreçlerin girdileri her tick'te silinir.

### 5. Widget ve CLI veriyi nasıl okur

- **Paylaşılan konum:** App Group kapsayıcısı `~/Library/Group Containers/<TEAMID>.dev.ohm/`. İçinde `ledger.sqlite` (WAL) ve `rules.json` bulunur. Ana uygulama ve CLI sandbox'sız ama App Group entitlement'ı ile imzalanır. Widget bu kapsayıcıya entitlement'ı üzerinden erişir.
- **Tek yazar** `OhmApp` içindeki `EnergyLedger`'dır. Widget ve CLI `sqlite3_open_v2(path, SQLITE_OPEN_READONLY)` ile bağlanır, ardından `PRAGMA query_only=1` ve `busy_timeout=2000` uygular. WAL modunda okuyucular yazarı bloklamaz. Okuyucu `-shm` dosyasına erişebilmeli; grup kapsayıcısı widget için okunur-yazılır olduğu için bu sağlanıyor.
- **Widget** yalnız saatlik ve dakikalık toplam tablolarını okur (ADR 0002). Timeline politikası `.after(15 dk)`. Uygulama gün değişiminde ve kullanıcı bir eylem yaptığında `WidgetCenter.shared.reloadTimelines(ofKind:)` çağırır; bu çağrı saatte en fazla 4 kez yapılır (WidgetKit bütçesi).
- **CLI okuma** (`ohm receipt --today`, `ohm top --history`) doğrudan SQLite üzerinden yapılır, uygulamanın açık olması gerekmez.
- **CLI değişiklikleri** (`ohm ecore Slack`, `ohm freeze`, `ohm thaw`) ve canlı `ohm top` her zaman çalışan uygulama üzerinden geçer. Böylece journal'ın ve Governor durumunun tek sahibi korunur. Kanal bir Unix domain soketidir: `confstr(_CS_DARWIN_USER_TEMP_DIR)` + `dev.ohm.control.sock`, izin `0600`. Kısa, kullanıcıya özel yol, 104 baytlık `sun_path` sınırının altında kalır. Uygulama `getpeereid` ile istemcinin UID'sini doğrular. Mesajlar satır başına bir JSON (`OhmControl`). Uygulama çalışmıyorsa CLI açık bir hata verir: "Ohm çalışmıyor; `open -a Ohm`".
- **Tek istisna `ohm thaw --all`:** Uygulama çalışmıyorsa CLI journal kilidini kendisi alır ve ADR 0004'teki kurtarmayı çalıştırır. Kullanıcının acil çıkış yolu hiçbir sürece bağımlı değildir.
- **App Intents** uygulama sürecinde çalışır ve `Governor`'ı doğrudan çağırır; soket kullanmaz.

### 6. Boştaki bütçe (<40 MB, <%0,5 CPU)

| Kalem | Bütçe | Nasıl tutulur |
|---|---|---|
| AppKit, SwiftUI ve `MenuBarExtra` taban çizgisi | ~25 MB | T-061'de ölçülür. Kapalı popover'ın görünüm ağacı hafif bir yer tutucuya indirilir. |
| Örnekleme durumu | ≤2 MB | Süreç tablosu (~600 × ~200 B) ve atıf önbelleği. Grafik halka tamponu (120 örnek) yalnız popover açıkken tutulur. |
| SQLite | ≤1 MB | `PRAGMA cache_size=-512`, tek yazma bağlantısı, dakikada bir `flush`. |
| Kurallar, Governor, tahmin | ≤1 MB | Kural sayısı ve donuk küme küçük. |
| FoundationModels | 0 (boştayken) | Oturum yalnız kural yazılırken yaşar. Model sistem sürecinde çalışır. |
| **Toplam hedef** | **<35 MB** (5 MB pay) | |
| `ohm-thawd` (ayrı süreç) | ≤4 MB, 0 CPU | `flock` ve vnode olayında bloklu bekler. Raporda ayrı satır olarak yazılır. |

CPU: `ambient` durumda tick başına hedef ≤3 ms (10 sn'de bir; ≈%0,03). Ledger `flush` işlemi dakikada bir tek transaction'dır ve WAL `synchronous=NORMAL` altında commit başına fsync yapmaz. Menü çubuğu halkası 10 sn'de bir, yalnız değer değiştiyse yeniden çizilir. Bu bütçe T-061'de Instruments ile doğrulanır. Kabul satırı: 10 dakikalık boşta ölçümde ortalama CPU <%0,5 ve fiziksel ayak izi <40 MB.

## Alternatifler

1. **Tek bir `OhmCore` target'ı (klasörlerle ayrım).** Reddedildi. Widget özel API sembollerini ve sinyal kodunu da ikili dosyasına alır. Bağımlılık yönü (ör. `Rules → Governor`) derleyici tarafından zorlanmaz.
2. **Actor yerine `DispatchQueue` ve kilitli sınıflar.** Reddedildi. Swift 6 strict concurrency altında her sınıf `@unchecked Sendable` gerektirir ve veri yarışı denetimi kaybolur. Bloklayan G/Ç ihtiyacı, actor'lere özel `DispatchSerialQueue` yürütücüsü verilerek karşılandı.
3. **Widget ve CLI'ın uygulamadan XPC ile veri alması.** Reddedildi. Uygulama kapalıyken widget boş kalır ve XPC Mach servisi için launchd kaydı gerekir. SQLite WAL, çok okuyucu ve tek yazar durumunu zaten güvenle çözüyor.
4. **CLI değişikliklerinin doğrudan `setpriority` ve `kill` çağırması.** Reddedildi. Governor bu etkileri bilmez. Aktivasyonda geri alma, journal ve "etkiler Ohm'un ömrüyle sınırlı" değişmezi (ADR 0004) bozulur.
5. **Sabit 1 sn örnekleme.** Reddedildi. Boştaki CPU bütçesini gereksiz yere harcar. Sayaçlar kümülatif olduğu için 10 sn doğruluk kaybettirmez.
6. **`DistributedNotificationCenter` ile CLI kontrolü.** Reddedildi. Yanıt kanalı yok, göndereni doğrulamak mümkün değil ve teslim garantisi yok.

## Sonuçlar ve riskler

- **(+)** Özel API tek bir target'ta kalır. IOReport tamamen kaybolursa `NullComponentSampler` devreye girer. Bu durumda yalnız GPU watt'ı ve küme doluluğu gider; pil fişi ve sistem toplamı IOReport'a bağlı değildir. Widget ile özel API arasında bağlantı yoktur.
- **(−)** Canlı CPU watt'ı yalnız okunabilen süreçleri kapsar ve gerçek CPU gücünden düşüktür. Aradaki fark (root süreçler) canlı olarak ölçülemez; yalnız IOReport patlamaları geldiğinde uzun pencerede tahmin edilir (ADR 0002).
- **(+)** Her mantık parçası sahte (fake) protokol uygulamalarıyla birim test edilebilir. T-022 ve T-031 donanım olmadan test yazabilir.
- **(−)** Dokuz target ve dört ikili dosya iskeleti (T-020) büyütür. XcodeGen şablonu bunu bir kez çözer.
- **Risk:** Sandbox'sız bir CLI'ın App Group kapsayıcısına erişmesi macOS 15'ten beri TCC uyarısına ("başka uygulamaların verilerine erişmek istiyor") yol açabilir. Etkisi CLI'da tek seferlik bir izin istemi olur. T-033 bunu doğrular. Uyarı çıkarsa CLI okumaları kontrol soketine taşınır; bu durumda uygulamanın açık olması gerekir. Ledger'ın ikinci bir kopyası tutulmaz.
- **Risk:** `PowerTelemetryData.SystemLoad` yalnız M3 ve macOS 27'de ölçüldü. M1 ve M2'de macOS 26 ile bulunup bulunmadığı bilinmiyor. Yoksa `SystemLoadSampler` deşarjda `V × I` yedeğine düşer ve şarjdayken "Diğer" satırı hesaplanamaz (ADR 0002). T-021 alanın varlığını çalışma zamanında kontrol eder; eski çip testi için bir M1 veya M2 cihaz gerekir.
- **Risk:** `MenuBarExtra(.window)` görünüm ağacı kapalıyken tamamen serbest bırakılmayabilir. T-061'de 40 MB aşılırsa popover, `NSStatusItem` ve `NSPopover` ile elle yönetilen bir yapıya geçirilir.

## Spike'a bağlı (Faz 0 sonuçlarıyla çözüldü)

- **T-010 PARTIAL (kesin):** IOReport canlı bileşen watt'ı için kullanılmaz. Kesin örnekleme tasarımı § 4'teki tablodur: süreç enerjisi, `GPU Energy`, küme doluluğu ve `SystemLoad`. CPU, DRAM ve ANE bileşen enerjisi yalnız patlamalardan uzun pencere ortalaması olarak kullanılır. Popover'da bileşen başına CPU, DRAM veya ANE watt'ı gösterilmez.
- **T-011 PASS:** `ProcessEnergySampler`, `ri_energy_nj` ve `ri_penergy_nj` sayaçlarını doğrudan kullanır. CPU zamanından tahmin yedeği kaldırıldı. `EPERM` oranı (~%40 pid) ADR 0002'de "Sistem" satırı olarak ele alınır.
- **T-013 PASS:** Aktivasyon ile SIGCONT arası 17–18 ms. `Governor` için `.userInitiated` QoS'u yeterli, değişiklik yok.
- **Açık kalan (spike dışı):** `dlopen` ile IOReport'un paylaşımlı önbellekten yüklenmesi (T-021). `SystemLoad` alanının M1 ve M2'de bulunması (bulunmazsa deşarjda `V × I` yedeği; § Sonuçlar ve riskler).
