# Ohm: Apple Silicon için enerji ve çekirdek yöneticisi (plan)

## Bağlam
Kullanıcı, Apple Silicon MacBook'larda eksikliği hissedilen, hafif ama "keşke olsaydı" dedirten bir uygulama, bu uygulamanın yol haritasını, tasarım ve üretim yöntemini ve tanıtım sitesini istiyor. Üç konsept arasından **Ohm** seçildi; dağıtım modeli **tamamen açık kaynak** (GitHub ve Homebrew, bağış).

Çalışma klasörü `/Users/ugurmac/Desktop/macbook` boş ve git deposu değil. Ortam: Apple M3, macOS 27.0, Swift 6.4, Xcode mevcut.

**Karşılanmayan ihtiyaç:** macOS, pilin hangi uygulamaya gittiğini anlaşılır bir birimle göstermiyor (Activity Monitor'deki "Energy Impact" birimsiz ve belirsiz). Kullanıcıya bir uygulamayı verimlilik çekirdeklerine (E-core) sınırlama imkânı da vermiyor. Stats ve iStat izleme yapıyor, App Tamer kısıtlama yapıyor, AlDente şarjı yönetiyor; ölçme, açıklama ve müdahaleyi tek, hafif ve açık kaynak bir yerde birleştiren bir uygulama yok.

## Ürün: Ohm
Menü çubuğunda yaşayan bir uygulama. Tek cümlelik vaadi: **"Pilin nereye gidiyor, gör ve tek tıkla durdur."**

### Özellikler (etki sırasıyla)
1. **Pil fişi:** Her uygulamanın harcadığı enerjiyi joule cinsinden ölçer ve bunu "pil dakikası" ile "pil yüzdesi" olarak gösterir. Örnek: "Slack bugün 38 dk pil yedi."
2. **Canlı güç akışı:** Toplam sistem gücü (`SystemLoad`), GPU gücü, süreç enerjilerinin toplamından CPU gücü, P/E küme doluluğu ve termal baskı. (T-010 sonucu: macOS 27'de IOReport'un CPU/DRAM/ANE enerji sayaçları saniyelik güncellenmiyor; bileşen başına canlı CPU/DRAM/ANE watt'ı gösterilmez.)
3. **E-core şeridi:** Seçilen bir uygulamayı tek tıkla yalnız verimlilik çekirdeklerinde çalıştırır. Uygulama öne gelince eski haline döner (isteğe bağlı).
4. **Dondurma:** Görünmeyen bir uygulamayı tamamen durdurur ve uygulama öne geldiği anda çözer. Çökmeye karşı bir kayıt dosyası (journal) ve otomatik çözme vardır.
5. **Kaçak süreç dedektörü:** Gizli olduğu halde uzun süre yüksek CPU harcayan bir süreci yakalar. Bildirimle birlikte "E-core'a al / dondur / kapat" seçeneklerini sunar.
6. **Kural motoru:** Koşul (güç kaynağı, pil yüzdesi, termal durum, ön plandaki uygulama, saat, Focus) ve eylem (E-core, dondur, bildir) çiftlerinden oluşur.
7. **Doğal dilde kural:** Cihaz üzerinde çalışan Foundation Models ile çalışır. Örneğin "Pil %30'un altındayken Chrome'u E-core'a al" cümlesi yapılandırılmış bir kurala dönüştürülür (`@Generable` ile). Apple Intelligence gerektirdiği için yalnız Apple Silicon'da mümkün.
8. **Pil tahmini:** O anki uygulama karışımına göre kalan süreyi tahmin eder. Basit, çevrimiçi öğrenen bir regresyon kullanır; bulut yok.
9. **Widget, Shortcuts (App Intents) ve `ohm` CLI** (ör. `ohm top`, `ohm ecore Slack`, `ohm receipt --today`).

**Kapsam dışı (v1):** Şarj limiti. SMC'ye yazmak root yetkili bir helper gerektiriyor ve risklidir; ayrı bir karar olarak v2'de ele alınır.

### Hafiflik hedefleri (kabul ölçütü)
- Uygulama paketi 15 MB'tan küçük.
- Boştayken bellek 40 MB'tan az, CPU ortalaması %0,5'ten az.
- Örnekleme aralığı uyarlamalı: popover açıkken 1 sn, kapalıyken 10 sn.
- Ohm kendi işini `.utility`/`.background` QoS ile yapar; yani kendisi de E-core'da çalışır.
- Ağ erişimi yok, telemetri yok. Tek istisna: Sparkle güncelleme kontrolü, o da kapatılabilir.

## Teknik fizibilite (Faz 0'da her biri doğrulanacak)
| İhtiyaç | Yöntem | Risk |
|---|---|---|
| Küme ve bileşen gücü, sudo olmadan | `IOReport` özel framework'ü: "Energy Model" ve "CPU Stats" grupları (macmon'un yaklaşımı) | Özel API olduğu için macOS 27'de değişmiş olabilir. Yedek yol yalnız süreç enerjisi. |
| Süreç başına enerji | `proc_pid_rusage(RUSAGE_INFO_V6)` → `ri_energy_nj` ve `ri_penergy_nj` | Aynı kullanıcının süreçleri okunabilir; root süreçler kısmi kalır. |
| Pil verisi | IOKit `AppleSmartBattery` (voltaj, akım, kapasite, döngü sayısı) ve `IOPSCopyPowerSourcesInfo` | Düşük |
| E-core'a sınırlama | `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` (`taskpolicy -b` ile aynı işi yapar) | Etkisi küme doluluğu ölçülerek doğrulanmalı. |
| Dondur ve çöz | `kill(pid, SIGSTOP/SIGCONT)` ve `NSWorkspace.didActivateApplicationNotification` | Dock'tan tıklanınca çözülme gecikebilir; ses veya ağ kullanan uygulamalar zarar görebilir. Bu yüzden güvenli liste ve journal şart. |
| Doğal dilde kural | FoundationModels (`LanguageModelSession` ve `@Generable`) | Apple Intelligence kapalıysa özellik gizlenir. |

**Önemli dürüstlük notu:** Süreç enerjisi yalnız CPU'yu (ve kısmen GPU'yu) kapsar; ekran ve Wi-Fi harcaması uygulamalara atfedilemez. Arayüz bunu "diğer (ekran, radyo)" satırı olarak ayrıca gösterir.

