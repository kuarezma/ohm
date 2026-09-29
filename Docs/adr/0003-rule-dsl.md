# ADR 0003: Kural DSL'i, değerlendirme semantiği ve doğal dil şeması

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü bekleniyor.
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0001 (`RuleEvaluating`, `DesiredState`), ADR 0004 (güvenlik vetoları, aktivasyonda çözme), T-031 (RuleEngine), T-040 (NLRuleParser)

## Bağlam

Kural motoru koşul ve eylem çiftlerini çalıştırır. Koşullar: güç kaynağı, pil yüzdesi, termal durum, ön plandaki uygulama, saat aralığı ve Focus. Eylemler: E-core, dondurma ve bildirim. Kurallar üç yoldan gelir: arayüz, doğal dil (FoundationModels `@Generable`, macOS 26+) ve ileride Shortcuts.

Bu ADR'nin cevaplaması gereken sorular:
- Kural modeli nasıl kodlanır? Model, `rules.json` olarak diske yazılır ve CLI tarafından okunur (ADR 0001).
- Semantik nedir? Tetikleme kenarla mı düzeyle mi olur, eşik çevresinde titreme nasıl önlenir, iki kural çatışırsa ne olur, koşul bitince etki geri alınır mı?
- Cihaz üstündeki küçük model hangi yapıyı üretmeli ki T-040 kapısı (20 cümlenin en az 18'i doğru) tutsun?

Olgular:
- **Focus:** Hangi Focus'un açık olduğunu adıyla veren bir genel API yok. `INFocusStatusCenter` yalnız "Focus açık mı" bilgisini (bool) verir ve kullanıcı izni ister. App Intents'teki `SetFocusFilterIntent` ise kullanıcının Focus ayarına ekleyebileceği bir filtre sunar. Filtre etkinleştiğinde uygulamaya kullanıcının seçtiği parametreler gelir.
- **`@Generable`:** Struct'ları ve ilişkili değer taşımayan enum'ları, optional alanları ve dizileri destekler. `@Guide` ile açıklama ve kısıt (`.range`, `.minimumCount`, `.maximumCount`, regex) verilebilir. Özyinelemeli tipler küçük modelde güvenilir değildir.

## Karar

### 1. Kalıcı kural modeli (`OhmModel`, `Codable`)

```swift
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var source: RuleSource                 // .manual | .naturalLanguage(text: String)
    public var when: Condition
    public var targets: TargetSelector
    public var actions: [Action]                  // 1…3, türler tekrar etmez
    public var options: RuleOptions = .init()
}

public indirect enum Condition: Codable, Sendable, Hashable {
    case always
    case all([Condition])
    case any([Condition])
    case not(Condition)
    case powerSource(PowerSourceKind)                              // .battery | .ac
    case batteryPercent(BatteryComparison, value: Int, hysteresis: Int?)  // .below | .atOrAbove, 1…99
    case thermal(atLeast: ThermalLevel)                            // .fair | .serious | .critical
    case frontmostApp(AppRef)
    case timeWindow(start: LocalTime, end: LocalTime, weekdays: Set<Weekday>?)
    case focus(isOn: Bool)                                         // INFocusStatusCenter
    case focusProfile(String)                                      // SetFocusFilterIntent parametresi
    case unsupported(raw: JSONValue)                               // ileri uyumluluk; kural devre dışı yüklenir
}

public enum TargetSelector: Codable, Sendable, Hashable {
    case apps([AppRef])                           // 1…10
    case runaway                                  // RunawayDetector'ın o an işaretlediği süreçler
    case allApps(except: [AppRef])                // yalnız eCore ve notify ile; freeze ile doğrulama reddeder
}

public struct AppRef: Codable, Sendable, Hashable {
    public var bundleID: String?                  // birincil
    public var executableName: String?            // paketsiz süreçler (ör. "node")
    public var displayName: String                // arayüz ve NL eşlemesi için
}

public enum Action: Codable, Sendable, Hashable {
    case eCore(whileFrontmost: FrontmostPolicy = .release)        // .release | .keep
    case freeze(minHiddenSeconds: Int? = nil)                     // ≥ Governor'ın genel alt sınırı (ADR 0004)
    case notify(message: String? = nil)
}

public struct RuleOptions: Codable, Sendable, Hashable {
    public var activateAfter: Duration?           // nil → yaprak türlerinin varsayılanlarının en büyüğü
    public var deactivateAfter: Duration?
    public var notifyCooldown: Duration = .seconds(1800)
}
```

**JSON kodlaması:** Swift'in enum'lar için otomatik ürettiği `{"all":{"_0":[…]}}` biçimi kullanılmaz; bu biçim okunaksız ve kararsız. Onun yerine elle yazılmış `Codable` uygulanır ve `"type"` ayırıcısı kullanılır:

```json
{ "type": "all", "of": [ { "type": "powerSource", "is": "battery" },
                         { "type": "batteryPercent", "op": "below", "value": 30 } ] }
```

Kalıcı JSON'un tamamı (`rules.json`, App Group kapsayıcısında, tek yazar `OhmApp`, geçici dosyaya yazıp `rename` ile atomik değiştirme):

```text
{ "schemaVersion": 1, "rules": [ <Rule>, … ] }
```

`Duration` alanları (`notifyCooldown`, `activateAfter`, `deactivateAfter`) JSON'da tam saniye olarak kodlanır.

| `Condition.type` | Alanlar |
|---|---|
| `always` | – |
| `all`, `any` | `of`: `[Condition]`, 1…8 eleman |
| `not` | `condition`: `Condition` |
| `powerSource` | `is`: `"battery"` \| `"ac"` |
| `batteryPercent` | `op`: `"below"` \| `"atOrAbove"`, `value`: 1…99, `hysteresis`?: 1…10 (varsayılan 3) |
| `thermal` | `atLeast`: `"fair"` \| `"serious"` \| `"critical"` |
| `frontmostApp` | `app`: `AppRef` |
| `timeWindow` | `start`, `end`: `"HH:mm"` (yerel saat); `weekdays`?: `["mon", …]`. `end ≤ start` ise pencere gece yarısını geçer ve `weekdays` başlangıç gününe göre yorumlanır. |
| `focus` | `isOn`: bool |
| `focusProfile` | `profile`: string |

| `Action.type` | Alanlar |
|---|---|
| `eCore` | `whileFrontmost`?: `"release"` (varsayılan) \| `"keep"` |
| `freeze` | `minHiddenSeconds`?: int |
| `notify` | `message`?: string |

**Doğrulama (`RuleValidator`, kaydetmeden önce ve yüklerken):**
- Ağaç derinliği ≤ 3, yaprak koşul sayısı ≤ 8, hedef ≤ 10 uygulama, en fazla 50 kural.
- `freeze` eylemi yalnız `apps` hedefiyle kullanılabilir. `allApps` ve `runaway` ile dondurma yapılmaz. Kaçak süreçler yalnız kullanıcı onayıyla dondurulur (ADR 0004).
- `freeze` hedefindeki her uygulama, ADR 0004'teki kalıcı "asla dondurma" listesine karşı kaydederken kontrol edilir. Listede olan uygulama kaydı reddedilir ve gerekçesi gösterilir.
- `unsupported` bir koşul içeren kural (daha yeni bir Ohm sürümünde yazılmış olabilir) devre dışı yüklenir. Ham JSON'u korunur ve dosya yeniden yazılırken silinmez.

### 2. Değerlendirme semantiği

**Tetikleyiciler (olay güdümlü):** Değerlendirme örnekleme tick'lerine değil bağlam olaylarına bağlıdır. Olaylar:
- güç kaynağı ve pil yüzdesi (`IOPSNotificationCreateRunLoopSource`),
- `ProcessInfo.thermalStateDidChangeNotification`,
- `NSWorkspace.didActivateApplicationNotification`,
- uygulama açılışı ve kapanışı (hedef uygulama açıldığında etkinin uygulanabilmesi için),
- Focus değişimi,
- `RuleEngine`'in kendi verdiği bir sonraki son tarih (bekleyen gecikme ya da saat penceresi sınırı).

Olaylar 250 ms içinde birleştirilir (coalescing). Motor her değerlendirmede `nextDeadline: Date?` döndürür; zamanlayıcı yalnız o ana kurulur. Boşta periyodik bir değerlendirme olmaz.

**Değerlendirme iki katmandadır:**

1. **Yaprak histerezisi (durumlu yapraklar):**
   - `batteryPercent below X`: yüzde `< X` olunca açılır, `≥ X + h` olunca kapanır. `atOrAbove X` için tersi geçerli: `≥ X` olunca açılır, `< X − h` olunca kapanır. Varsayılan `h = 3`.
   - `thermal atLeast L`: seviye `≥ L` olunca açılır, `< L` olunca kapanır. Sıcaklık dalgalanmasına karşı koruma ikinci katmanın gecikmesindedir.
   - Diğer yapraklar durumsuzdur.

2. **Kural düzeyinde gecikme (debounce):** Ham sonuç, `activateAfter` süresi boyunca kesintisiz `true` kalırsa kural `active` olur. `deactivateAfter` süresi boyunca kesintisiz `false` kalırsa `inactive` olur. Durumlar: `inactive → pendingActive → active → pendingInactive → inactive`. Varsayılanlar, kuraldaki yaprak türlerinin en büyük değeridir:

| Yaprak | `activateAfter` | `deactivateAfter` | Neden |
|---|---|---|---|
| `powerSource` | 5 sn | 5 sn | Kablonun gevşek teması |
| `batteryPercent` | 0 | 0 | Histerezis yaprağın içinde |
| `thermal` | 10 sn | 60 sn | Termal durum kısa süre sıçrayabilir |
| `frontmostApp` | 2 sn | 2 sn | Cmd-Tab ile hızlı geçişler |
| `timeWindow` | 0 | 0 | Sınır kesin olmalı |
| `focus`, `focusProfile` | 0 | 5 sn | |

**Düzey ve kenar:**
- `eCore` ve `freeze` **düzey tetiklemelidir** (level-triggered). Kural `active` olduğu sürece katkısı "istenen durum"da (`DesiredState`) yer alır. `inactive` olunca, devre dışı bırakılınca veya silinince katkı kalkar. Geri alma bu katkı farkından kendiliğinden doğar; ayrı bir "geri al" eylemi yoktur.
- `notify` **kenar tetiklemelidir** (edge-triggered). Yalnız `inactive → active` geçişinde, `notifyCooldown` süresi dolmuşsa ateşlenir. Aynı değerlendirmede ateşlenen bildirimler tek bir bildirimde birleştirilir.

**Uzlaştırma (reconciliation):** `RuleEngine`, her aktif kuralın hedeflerini `AppKey`'e çözer ve `DesiredState` üretir. Bu durum her uygulama için istenen etkiler kümesini ve bunların kaynaklarını içerir. `Governor.reconcile` gerçek durumu istenen duruma getirir. Governor yalnız **kendi uyguladığı** etkiyi geri alır: Ohm'dan önce zaten arka plan önceliğinde olan bir süreç (`getpriority` 1 döndürüyorsa) Ohm tarafından hiçbir zaman ön plana döndürülmez. Hedef uygulama o anda çalışmıyorsa istek beklemede kalır ve uygulama açılınca uygulanır.

### 3. Çatışma çözümü

Bir uygulama için sıralama `none < eCore < freeze` şeklindedir.

1. **Birleşim:** Uygulamaya yönelik istekler bütün aktif kural katkıları ve elle yapılan katkılar üzerinden toplanır. Governor bu kümeden, güvenlik vetosuna (ADR 0004) takılmayan **en yüksek** etkiyi uygular. Dondurma veto edilirse (ör. uygulama ses çalıyor), aynı uygulama için E-core da istenmişse E-core uygulanır. İstenmemişse hiçbir şey uygulanmaz. Veto, gerekçesiyle birlikte arayüzde görünür. Dondurmanın yerine sessizce E-core konmaz; kural yazarı ikisini birlikte istediyse ikisi de uygulanır.
2. **Aynı etki, birden çok kaynak:** Etki, onu isteyen son kaynak kalkana kadar sürer. Örneğin iki kural Chrome'u E-core'da tutuyorsa, biri bittiğinde Chrome E-core'da kalır.
3. **Elle iptal her zaman kazanır.** Kullanıcı kural tarafından yönetilen bir uygulamayı elle çözerse veya E-core'dan çıkarırsa, **kural yeniden kurulana kadar** bir bastırma kaydı oluşur. Bu kayıt, o an etkiyi isteyen kuralların o uygulamaya yönelik katkısını bastırır ve ilgili kural bir kez `inactive` olup yeniden `active` olana kadar sürer. Kullanıcının kararı bir sonraki değerlendirmede ezilmez.
4. **Elle uygulama:** Kullanıcı popover'da [E] düğmesine basarsa `manual` kaynaklı bir katkı eklenir. Bu katkı kullanıcı onu kaldırana veya uygulama kapanana kadar sürer. Elle yapılan dondurma, uygulama aktive edilince biter. Hiçbir katkı Ohm yeniden başladıktan sonra geri gelmez (ADR 0004'teki değişmez); açılışta kurallar yeniden değerlendirilir, elle katkılar sıfırlanır.
5. **Aktivasyonda çözme** kural semantiğinin değil güvenliğin parçasıdır. Aktive edilen donuk uygulama her koşulda çözülür. Governor bu uygulamayı, uygulama yeniden `refreezeGrace` süresi boyunca (varsayılan 10 dk) gizli kalana kadar tekrar dondurmaz (ADR 0004). Kural hâlâ aktif olsa bile bu geçerlidir.
6. **`eCore(whileFrontmost: .release)`:** Hedef uygulama öne geldiğinde E-core politikası geçici olarak kaldırılır. Uygulama öne gelmeyi bırakıp `frontmostApp` gecikmesi (2 sn) dolunca politika yeniden uygulanır.
7. **Deterministik sıra:** Bildirim metinleri ve rapor satırları kural `id`'sine göre sıralanır. Katkılar küme olarak birleştiği için kuralların değerlendirme sırası sonucu etkilemez.

