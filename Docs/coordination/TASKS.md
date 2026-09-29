# Görev Panosu — Ohm

Durum kodları: `DONE` · `TODO` · `IN-PROGRESS` · `BLOCKED` · `REVIEW` (kapı bekliyor).
Her görevin model seçimi ve gerekçesi `Docs/PLAN.md` § "Görev tablosu"ndadır.

| id | kapsam | sahip | zeka | bağımlılık | durum | kabul kriteri |
|----|--------|-------|------|-----------|-------|---------------|
| T-001 | Mimari ADR'ler (modüller, ledger şeması, kural DSL'i, dondurma güvenliği) | Opus 5.5 high | CC 🟡3 | – | REVIEW | `Docs/adr/0001..0004.md`, şef review |
| T-001b | ADR'ye ikinci görüş | GPT-6.1 Sol high (salt okunur) | Codex 🟠3 | T-001 | DONE | İtirazlar ADR'de karara bağlanır |
| T-002 | Rakip ve macOS 27 güç API taraması | Gemini 3.8 Flash high | AG 🔴3 | – | DONE | `Docs/research/competitors.md`, her iddia linkli |
| T-010 | Spike: IOReport ile sudo'suz watt | Opus 5.5 high | CC 🟡3 | – | DONE (PARTIAL) | Aşağıdaki kart |
| T-011 | Spike: `ri_energy_nj` ile süreç enerjisi | Opus 5.5 high | CC 🟡3 | – | DONE | Aşağıdaki kart |
| T-012 | Spike: `PRIO_DARWIN_BG` ile E-core | Opus 5.5 high | CC 🟡3 | T-010 | DONE | Aşağıdaki kart |
| T-013 | Spike: SIGSTOP ve aktivasyonda çözme | Opus 5.5 high | CC 🟡3 | – | DONE | Aşağıdaki kart |
| T-020 | XcodeGen iskeleti | Gemini 3.8 Flash high | AG 🔴3 | spike kapısı, T-001 | DONE | `xcodegen && xcodebuild build` yeşil |
| T-021 | OhmCore/Sampling | Opus 5.5 high | CC 🟡3 | T-020 | DONE | Testler yeşil, boşta CPU <%0,5 |
| T-022 | Ledger (SQLite) | Gemini 3.8 Flash high | AG 🔴3 | T-020 | DONE | Hesap testleri yeşil |
| T-023 | Governor (ECoreLane, Freezer, Journal) | Opus 5.5 high | CC 🟡3 | T-020 | DONE | Çökme/kurtarma testleri yeşil |
| T-024 | Kritik review T-021 + T-023 | GPT-6 Astra high | Codex 🟠3 | T-021, T-023 | DONE | Bulgular testle kapanır |
| T-025 | Kararsız Governor testleri 20 ve 22a: kök neden | GPT-6.1 Sol medium | Codex 🟡2 | T-023 | DONE | 20× Governor suite + 3× tam `swift test` kırmızısız |
| T-026 | Dondurma güvenliği P1'leri + otomatik dondurma izin listesi (T-001b #1–4, #8) | GPT-6.1 Sol high | Codex 🟠3 | T-025 | TODO | Her bulguya regresyon testi; Governor/Journal testleri yeşil; kritik review Opus high |
| T-027 | Ledger doğruluğu (T-001b #10–16, #18) | GPT-6.1 Sol medium | Codex 🟡2 | – | TODO | Her bulguya test; `swift test --filter OhmLedger` yeşil; ADR 0002 tek GPU kararı |
| T-028 | Kural derleyici/motor doğruluğu (T-001b #5–7, #9) | GPT-6.1 Sol medium | Codex 🟡2 | – | TODO | Her bulguya test; `swift test --filter OhmRules` yeşil |
| T-029 | Örnekleme geri basıncı (T-001b #17) | GPT-6.1 Sol medium | Codex 🟡2 | – | TODO | Tüketici durunca bellek sınırlı; enerji toplamı korunur (test) |
| T-030 | SwiftUI popover, halka, Settings, onboarding | Gemini 3.8 Flash high | AG 🔴3 | T-021 | DONE | Preview görüntüleri, açık/koyu, VoiceOver |
| T-031 | RuleEngine ve kural arayüzü | Gemini 3.8 Flash high | AG 🔴3 | T-001 | DONE | Kural testleri yeşil |
| T-032 | RunawayDetector ve bildirimler | Gemini 3.8 Flash high | AG 🔴3 | T-021 | TODO | Sahte yükte tetiklenir |
| T-033 | Widget, App Intents, `ohm` CLI | Gemini 3.8 Flash high | AG 🔴3 | T-022 | TODO | `ohm receipt --today` çıktısı |
| T-040 | Doğal dilde kural (FoundationModels) | Gemini 3.8 Flash high | AG 🔴3 | T-031 | DONE | 20 cümlede ≥18 doğru |
| T-041 | Pil tahmini | Gemini 3.8 Flash high | AG 🔴3 | T-022 | DONE | Hata <20 dk |
| T-050 | Site tasarım yönü ve metin taslağı | Opus 5.5 medium (şef) | CC 🔵2 | – | DONE | `Docs/SITE-BRIEF.md` |
| T-051 | Site v1 kodu | Gemini 3.8 Flash high | AG 🔴3 | T-050 | DONE | 390/1440 px görüntü, konsol temiz, Lighthouse ≥95 |
| T-052 | Site Türkçe sürümü | Gemini 3.8 Flash high | AG 🔴3 | T-051 | DONE | Şef okur |
| T-060 | CI: build, test, notarize, appcast | Gemini 3.8 Flash high | AG 🔴3 | T-020 | TODO | Dry-run yeşil |
| T-061 | Performans ölçümü | Gemini 3.8 Flash high | AG 🔴3 | T-030 | TODO | Hedef tablo dolar |
| T-062 | Homebrew cask, README, katkı rehberi | Gemini 3.8 Flash high | AG 🔴3 | T-060 | TODO | `brew audit` temiz |

---

### T-010 Spike: IOReport ile sudo'suz watt okuma
Model: Opus 5.5 (high) | Zeka: CC 🟡3
Amaç: `libIOReport` üzerinden CPU (P/E küme), GPU, ANE, DRAM enerjisini sudo'suz okuyup watt olarak basmak.
Yer: `spikes/ioreport/` (tek dosyalık Swift veya C + Swift; `spikes/README.md`'ye sonuç).
Kabul kapısı: `spikes/ioreport/run.sh` 10 sn boyunca saniyede bir satır basar (`cpu_p_W cpu_e_W gpu_W ane_W dram_W`). Boşta ve `yes > /dev/null` yükü altında CPU değeri belirgin artar. Karşılaştırma için aynı anda `AppleSmartBattery` sistem gücü (Voltage × Amperage) okunur; IOReport toplamı sistem gücünden küçük olmalı ve yükle birlikte hareket etmeli (sudo olmadığı için `powermetrics` kullanılamaz).
Dokunma: `spikes/` dışı.
Olgular: macmon (Rust, github.com/vladkens/macmon) aynı işi sudo'suz yapar; referans olarak kaynağı okunabilir. Kanal grupları: "Energy Model", "CPU Stats" / "CPU Core Performance States", "GPU Stats". Fonksiyonlar `IOReportCopyChannelsInGroup`, `IOReportCreateSubscription`, `IOReportCreateSamples`, `IOReportCreateSamplesDelta`, `IOReportSimpleGetIntegerValue`, `IOReportChannelGetUnitLabel` vb. `/usr/lib/libIOReport.dylib`'ten dlopen veya link ile gelir; başlık yoktur, prototipler elle yazılır. Birim etiketi mJ/uJ/nJ olabilir; etikete göre dönüştür.
Durum: DONE (PARTIAL) — CPU/DRAM/ANE enerji sayaçları 1 Hz güncellenmiyor; yedek tasarım `spikes/README.md`

### T-011 Spike: süreç başına enerji
Model: Opus 5.5 (high) | Zeka: CC 🟡3
Amaç: `proc_pid_rusage(pid, RUSAGE_INFO_V6, …)` ile her sürecin `ri_energy_nj` ve `ri_penergy_nj` değerlerini okuyup 5 sn aralıkla watt ve joule olarak listelemek.
Yer: `spikes/procenergy/`.
Kabul kapısı: `spikes/procenergy/run.sh` en çok enerji harcayan 10 süreci basar. `yes > /dev/null` süreci listenin başına çıkar ve ~1 çekirdeğe denk bir güç gösterir. Okunamayan (root) süreç sayısı raporlanır.
Dokunma: `spikes/` dışı.
Olgular: `<libproc.h>`, `proc_listallpids`, `proc_pid_rusage`, `struct rusage_info_v6` (`<sys/resource.h>`). Alan adlarını SDK başlığından oku, hatırlamaya çalışma: `grep -n "ri_energy_nj\|ri_penergy_nj" $(xcrun --show-sdk-path)/usr/include/sys/resource.h`.
Durum: TODO

### T-012 Spike: E-core'a sınırlama
Model: Opus 5.5 (high) | Zeka: CC 🟡3
Amaç: `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` uygulanan bir sürecin P-kümeden E-kümeye geçtiğini ölçmek.
Yer: `spikes/ecore/`.
Kabul kapısı: Script 4 adet `yes` yükü başlatır, 5 sn ölçer, ardından BG politikası uygular, 5 sn daha ölçer, sonra politikayı kaldırır. T-011'deki `ri_penergy_nj / ri_energy_nj` oranı (P-core enerji payı) ve/veya T-010'daki küme gücü önce/sonra tablo olarak basılır. Beklenen: BG sonrası P payı belirgin düşer. Script sonunda bütün `yes` süreçlerini öldürür.
Dokunma: `spikes/` dışı; kendi başlattığı süreçler dışında hiçbir sürece politika uygulama.
Olgular: `<sys/resource.h>`: `PRIO_DARWIN_PROCESS`, `PRIO_DARWIN_BG`; kaldırmak için değer 0. `taskpolicy -b -p <pid>` aynı etkiyi verir (karşılaştırma için).
Durum: TODO

### T-013 Spike: dondurma ve aktivasyonda çözme
Model: Opus 5.5 (high) | Zeka: CC 🟡3
Amaç: Bir GUI uygulamasını SIGSTOP ile dondurup, aktive edildiği an SIGCONT ile çözen küçük bir ajan; ayrıca ajan `kill -9` ile öldürülse bile donuk süreç kalmamasını sağlayan journal + ayrı çözme mekanizması.
Yer: `spikes/freeze/`.
Kabul kapısı: Hedef olarak yalnız ajanın kendisinin başlattığı bir uygulama kullanılır (ör. `open -na TextEdit` ile yeni örnek, pid'i kaydedilir). (1) Dondurulduktan sonra `ps -o stat= -p <pid>` → `T`. (2) `open -a TextEdit` ile aktive edilince SIGCONT gecikmesi ölçülür ve basılır (hedef <300 ms). (3) Ajan donmuş bir süreç varken `kill -9` ile öldürülür; journal'dan çözen mekanizma (ör. ayrı watchdog süreci veya bir sonraki açılışta kurtarma) sonrasında `ps` durumu `T` değildir. Sonuçlar `spikes/README.md`'ye.
Dokunma: Kullanıcının zaten açık olan uygulamalarına asla sinyal gönderme. Test sonunda başlattığın TextEdit örneğini kapat.
Olgular: `NSWorkspace.shared.notificationCenter`, `NSWorkspace.didActivateApplicationNotification`, `NSRunningApplication.processIdentifier`; `kill(pid, SIGSTOP/SIGCONT)`. Dock tıklaması otomasyonla yapılamaz; aktivasyon `open -a` ile tetiklenir, Dock davranışı elle testte doğrulanacak diye not düş.
Durum: TODO