**App Store dışı:** Sandbox, başka bir uygulamaya sinyal göndermeye izin vermez. Uygulama Developer ID ile imzalanıp notarize edilir. Homebrew imzasız cask'ları kabul etmediği için bu şart; kullanıcının Apple Developer hesabı var (ayrıntı: "İmzalama ve notarization").

## Mimari
```
macbook/
├─ app/                      # XcodeGen project.yml → Ohm.xcodeproj (üretilir, commit edilmez)
│  ├─ OhmCore/               # Swift package: UI'sız, test edilebilir çekirdek
│  │  ├─ Sampling/           # IOReportSampler, ProcessEnergySampler, BatterySampler, ThermalSampler
│  │  ├─ Ledger/             # EnergyLedger: SQLite (sistem sqlite3, bağımlılık yok), günlük dilimler
│  │  ├─ Governor/           # ECoreLane, Freezer (+ FreezeJournal), RunawayDetector
│  │  ├─ Rules/              # Rule modeli, RuleEngine, NLRuleParser (FoundationModels)
│  │  └─ Forecast/           # BatteryForecaster (çevrimiçi lineer regresyon)
│  ├─ OhmApp/                # SwiftUI MenuBarExtra(.window), Settings, Onboarding
│  ├─ OhmWidget/             # WidgetKit: günlük pil fişi
│  └─ ohm-cli/               # swift-argument-parser, OhmCore'u paylaşır
├─ site/                     # tanıtım sitesi (statik)
├─ Docs/                     # ROADMAP.md, DESIGN.md, ADR'ler
└─ .github/workflows/        # build, test, tag'de notarize ve release
```
- **Eşzamanlılık:** Swift 6 strict concurrency. Örnekleyiciler `actor`; UI durumu `@Observable` ve `@MainActor`.
- **Bağımlılıklar:** Sparkle 2 (güncelleme) ve swift-argument-parser. Başka bağımlılık yok.
- **Lisans:** MIT.