### 4. Doğal dil şeması (`@Generable`)

Model özyinelemeli `Condition` ağacını **üretmez**. Düz bir `GeneratedRule` üretir. Deterministik `RuleCompiler` bu çıktıyı `Rule`'a çevirir, doğrular ve uygulama adlarını bundle ID'ye çözer. Bu tercihin gerekçesi: düz şema küçük model için daha kolay, doğrulama kodu modelden bağımsız ve test edilebilir.

```swift
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
@Generable(description: "Kullanıcının tek cümlesinden çıkarılan bir enerji kuralı")
struct GeneratedRule {
    @Guide(description: "Kısa, kullanıcının dilinde kural adı")
    var name: String
    @Guide(description: "Kuralın etkileyeceği uygulama adları, cümlede geçtiği gibi (ör. Chrome, Slack). Kaçak süreçler hedefse boş.",
           .maximumCount(5))
    var targetApps: [String]
    @Guide(description: "Hedef, arka planda uzun süre çok CPU harcayan 'kaçak' süreçler mi")
    var targetRunaway: Bool
    @Guide(description: "Yapılacak eylemler: eCore = verimlilik çekirdeğine al, freeze = dondur, notify = bildir",
           .minimumCount(1), .maximumCount(3))
    var actions: [GeneratedAction]
    @Guide(description: "Koşulların hepsi mi (all) yoksa en az biri mi (any) gerekli")
    var match: GeneratedMatch
    @Guide(.minimumCount(1), .maximumCount(4))
    var conditions: [GeneratedCondition]
}

@available(macOS 26, *) @Generable enum GeneratedAction { case eCore, freeze, notify }
@available(macOS 26, *) @Generable enum GeneratedMatch { case all, any }
@available(macOS 26, *) @Generable enum GeneratedThermal { case fair, serious, critical }
@available(macOS 26, *) @Generable enum GeneratedWeekday { case mon, tue, wed, thu, fri, sat, sun }
@available(macOS 26, *) @Generable enum GeneratedConditionKind {
    case onBattery, onAC, batteryBelow, batteryAtOrAbove, thermalAtLeast,
         frontmostIs, frontmostIsNot, timeBetween, focusOn, focusOff, focusProfile
}

@available(macOS 26, *)
@Generable(description: "Tek bir koşul; yalnız kind'a uyan alanlar doldurulur, diğerleri boş kalır")
struct GeneratedCondition {
    var kind: GeneratedConditionKind
    @Guide(description: "Pil yüzdesi eşiği (1-99); yalnız batteryBelow ve batteryAtOrAbove için")
    var percent: Int?
    @Guide(description: "Yalnız thermalAtLeast için. 'ısınınca' = serious")
    var thermal: GeneratedThermal?
    @Guide(description: "Uygulama adı; yalnız frontmostIs ve frontmostIsNot için")
    var appName: String?
    @Guide(description: "24 saatlik HH:mm; yalnız timeBetween için")
    var start: String?
    @Guide(description: "24 saatlik HH:mm; yalnız timeBetween için")
    var end: String?
    @Guide(description: "Yalnız timeBetween için; 'hafta içi' = mon…fri")
    var weekdays: [GeneratedWeekday]?
    @Guide(description: "Focus profil adı; yalnız focusProfile için")
    var focusProfile: String?
}
#endif
```

