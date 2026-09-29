# ADR 0001: Modül sınırları ve eşzamanlılık modeli

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü bekleniyor.
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0002 (ledger), ADR 0003 (kural DSL'i), ADR 0004 (dondurma güvenliği), `Docs/PLAN.md` § Mimari

## Bağlam

Ohm; menü çubuğu uygulaması, widget, `ohm` CLI ve dondurma güvenliği için bir izleyici süreçten oluşuyor. Bunların hepsi aynı çekirdek mantığı paylaşıyor. Kısıtlar şunlar:

- **Hafiflik (kabul ölçütü):** Boştayken bellek <40 MB ve CPU ortalaması <%0,5. Popover açıkken örnekleme 1 sn, kapalıyken 10 sn. Ohm'un kendi işi `.utility` veya `.background` QoS ile yapılır.
- **Swift 6 strict concurrency** (araç zinciri Swift 6.4). Veri yarışı derleme hatasıdır.
- **Özel API riski:** IOReport'un başlığı yok ve macOS 27'de değişmiş olabilir (T-010). Bu yüzden özel API'ye bağlı kod tek bir modülde ve bir protokolün arkasında durmalı; yedek yol protokolün başka bir uygulaması olmalı.
- **Sandbox sınırı:** WidgetKit uzantısı sandbox'lı çalışmak zorunda. Ana uygulama başka süreçlere sinyal gönderdiği için sandbox'sız, Developer ID ile imzalı. Widget özel API'lere ve sinyal koduna bağlanmamalı.
- **Tek yazar:** SQLite ledger'ına ve dondurma journal'ına yalnız bir süreç yazmalı. Aksi halde kilit çekişmesi ve bozulma riski doğar.
- **Dağıtım hedefi:** Plan "M1+, macOS 15+" diyor. FoundationModels ve Liquid Glass ise macOS 26 istiyor. Bu ADR'nin varsayımı şu: dağıtım hedefi macOS 15, macOS 26 özellikleri `#available(macOS 26, *)` ile açılır.

## Karar

### 1. Paket ve hedef yapısı

`app/OhmCore/Package.swift` tek bir SwiftPM paketi. Plandaki beş klasör ayrı **target** olur. Böylece bağımlılık yönü derleyici tarafından zorlanır.

| Target | Tür | İçerik | Bağımlılıklar |
|---|---|---|---|
| `OhmModel` | Swift | Yalnız değer tipleri: kimlikler, örnekler, fiş satırları, `Rule` modeli, komutlar. Hepsi `Sendable`, çoğu `Codable`. | – |
| `COhmSys` | C | IOReport prototipleri (`dlopen`/`dlsym`), `responsibility_get_pid_responsible_for_pid` (`dlsym`, libquarantine), async-signal-safe çözme tablosu (ADR 0004). | – |
| `OhmSampling` | Swift | `IOReportSampler`, `ProcessEnergySampler`, `BatterySampler`, `ThermalSampler`, `AttributionResolver`, `SamplingEngine` | `OhmModel`, `COhmSys` |
| `OhmLedger` | Swift | `EnergyLedger` (yazar), `LedgerReader` (salt okunur), migration'lar | `OhmModel` (sistem `sqlite3`) |
| `OhmJournal` | Swift | `FreezeJournal`, `JournalRecovery`, `ProcessIdentity` doğrulama | `OhmModel`, `COhmSys` |
| `OhmGovernor` | Swift | `Governor`, `ECoreLane`, `Freezer`, `SafetyPolicy`, `RunawayDetector` | `OhmModel`, `OhmJournal`, `COhmSys` |
| `OhmRules` | Swift | `RuleEngine`, `RuleCompiler`, `NLRuleParser` (`#if canImport(FoundationModels)`) | `OhmModel` |
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

### 2. Modüller arası protokoller

Protokoller `OhmModel` içinde tanımlanır; somut tipler kendi target'larında yaşar. Testler sahte (fake) uygulamaları bu protokoller üzerinden verir.

```swift
// MARK: OhmModel — değer tipleri (özet)
public struct ProcessStartTime: Hashable, Sendable, Codable { public var sec: Int64; public var usec: Int32 }
public struct ProcessIdentity: Hashable, Sendable, Codable {        // pid yeniden kullanımına karşı
    public var pid: Int32
    public var start: ProcessStartTime                               // proc_pidinfo(PROC_PIDTBSDINFO)
}
public enum AttributionKind: Int, Sendable, Codable { case bundleID = 0, executableName = 1, processName = 2 }
public struct AppKey: Hashable, Sendable, Codable {                  // ADR 0002'deki kalıcı atıf anahtarı
    public var kind: AttributionKind
    public var value: String
}
public enum PowerSourceKind: String, Sendable, Codable { case battery, ac, unknown }
public enum ThermalLevel: Int, Sendable, Codable, Comparable { case nominal, fair, serious, critical }

public struct SystemPower: Sendable {                                // bir aralığın ortalaması, watt
    public var cpuP: Double?, cpuE: Double?, gpu: Double?, ane: Double?, dram: Double?  // IOReport; yoksa nil
    public var batteryTerminal: Double?                               // V × I, yalnız pildeyken anlamlı
    public var clusterActive: ClusterResidency?
}
public struct BatteryState: Sendable, Codable {
    public var source: PowerSourceKind
    public var percent: Int
    public var voltage_mV: Int, amperage_mA: Int
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
public protocol SystemPowerSampling: Sendable {                      // IOReportSampler | BatteryOnlyPowerSampler
    func sample() async throws -> SystemPower
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
- **Sayaçlar kümülatif olduğu için** (IOReport enerji sayaçları, `ri_energy_nj`) aralığın uzaması ölçülen enerjiyi değiştirmez. Değişen iki şey var: zaman çözünürlüğü ve iki örnek arasında doğup ölen süreçlerin kaybı (ADR 0002 § Dürüst sınırlar). `suspended` durumdan çıkıldığında ilk delta normal şekilde hesaplanır. Aradaki boşluk bir `sampling_gap` satırı olarak ledger'a yazılır.
- **Popover açıkken bile süreç taraması 1 sn'de yapılır.** Ölçülecek yük ~500 süreç için `proc_listallpids` artı `proc_pid_rusage` çağrısı. T-021 bunu ölçer. Tarama tick başına 5 ms CPU'yu aşarsa, `interactive` durumda süreç taraması 2 sn'ye çekilir, sistem gücü 1 sn'de kalır.
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

- **(+)** Özel API tek bir target'ta kalır; yedek yol protokolün ikinci uygulamasıdır (`BatteryOnlyPowerSampler`). Widget ile özel API arasında bağlantı yoktur.
- **(+)** Her mantık parçası sahte (fake) protokol uygulamalarıyla birim test edilebilir. T-022 ve T-031 donanım olmadan test yazabilir.
- **(−)** Dokuz target ve dört ikili dosya iskeleti (T-020) büyütür. XcodeGen şablonu bunu bir kez çözer.
- **Risk:** Sandbox'sız bir CLI'ın App Group kapsayıcısına erişmesi macOS 15 ve sonrasında TCC uyarısına ("başka uygulamaların verilerine erişmek istiyor") yol açabilir. Etkisi CLI'da tek seferlik bir izin istemi olur. T-033 bunu doğrular. Uyarı çıkarsa CLI okumaları kontrol soketine taşınır; bu durumda uygulamanın açık olması gerekir. Ledger'ın ikinci bir kopyası tutulmaz.
- **Risk:** `DispatchSerialQueue` yürütücüsü macOS 14+ gerektirir. Dağıtım hedefi 15 olduğu için sorun değil.
- **Risk:** `MenuBarExtra(.window)` görünüm ağacı kapalıyken tamamen serbest bırakılmayabilir. T-061'de 40 MB aşılırsa popover, `NSStatusItem` ve `NSPopover` ile elle yönetilen bir yapıya geçirilir.

## Spike'a bağlı

- **T-010 (IOReport sudo'suz):** Geçerse `SystemPowerSampling` = `IOReportSampler` (P/E küme, GPU, ANE, DRAM watt'ı, küme doluluğu). Geçmezse `BatteryOnlyPowerSampler`: sistem gücü yalnız pildeyken `V × I` olarak okunur. Popover'daki küme çubukları gizlenir, "Diğer" satırı yalnız pildeyken hesaplanır (ADR 0002).
- **T-011 (`ri_energy_nj`):** Geçerse `ProcessEnergySampler` enerji sayacını doğrudan kullanır. Geçmezse (sıfır veya okunamaz) süreç enerjisi, IOReport küme enerjisinin CPU zamanı payına göre dağıtılmasıyla tahmin edilir (`ri_user_time + ri_system_time`). Arayüzde "tahmini" etiketi gösterilir. T-010 da kalırsa pil fişi yalnız CPU zamanı olarak gösterilir. Bu, ürün vaadinin daraltılması demektir ve kullanıcı kararı gerektirir.
- **T-011 (tick maliyeti):** Tam taramanın ölçülen maliyeti, `interactive` durumda süreç taramasının 1 sn mi 2 sn mi olacağını belirler (§ 4).
- **T-013 (aktivasyon gecikmesi):** `Governor` yürütücüsünün `.userInitiated` QoS'u, ölçülen gecikme 300 ms'yi aşarsa yeniden değerlendirilir.