## Tasarım (UX)
- **İlkeler:** Tamamen yerel macOS hissi (SF Pro, SF Symbols, macOS 26+ Liquid Glass malzemesi), sıfır ayar ile değer verme, derinliğin kademeli açılması (progressive disclosure).
- **Menü çubuğu simgesi:** İçinde anlık watt değerini gösteren küçük bir halka. Rengi termal duruma göre değişir. İstenirse sayı olarak da gösterilebilir.
- **Popover taslağı:**
```
┌───────────────────────────────┐
│ ⚡ 7.4 W   ▮▮▮▯ P  ▮▮▮▮▮▯ E  🌡 │  canlı güç + küme doluluğu
│ Pil: 62% · tahmin 5 sa 10 dk  │
├───────────────────────────────┤
│ Bugünün fişi                  │
│ Chrome      1 sa 12 dk  [E][❄]│  satır: pil dakikası + hızlı eylem
│ Slack          38 dk    [E][❄]│
│ Diğer (ekran, radyo) 2 sa     │
├───────────────────────────────┤
│ ⚠ node 94% CPU, 12 dk gizli   │  kaçak süreç kartı
│   [E-core'a al] [Dondur] [Kapat]│
├───────────────────────────────┤
│ Kurallar (3 aktif)  + "yaz..." │  doğal dilde kural girişi
└───────────────────────────────┘
```
- **Tasarım süreci:** Önce `Docs/DESIGN.md`'de bilgi mimarisi ve durum tablosu (boş, şarjda, sıcak, kaçak süreç var) yazılır. Ardından SwiftUI Preview ile ekran varyantları hazırlanır; ayrı bir Figma aşaması yoktur. Son olarak açık/koyu tema ve erişilebilirlik (VoiceOver etiketleri, Reduce Motion) kontrol edilir.

## Tanıtım sitesi (`site/`)
- **Teknoloji:** Bağımlılıksız statik HTML, CSS ve biraz vanilla JS. Build adımı yok; Lighthouse performans puanı hedefi 95'in üzeri.
- **Dil:** İngilizce varsayılan, Türkçe sürüm `/tr/` altında (açık kaynak kitlesi küresel olduğu için; varsayım).
- **Bölümler:**
  1. Hero: "Where did your battery go?" başlığı ve CSS/SVG ile canlandırılmış popover maketi. Video yok, watt değerleri canlı gibi değişir.
  2. Etkileşimli pil fişi demosu: Uygulama satırına tıklanınca "E-core'a al" animasyonu ve tasarruf edilen dakikalar görünür.
  3. Özellik ızgarası: E-core şeridi, dondurma, kaçak süreç dedektörü, doğal dilde kural, widget, CLI.
  4. "Neden yalnız Apple Silicon": P/E çekirdekler, birleşik bellek, ANE ve cihaz üstü model, kısa bir diyagramla.
  5. Gizlilik: Ağ yok, telemetri yok, kaynak kodu açık.
  6. Karşılaştırma tablosu: Activity Monitor, Stats, App Tamer ve Ohm.
  7. İndirme: GitHub Release ve `brew install --cask ohm`, sistem gereksinimi (M1+, macOS 15+).
  8. Katkı ve bağış (GitHub Sponsors), SSS.