`@Guide` kısıtları (`.range`, regex) optional alanlarda derleyici tarafından desteklenmiyorsa, kısıt açıklama metnine taşınır. Asıl doğrulama her durumda `RuleCompiler`'dadır. T-040 bunu derleyerek doğrular.

Modelin ürettiği yapının JSON karşılığı (JSON Schema 2020-12). Değerlendirme seti bu biçimde saklanır; T-040 testleri model çıktısını bu şemaya karşı da doğrular:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://kuarezma.github.io/ohm/schema/generated-rule.v1.json",
  "type": "object",
  "additionalProperties": false,
  "required": ["name", "targetApps", "targetRunaway", "actions", "match", "conditions"],
  "properties": {
    "name":          { "type": "string", "minLength": 1, "maxLength": 60 },
    "targetApps":    { "type": "array", "items": { "type": "string", "minLength": 1 }, "maxItems": 5 },
    "targetRunaway": { "type": "boolean" },
    "actions":       { "type": "array", "items": { "enum": ["eCore", "freeze", "notify"] },
                       "minItems": 1, "maxItems": 3, "uniqueItems": true },
    "match":         { "enum": ["all", "any"] },
    "conditions":    { "type": "array", "minItems": 1, "maxItems": 4, "items": { "$ref": "#/$defs/condition" } }
  },
  "$defs": {
    "condition": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kind"],
      "properties": {
        "kind": { "enum": ["onBattery", "onAC", "batteryBelow", "batteryAtOrAbove", "thermalAtLeast",
                           "frontmostIs", "frontmostIsNot", "timeBetween", "focusOn", "focusOff", "focusProfile"] },
        "percent":      { "type": "integer", "minimum": 1, "maximum": 99 },
        "thermal":      { "enum": ["fair", "serious", "critical"] },
        "appName":      { "type": "string", "minLength": 1 },
        "start":        { "type": "string", "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$" },
        "end":          { "type": "string", "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$" },
        "weekdays":     { "type": "array", "items": { "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] },
                          "uniqueItems": true, "maxItems": 7 },
        "focusProfile": { "type": "string", "minLength": 1 }
      },
      "allOf": [
        { "if": { "properties": { "kind": { "enum": ["batteryBelow", "batteryAtOrAbove"] } } }, "then": { "required": ["percent"] } },
        { "if": { "properties": { "kind": { "const": "thermalAtLeast" } } },                     "then": { "required": ["thermal"] } },
        { "if": { "properties": { "kind": { "enum": ["frontmostIs", "frontmostIsNot"] } } },     "then": { "required": ["appName"] } },
        { "if": { "properties": { "kind": { "const": "timeBetween" } } },                        "then": { "required": ["start", "end"] } },
        { "if": { "properties": { "kind": { "const": "focusProfile" } } },                       "then": { "required": ["focusProfile"] } }
      ]
    }
  }
}
```

**`RuleCompiler` kuralları (deterministik, birim testli):**
1. `match` ve `conditions` birlikte `all`/`any` altında yapraklara çevrilir. `frontmostIsNot` → `not(frontmostApp)`, `focusOff` → `focus(isOn: false)`.
2. **Pil eşiği normalizasyonu:** `batteryBelow` var ve hiçbir koşul `onAC` değilse, kurala `powerSource: battery` eklenir. Gerekçe: pil eşiğine bağlı bir kuralın amacı pil tasarrufudur. Şarjdayken %25'teki bir Mac'te Chrome'u yavaşlatmak kullanıcının istediği şey değildir. Onay ekranı eklenen koşulu açıkça gösterir.
3. **Uygulama adı çözümü:** Ad önce çalışan uygulamalarda, sonra `/Applications`, `~/Applications` ve `/System/Applications` altındaki paket adlarında aranır. Eşleştirme büyük-küçük harf duyarsızdır ve tam eşleşme, sonra kelime öneki olarak yapılır ("Chrome" → "Google Chrome"). Tek aday çıkarsa `AppRef` o olur. Birden çok aday (Chrome ve Chrome Canary) veya hiç aday yoksa taslak "çözülmemiş" işaretlenir ve onay ekranında seçici gösterilir.
4. `targetApps` boş ve `targetRunaway` yanlışsa taslak geçersizdir; kullanıcıdan hedef istenir.
5. **NL kuralları hiçbir zaman kendiliğinden etkinleşmez.** Onay ekranında insan diliyle özet gösterilir, örneğin "Pildeyken ve pil %30'un altındayken → Google Chrome → E-core". Kullanıcı [Kaydet] demeden kural `enabled = false` kalır.
6. **Kullanılabilirlik:** `SystemLanguageModel.default.availability != .available` ise veya model kullanıcının dilini desteklemiyorsa (`supportsLocale`) doğal dil girişi gizlenir. Elle kural arayüzü her zaman çalışır.

**T-040 kapısında "doğru"nun tanımı:** Derlenen `Rule`, beklenen `Rule` ile eşit olmalı. `id`, `name` ve `source` karşılaştırmaya girmez; `AppRef` eşitliği `bundleID` üzerinden kurulur.

### 5. Örnek kurallar (kalıcı JSON)

**1. "Pil %30'un altındayken Chrome'u E-core'a al"**

Modelin ürettiği `GeneratedRule`:
```json
{ "name": "Düşük pilde Chrome E-core", "targetApps": ["Chrome"], "targetRunaway": false,
  "actions": ["eCore"], "match": "all",
  "conditions": [ { "kind": "batteryBelow", "percent": 30 } ] }
```
Derlenmiş `Rule` (pil eşiği normalizasyonu `powerSource` koşulunu ekledi):
```json
{ "schemaVersion": 1, "id": "3F2A7C1E-0B6D-4E8A-9C11-2D5E8F0A6B01",
  "name": "Düşük pilde Chrome E-core", "enabled": true,
  "source": { "type": "naturalLanguage", "text": "Pil %30'un altındayken Chrome'u E-core'a al" },
  "when": { "type": "all", "of": [
    { "type": "powerSource", "is": "battery" },
    { "type": "batteryPercent", "op": "below", "value": 30 } ] },
  "targets": { "type": "apps", "apps": [ { "bundleID": "com.google.Chrome", "displayName": "Google Chrome" } ] },
  "actions": [ { "type": "eCore", "whileFrontmost": "release" } ] }
```
Semantik: Pildeyken yüzde 30'un altına düşünce Chrome E-core'a alınır. Yüzde 33'e çıkınca (histerezis 3) veya şarja takılıp 5 sn geçince politika kaldırılır. Chrome öne gelince geçici olarak serbest bırakılır.

**2. "Pildeyken Slack'i arka planda 10 dakika kalınca dondur"**
```json
{ "schemaVersion": 1, "id": "8C0D5B2A-6E71-4F3C-A2D4-5B9E1C7F3A02", "name": "Pilde Slack'i dondur", "enabled": true,
  "source": { "type": "manual" },
  "when": { "type": "powerSource", "is": "battery" },
  "targets": { "type": "apps", "apps": [ { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack" } ] },
  "actions": [ { "type": "freeze", "minHiddenSeconds": 600 }, { "type": "eCore" } ] }
```
Semantik: Slack görünür değilse ve 10 dakikadır ön planda değilse dondurulur. Güvenlik vetosu (ör. Slack'te arama sürüyor, mikrofon açık) dondurmayı engellerse, kural E-core'u da istediği için Slack E-core'a alınır. Kullanıcı Slack'e geçince Slack çözülür ve 10 dk yeniden gizli kalana kadar dondurulmaz.

**3. "Mac ısınınca Docker'ı E-core'a al ve bana haber ver"**
```json
{ "schemaVersion": 1, "id": "1E9B4D7C-2A38-4B6F-8D05-7C3A9E2F1B03", "name": "Sıcakta Docker'ı yavaşlat", "enabled": true,
  "source": { "type": "naturalLanguage", "text": "Mac ısınınca Docker'ı E-core'a al ve bana haber ver" },
  "when": { "type": "thermal", "atLeast": "serious" },
  "targets": { "type": "apps", "apps": [ { "bundleID": "com.docker.docker", "displayName": "Docker" } ] },
  "actions": [ { "type": "eCore", "whileFrontmost": "keep" }, { "type": "notify" } ],
  "options": { "notifyCooldown": 3600 } }
```
Semantik: Termal durum 10 sn boyunca `serious` veya üstünde kalınca Docker E-core'a alınır ve bir bildirim gönderilir. Soğuma 60 sn sürünce politika kaldırılır. Bildirim en fazla saatte bir gelir. (Docker'ın asıl yükü sanal makine süreçlerindedir. Bunların paket içinde olup olmadığını ADR 0004'teki süreç ağacı kuralı belirler; paket dışındaysa kapsam dışı kalır ve arayüz bunu söyler.)

**4. "Xcode öndeyken Slack ve Discord'u dondur"**
```json
{ "schemaVersion": 1, "id": "5A6C2E8B-9D14-4C7A-B3F0-8E1D4A6C2B04", "name": "Odaklı kodlama", "enabled": true,
  "source": { "type": "manual" },
  "when": { "type": "frontmostApp", "app": { "bundleID": "com.apple.dt.Xcode", "displayName": "Xcode" } },
  "targets": { "type": "apps", "apps": [
    { "bundleID": "com.tinyspeck.slackmacgap", "displayName": "Slack" },
    { "bundleID": "com.hnc.Discord", "displayName": "Discord" } ] },
  "actions": [ { "type": "freeze" } ] }
```
Semantik: Xcode 2 sn boyunca önde kalınca, gizli olan ve genel alt sınır kadar (ADR 0004, varsayılan 5 dk) ön plana gelmemiş olan Slack ve Discord dondurulur. Kullanıcı Slack'e geçerse Slack çözülür, kural da `frontmostApp` artık Xcode olmadığı için 2 sn sonra `inactive` olur ve Discord da çözülür.

**5. "Hafta içi 22:00 ile 07:00 arası Focus açıkken Dropbox'ı E-core'a al"**
```json
{ "schemaVersion": 1, "id": "C4B1F3A9-7E25-4D8B-9A6C-3F2E5D8B1C05", "name": "Gece Dropbox'ı yavaşlat", "enabled": true,
  "source": { "type": "naturalLanguage", "text": "Hafta içi 22:00 ile 07:00 arası Focus açıkken Dropbox'ı E-core'a al" },
  "when": { "type": "all", "of": [
    { "type": "timeWindow", "start": "22:00", "end": "07:00", "weekdays": ["mon", "tue", "wed", "thu", "fri"] },
    { "type": "focus", "isOn": true } ] },
  "targets": { "type": "apps", "apps": [ { "bundleID": "com.getdropbox.dropbox", "displayName": "Dropbox" } ] },
  "actions": [ { "type": "eCore", "whileFrontmost": "keep" } ] }
```
Semantik: Pencere gece yarısını geçer. Cuma 22:00'de başlayan pencere cumartesi 07:00'ye kadar sürer; cumartesi ve pazar 22:00'de pencere açılmaz. Focus kapanınca 5 sn sonra politika kaldırılır. Dropbox bir menü çubuğu (accessory) uygulaması olduğu için E-core uygulanabilir, ama ADR 0004 gereği asla dondurulamaz.

## Alternatifler

1. **Kenar tetiklemeli eylemler (koşul doğru olunca "uygula", yanlış olunca "geri al" olayları).** Reddedildi. Ohm yeniden başlarsa, bir olay kaçarsa veya iki kural aynı hedefte çakışırsa durum kayar. İstenen durumu hesaplayıp uzlaştırma yapmak her değerlendirmede kendini düzeltir. Yalnız `notify` doğası gereği kenar tetiklemelidir.
2. **Kural önceliği (priority) alanı.** Reddedildi. Etkiler sıralı ve birleşim en yüksek etkiyi seçiyor. Öncelik, kullanıcının anlaması gereken ikinci bir kavram eklerdi ama çözdüğü gerçek bir çatışma yok.
3. **Modelin doğrudan özyinelemeli `Condition` üretmesi.** Reddedildi. Küçük model derin iç içe yapılarda daha çok hata yapar ve `@Generable` özyinelemeli tiplerde güvenilir değildir. Düz şema ve deterministik derleyici daha çok test edilebilir.
4. **Swift'in enum'lar için otomatik ürettiği `Codable`.** Reddedildi. JSON okunaksız (`_0` anahtarları) ve alan eklemek şemayı kırar. CLI ve kullanıcılar `rules.json`'u okuyabilmeli.
5. **Focus adını doğrudan okumak.** Mümkün değil; genel API yok. Kullanıcının Focus ayarına eklediği `SetFocusFilterIntent` filtresi, ad yerine kullanıcı tanımlı bir profil parametresi taşır.
6. **Değerlendirmeyi her örnekleme tick'inde yapmak.** Reddedildi. Popover açıkken saniyede bir gereksiz iş yapılır. Koşulların hiçbiri süreç örneklerine bağlı değil; hepsinin kendi olay kaynağı var.

## Sonuçlar ve riskler

- **(+)** Geri alma ayrı bir kod yolu değil, istenen durumun bir sonucu. Çatışma, çökme sonrası yeniden başlama ve elle iptal aynı mekanizmayla çözülür.
- **(+)** Doğal dil katmanı isteğe bağlı bir önyüz. Model yoksa ürünün geri kalanı etkilenmez.
- **(−)** Bastırma kayıtları ve gecikme durum makinesi kullanıcıya "kural neden şu an çalışmıyor?" sorusunu doğurur. Arayüz her kural için durumunu ve gerekçesini gösterir (`pendingActive 3 sn`, `bastırıldı: elle çözüldü`, `veto: ses çalıyor`).
- **Risk:** Apple Intelligence modelinin Türkçe desteği. `supportsLocale(Locale(identifier: "tr"))` yanlış dönerse Türkçe cümleler desteklenmez ve T-040 kapısı Türkçe için ölçülemez. Bu durumda kapı İngilizce setle ölçülür ve Türkçe desteği model desteğine bağlanır.
- **Risk:** `INFocusStatusCenter` yetkilendirmesi ek bir entitlement veya capability isteyebilir. T-031 bunu doğrular. Gerekirse `focus` yaprağı kaldırılır ve yalnız `focusProfile` kalır.
- **Risk:** Uygulama adı çözümü yanlış eşleşme üretebilir. Belirsizlikte her zaman kullanıcıya sorulur ve onay ekranı bundle ID'yi gösterir.

## Spike'a bağlı

- **T-012 (`PRIO_DARWIN_BG`):** Geçerse `eCore` eylemi bu adla kalır. Geçmezse (P-küme payı ölçülebilir biçimde düşmüyorsa) eylem modelde aynı kalır ama arayüzde ve NL açıklamalarında "arka plan önceliği" adıyla sunulur. `PRIO_DARWIN_BG` disk ve ağ G/Ç'sini de kıstığı için (man sayfası: "disk IO is throttled … network IO is throttled for any sockets opened after going into background state") bu yan etki her iki durumda da arayüzde belirtilir.
- **T-012:** Politikanın başka bir süreç tarafından `setpriority(…, 0)` ile kaldırılabildiği doğrulanmalı. Kaldırılamıyorsa `whileFrontmost: .release` desteklenmez ve düz `eCore` "uygulama yeniden başlayana kadar" semantiğine iner.
- **T-013:** Aktivasyonda çözme 300 ms kapısını geçmezse `freeze` eylemi kurallardan kaldırılır. `RuleValidator` `freeze`'i reddeder, `GeneratedAction.freeze` onay ekranında devre dışı gösterilir ve dondurma yalnız elle, süre sınırlı bir işlem olarak kalır (ADR 0004).