- **Görsel dil:** Koyu zemin, enerjiyi anlatan tek bir vurgu rengi (elektrik yeşili ya da amber; tasarım adımında seçilecek). Tipografi SF Pro yerine web için Inter/Geist. `prefers-color-scheme` ve `prefers-reduced-motion` desteklenir.
- **Yayın:** GitHub Pages, adres `kuarezma.github.io/ohm` (`gh` bu hesapla oturum açmış durumda). Site, repodaki `site/` klasöründen bir GitHub Actions Pages workflow'uyla yayınlanır; alan adı gerekmez. Kullanıcı ileride bir alan adı alırsa yalnız bir `site/CNAME` dosyası ve DNS kaydı eklenir; site kodu değişmez. Bu yüzden bütün bağlantılar göreli yazılır (`/ohm/` tabanına bağımlı değil). Repo oluşturma, push ve Pages'i açma dışa dönük işlerdir; her biri için ayrıca onay alınır.

## Yol haritası
| Faz | Süre (tahmini) | Çıktı | Kapı |
|---|---|---|---|
| **0: Spike** | 1 hafta | 4 küçük CLI deneyi: IOReport, `ri_energy_nj`, `PRIO_DARWIN_BG` etkisi, SIGSTOP ile aktivasyonda çözme | Her deneyin M3 + macOS 27 üzerinde ölçülmüş bir sonucu olur. IOReport çalışmazsa kapsam yedek yola daraltılır. |
| **1: MVP** | 3–4 hafta | Menü çubuğu popover'ı, canlı watt, enerji defteri (ledger), pil dakikası, E-core düğmesi, repo, site v1 | Boştaki bellek ve CPU hedefleri tutar; E-core küme doluluğunu ölçülebilir biçimde değiştirir. |
| **2: Yönetim** | 3 hafta | Journal'lı dondurma, kaçak süreç dedektörü, kural motoru (arayüzle), bildirimler, widget, CLI | Ohm'u zorla öldürme testinde (kill -9) dondurulmuş uygulama kalmaz. |
| **3: Zeka** | 2–3 hafta | Doğal dilde kural, pil tahmini, geçmiş ve haftalık fiş, App Intents | 20 örnek cümlenin en az 18'i doğru kurala dönüşür; tahmin hatası 20 dakikanın altında kalır. |
| **4: Lansman** | 1–2 hafta | Notarize edilmiş sürüm, Sparkle appcast, Homebrew cask, site v2 (TR/EN), HN, r/macapps, Product Hunt | Temiz bir Mac'te kurulum sırasında Gatekeeper uyarısı çıkmaz. |
| v2 (sonra) | – | Şarj limiti helper'ı, fan ve sıcaklık, çoklu Mac karşılaştırması | Ayrı mimari kararı gerekir. |

## Nasıl üretilecek: görevlerin modellere dağılımı
Kaynak: `~/Desktop/model_görevleri/ROUTING.md` (Artificial Analysis ölçümleri, 28 Eyl 2026). Seçimi belirleyen üç ölçüm:
- **Gemini 3.8 Flash high** (zeka 40.9, AutomationBench %59.9) aboneliğiyle neredeyse sınırsız. Ancak terminalde zayıf (TerminalBench %19.7) ve bilgi doğruluğu %54.6. Bu yüzden yalnız kapıyla doğrulanabilen, iyi tanımlı işleri alır ve kullanacağı API olguları ona görev kartında verilir.
- **Opus 5.5 high** (zeka 53.6, bilgi doğruluğu %64.6, TerminalBench %56.6), özel API'ler, C interop ve veri kaybı riski taşıyan kod için doğru model.
- **Sonnet 5.5 max** yalnız bir durumda kullanılır: terminal döngüsü Opus high'ta tıkanırsa (TerminalBench %63.6, bütün modellerin en yükseği). Sonnet xhigh hiç kullanılmaz; Opus medium aynı zekada daha ucuz.

### Orkestrasyon: bütün modelleri şef çalıştırır
Kullanıcı hiçbir modeli elle çağırmaz ve hiçbir komut kopyalamaz. Her devri şef (bu oturum) kendi araçlarıyla başlatır, sonucunu bekler, kapıdan geçirir ve merge eder. Kullanıcıya yalnız özet, ölçüm satırları ve onay gerektiren kararlar gelir. Onay gerektiren kararlar: herkese açık yayın, push, Apple Developer hesabı ve silme.

| Model | Şefin kullandığı araç | Kurulum durumu |
|---|---|---|
| Opus 5.5 high / xhigh | `Agent` aracı, `subagent_type: opus-high` / `opus-xhigh`; arka planda ve kendi worktree'sinde (`isolation: worktree`) | `~/.claude/agents/` içinde mevcut |
| Sonnet 5.5 max | `Agent` aracı, `subagent_type: sonnet-max` | Mevcut |
| Gemini 3.8 Flash | `Skill` aracı: `agy:implementer`, `agy:researcher`, `agy:staffer`; arka planda çalışır, bitince bildirim gelir; efor şef tarafından `high` verilir | `agy` kurulu |
| GLM 5.3 / Kimi K3 (yedek) | `Bash`: `opencode run -m nvidia/z-ai/glm-5.3 --variant max --dir <worktree> "<kart>"` (`run_in_background`) | `opencode` kurulu |
| Muse Spark 1.3 / Opus yedeği | `Bash`: `cursor-agent -p --model <id> "<kart>"` | `cursor-agent` kurulu |
| GPT-6 Astra (danışman) | `Skill` aracı: `codex:rescue --model gpt-6-astra --effort <medium\|high\|xhigh>`; salt okunur ("do not edit, report only") | `codex-cli 0.158.0` kurulu (0.157 ve üstü gerekir) |

**Astra'nın rolü:** Kullanıcı Astra'yı kullanmaya izin verdi. Astra high'ın ölçümleri: zeka 50.9, TerminalBench %54, bilgi doğruluğu %61.1, halüsinasyon oranı %44.8 (güçlü modeller arasında en düşük), görev başına 11.8k token. Astra kod yazmaz, **farklı model ailesinden ikinci görüş** verir: Opus'un yazdığını Opus'tan başka bir aile denetlemiş olur. Codex kotası kıt olduğu için aynı soru hem Opus'a hem Astra'ya sorulmaz. Astra'ya olgular ve şefin kendi görüşü birlikte verilir, "katılmıyorsan gerekçelendir" denir. Astra'nın yanıtı tavsiyedir; son karar ve doğrulama şefte kalır.

**Her devrin döngüsü:**
1. Şef `handoff` ile bir görev kartı yazar. Kart; hedefi, dosyaları, verilen API olgularını, kabul komutunu ve yapılmayacakları içerir.
2. Şef modeli yukarıdaki araçla arka planda başlatır ve kullanıcıya tek satırla bildirir: "T-0XX → Gemini high, çünkü …".
3. Bağımsız görevler aynı anda paralel başlatılır. Şef bu sırada kendi satırındaki işi yapar; sonucu tahmin etmez, bildirimi bekler.
4. Dönüşte şef `gate` ile kabul komutunu kendisi çalıştırır. Geçerse merge edip worktree'yi kaldırır. Kalırsa merdivende bir basamak çıkar.
5. Devir sonucu `DEVIR-LOG.md`'ye bir satır olarak yazılır.

### Görev tablosu
Zeka skalası: CC (Claude Code) 🔵2 orta · 🟡3 yüksek · 🟣5 max, AG (Antigravity) 🔴3 yüksek.

| ID | Görev | Model (efor) | Zeka | Çağrı | Neden bu model | Kabul kapısı |
|---|---|---|---|---|---|---|
| T-001 | Mimari ADR: modül sınırları, ledger şeması, kural DSL'i, dondurma güvenlik modeli | Opus 5.5 (high) | CC 🟡3 | `opus-high` ajanı | Geri dönüşü zor mimari kararlar | `Docs/adr/0001..0004.md`'yi şef review eder |
| T-001b | ADR'ye ikinci görüş: özellikle dondurma güvenlik modeli ve özel API bağımlılığı | GPT-6 Astra (medium) | Codex 🟡2 | `codex:rescue --model gpt-6-astra --effort medium`, salt okunur | Geri dönüşü zor karar için farklı ailenin görüşü | Şef itirazları ADR'de karara bağlar |
| T-002 | Rakip taraması (Stats, App Tamer, iStat, macmon, AlDente) ve macOS 27'deki güç/IOReport değişiklikleri | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:researcher` | Tarama ve özet; kota bol | Kaynak linkli rapor, şef doğrular |
| T-010 | Spike: IOReport ile sudo'suz watt okuma | Opus 5.5 (high) | CC 🟡3 | `opus-high` | Özel API ve C interop; Gemini'nin bilgi doğruluğu burada yetersiz | M3'te watt değeri basılır ve `powermetrics` ile ±%15 içinde tutar |
| T-011 | Spike: `ri_energy_nj` ile süreç başına enerji | Opus 5.5 (high) | CC 🟡3 | `opus-high` (T-010 ile aynı ajan) | Aynı bağlam, devir maliyeti yok | 3 uygulamanın joule değeri tutarlı çıkar |
| T-012 | Spike: `PRIO_DARWIN_BG` ile E-core'a sınırlama | Opus 5.5 (high) | CC 🟡3 | `opus-high` | Etkinin ölçümle kanıtlanması gerek | Önce/sonra P-küme payı düşer |
| T-013 | Spike: SIGSTOP ve aktivasyonda otomatik çözme | Opus 5.5 (high) | CC 🟡3 | `opus-high` | Kullanıcının uygulamalarını donuk bırakma riski | Dock tıklamasından 300 ms içinde yanıt, `kill -9` sonrası donuk uygulama kalmaz |
| T-020 | Proje iskeleti: XcodeGen `project.yml`, `Package.swift`, hedefler, lint | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Tarifli boilerplate | `xcodegen && xcodebuild build` yeşil |
| T-021 | `OhmCore/Sampling`: spike'ları üretim koduna taşıma (actor'ler) | Opus 5.5 (high) | CC 🟡3 | `opus-high` | Özel API ve Swift 6 strict concurrency | Birim testler yeşil, boşta CPU <%0,5 |
| T-022 | `Ledger`: SQLite enerji defteri ve pil dakikası hesabı | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Şema T-001'de hazır; saf mantık | Hesap testleri yeşil |
| T-023 | `Governor`: ECoreLane, Freezer ve FreezeJournal | Opus 5.5 (high) | CC 🟡3 | `opus-high` | Veri kaybı riski; spike'ları yapan model sürdürür | Çökme ve kurtarma testleri yeşil |
| T-024 | Kritik review: T-021 ve T-023 (sinyal güvenliği, journal kurtarma, özel API hataları) | GPT-6 Astra (high) | Codex 🟠3 | `codex:rescue --model gpt-6-astra --effort high`, salt okunur | Farklı aile ve düşük halüsinasyon oranı; kodu Opus yazdı | Bulgular şefin testleriyle doğrulanıp kapanır |
| T-030 | SwiftUI: popover, menü çubuğu halkası, Settings, onboarding | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Görsel/UI işi | Preview ekran görüntüleri, açık/koyu tema, VoiceOver etiketleri |
| T-031 | RuleEngine ve kural arayüzü | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | DSL T-001'de tanımlı; test edilebilir mantık | Kural değerlendirme testleri yeşil |
| T-032 | RunawayDetector ve bildirimler | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | İyi tanımlı eşik mantığı | Sahte yük testiyle tetiklenir |
| T-033 | Widget, App Intents ve `ohm` CLI | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Tarifli entegrasyon | `ohm receipt --today` çıktısı ve widget önizlemesi |
| T-040 | Doğal dilde kural (FoundationModels + `@Generable`) | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` (API imzaları kartta verilir) | Değerlendirme setiyle ölçülebilir | 20 cümleden en az 18'i doğru; 2 kez kalırsa `opus-high`'a geçer |
| T-041 | Pil tahmini (çevrimiçi regresyon) | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Küçük matematik, test edilebilir | Kayıtlı veride hata <20 dk |
| T-050 | Site tasarım yönü: renk, tipografi, bölüm akışı, TR/EN metin taslağı | Opus 5.5 (medium) | CC 🔵2 | Şef kendisi (`frontend-design` skill'i) | Ürün sesi ve konumlandırma kararı; kısa iş | `Docs/SITE-BRIEF.md` |
| T-051 | Site v1 kodu: HTML/CSS/JS, animasyonlu popover maketi, fiş demosu | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Görsel/UI | 390 ve 1440 px ekran görüntüsü, konsolda hata yok, Lighthouse ≥95 |
| T-052 | Sitenin Türkçe sürümü ve metin cilası | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:staffer` | Çeviri ve yerelleştirme | Metni şef okur |
| T-060 | CI: GitHub Actions ile build, test, notarize ve Sparkle appcast | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Tarifli YAML | Tag'de dry-run yeşil; 2 kez kalırsa Opus high, terminalde tıkanırsa Sonnet max |
| T-061 | Performans ölçümü: Instruments/`xctrace` ile boştaki bellek ve CPU | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:staffer` | Mekanik ölçüm; yorumu şef yapar | Hedef tablo dolar |
| T-062 | Homebrew cask, README ve katkı rehberi | Gemini 3.8 Flash (high) | AG 🔴3 | `/agy:implementer` | Doküman ve tarifli iş | `brew audit` temiz |
| – | Görev kartları, kapılar, merge, kullanıcıyla konuşma | Opus 5.5 (medium) | CC 🔵2 | Şef | `handoff` ve `gate` skill'leri | – |

**Yedek:** Gemini'ye erişilemezse kod işleri GLM 5.3 (max), doküman ve özet işleri Muse Spark 1.3 (xhigh) üstlenir. Bu yedekler henüz hiçbir kapıdan geçmediği için önce yalnız mekanik işlerde (T-052, T-062) denenir.

**Merdiven:** Gemini'ye bir görevde en fazla 2 deneme hakkı verilir; ardından iş sırasıyla Opus medium'a, Opus high'a ve (yalnız terminal döngüsü tıkanırsa) Sonnet max'e çıkar. Opus high da iki kez çözemezse şef, Astra high'dan (gerekirse xhigh) salt okunur bir teşhis ister ve düzeltmeyi Opus uygular. Gemini'nin yazdığı kodu Gemini denetlemez, onu Opus review eder. Her devir `~/Documents/PROJELER/ai-model-ve-token-yonetimi/DEVIR-LOG.md` dosyasına bir satır olarak yazılır.

**Şefin eforu:** Bu oturum şu an high eforda. Kurala göre şef medium'da çalışmalı. Sohbet henüz kısa olduğu için önbelleği sıfırlamanın maliyeti şu an düşük; uygulamaya geçmeden önce `/effort medium` yapılması önerilir.

### Dalgalar (paralel çalışma sırası)
1. **Dalga 1, paralel:** T-001 (bitince T-001b Astra) ve T-010…T-013 (aynı `opus-high` ajanı içinde sırayla), T-002 (Gemini) ve T-050 (şef).
2. **Dalga 2:** Spike kapısı geçilirse T-020 başlar. Ardından T-021 ile T-023 (Opus) ve T-022 (Gemini) paralel yürür. T-051 site işi bu dalgayla birlikte paralel ilerler.
3. **Dalga 3:** T-024 review, sonra T-030…T-033 (Gemini, ayrı worktree'lerde paralel).
4. **Dalga 4:** T-040 ile T-041, sonra T-052 ve T-060…T-062.

**Git düzeni:** `git init`. Her görev kendi worktree'sinde çalışır (`git worktree add -b t-0XX ../worktrees/t-0XX main`). Merge yalnız kapıdan geçen görev için yapılır; worktree iş bitince kaldırılır.

## Onaydan sonra bu oturumda yapılacaklar
1. `git init`, iskelet klasörler, `docs/ROADMAP.md` ve `Docs/DESIGN.md` (şef yapar; birkaç araç çağrısı sürer). Tur 0: `Docs/coordination/TASKS.md` dosyasına yukarıdaki kartlar `handoff` formatında yazılır.
2. Dalga 1 başlatılır: T-001 ve T-010…013 `opus-high` ajanına, T-002 `/agy:researcher`'a (her ikisi arka planda), T-050 şefin kendisine.
3. Spike sonuçları geldikçe `gate` ile kontrol edilir ve kullanıcıya ölçüm satırlarıyla raporlanır. Dalga 2 ancak spike kapısı geçilirse başlar.
4. Site v1 (T-051) kapıdan geçince yerelde önizlenir; istenirse private Artifact olarak paylaşılır. Herkese açık yayın ayrıca onay ister.

## Doğrulama
- **Spike'lar:** `swift spikes/ioreport.swift` benzeri komutlar watt değerleri basmalı. `PRIO_DARWIN_BG` sonrası hedef sürecin P-küme payı düşmeli (IOReport ile önce/sonra karşılaştırılır). SIGSTOP uygulanan bir uygulama Dock'tan tıklandığında 300 ms içinde yanıt vermeli.
- **Uygulama (Faz 1+):** `xcodebuild test` ile OhmCore birim testleri (ledger hesapları, kural değerlendirmesi, journal kurtarma). Instruments ile boştaki bellek ve CPU ölçümü. `kill -9` ile Ohm'u öldürme ve yeniden başlatma testi.
- **Site:** Yerel sunucuda Chrome ile 390 px ve 1440 px genişlikte ekran görüntüsü; konsolda hata olmamalı; Lighthouse performans ve erişilebilirlik puanları 95'in üzerinde; açık/koyu tema ve reduced-motion kontrolü.

## İmzalama ve notarization
Kullanıcının Apple Developer hesabı var. Anahtarlıkta şu an yalnız bir **"Apple Development"** sertifikası bulunuyor. Bu sertifika geliştirme ve yerel çalıştırma için yeterli; Faz 0–3 bununla ilerler.

App Store dışı dağıtım için Faz 4'ten önce kullanıcının iki adımı yapması gerekiyor. Şef bu adımları o sırada hatırlatır; ikisi de interaktif olduğu için şef yapamaz:
1. Xcode › Settings › Accounts › Manage Certificates › **+ Developer ID Application**.
2. `! xcrun notarytool store-credentials ohm --apple-id <apple-id> --team-id <team-id>`. Bu komut uygulamaya özel bir parola sorar. Şef sonra bu `ohm` profilini kullanır.

CI tarafında (T-060) sertifika ve notary kimlik bilgileri GitHub Actions secret'ı olarak eklenir. Secret'ları kullanıcı girer; şef bu değerleri hiçbir zaman görmez ve loglamaz.

## Kullanıcıya açık kararlar (plan onayını engellemez)
- İsim: "Ohm" çalışma adı. Marka kontrolü lansmandan önce yapılacak. Alan adı isteğe bağlı: başlangıçta GitHub Pages yeterli, gerekirse kullanıcı sonra alır.
