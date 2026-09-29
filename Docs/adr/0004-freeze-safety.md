# ADR 0004: Dondurma (SIGSTOP) güvenlik modeli

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü (özellikle bu ADR) bekleniyor. Faz 0 spike sonuçları işlendi (`spikes/README.md`, `main` 5773b60).
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0001 (`Governor`, `ohm-thawd`, `OhmJournal`), ADR 0003 (kural semantiği, vetolar), T-013 (spike), T-023 (uygulama), T-024 (kritik review)
- **Önem:** Bu ADR, kullanıcı verisini kaybettirebilecek tek yolu yönetiyor. Aşağıdaki değişmezlerden biri bozulursa dondurma özelliği kapatılır.

## Bağlam

`kill(pid, SIGSTOP)` bir süreci çekirdek düzeyinde durdurur. Süreç `SIGCONT` alana kadar hiçbir kod çalıştıramaz: olay işleyemez, AppleEvent'e yanıt veremez, soketlerine bakamaz, zamanlayıcıları çalışmaz. SIGSTOP'un kendisi bellekteki veriyi silmez. **Veri kaybı dolaylı yoldan gelir:**

| # | Tehdit | Nasıl veri kaybına dönüşür |
|---|---|---|
| T1 | Ohm ölür ve uygulama donuk kalır | Kullanıcı "donmuş" uygulamayı Zorla Çık ile kapatır ve kaydedilmemiş belgesi gider. |
| T2 | Donuk uygulama varken oturum kapatma, yeniden başlatma veya kapatma | Uygulama çıkış AppleEvent'ine ve "Kaydet?" penceresine yanıt veremez. loginwindow işlemi iptal eder ya da süreci öldürür. |
| T3 | Zorla Çık penceresi donuk uygulamayı "Yanıt Vermiyor" olarak gösterir | Kullanıcı sorunu yanlış anlar ve zorla kapatır. |
| T4 | Başkalarının bağımlı olduğu bir süreç dondurulur | Event tap sahibi dondurulursa sistem genelinde girdi takılır. Ses süreci dondurulursa arama kopar. Sistem arayüzü süreçleri dondurulursa Dock ve pencere geçişi bozulur. |
| T5 | Uygulama ağacı yarım dondurulur | Chrome'un ana süreci çalışırken renderer'ları durdurulursa, ana süreçteki donma bekçisi (hang watchdog) sekmeyi "yanıt vermiyor" sayıp sonlandırabilir ve formdaki veri kaybolur. Tersine, yalnız ana süreç durdurulursa helper'lar CPU harcamaya devam eder. |
| T6 | Ağ oturumları süre aşımına uğrar | Görüntülü arama kopar, yükleme yarıda kalır, SSH oturumu ölür. |
| T7 | pid yeniden kullanılır | İlgisiz bir süreç SIGSTOP alır (tehlikeli) ya da SIGCONT alır (çoğunlukla zararsız). |
| T8 | Zamana duyarlı olaylar kaçar | Takvim alarmı, mesaj veya hatırlatıcı gelmez. Veri kaybı değil ama zarar. |
| T9 | Journal bozulur veya iki yazar çakışır | Hangi süreçlerin donuk olduğu bilgisi kaybolur ve T1'e dönüşür. |

Faz 0 ölçümleri (M3, macOS 27; T-012, T-013):
- Donuk (SIGSTOP) bir uygulama `open -a` ile aktive edildiğinde `NSWorkspace.didActivateApplicationNotification` yine geliyor. Aktivasyon, uygulamanın iş birliğini gerektirmiyor. Aktivasyondan SIGCONT'a kadar geçen süre 17–18 ms.
- **Öndeki uygulama yeniden aktive edilirse bildirim gelmiyor.** Gizleme (`NSRunningApplication.hide()`) uygulamanın çalışmasını gerektirdiği için SIGSTOP'tan **önce** yapılmalı.
- Ajan `kill -9` ile öldürüldüğünde ayrı bir izleyici süreç 36–39 ms içinde çözdü. İkisi birlikte öldürüldüğünde, bir sonraki açılışta journal'dan kurtarma süreci çözdü. Pid yeniden kullanımına karşı `ri_proc_start_abstime` kullanıldı.
- `getpriority(PRIO_DARWIN_PROCESS, pid)` BG politikası uygulanmışken de 0 döndürüyor. Politika durumu sistemden okunamıyor. `setpriority(…, 0)` politikayı başka bir süreçten kaldırabiliyor.
- Dock tıklaması ve Cmd-Tab otomasyonla test edilemedi, **elle doğrulanmadı**.

Kaynak olgular (SDK ve man sayfasından doğrulandı): CoreAudio `kAudioHardwarePropertyTranslatePIDToProcessObject`, `kAudioProcessPropertyIsRunningOutput`, `kAudioProcessPropertyIsRunningInput`; CoreGraphics `CGGetEventTapList` (`CGEventTapInformation.tappingProcess`); IOKit `IOPMCopyAssertionsByProcess`; `sysctl kern.bootsessionuuid`; HIServices `kAXEditedAttribute` ("AXEdited"). `PRIO_DARWIN_BG` hakkında `setpriority(2)` man sayfası şunu söylüyor: "disk IO is throttled … network IO is throttled for any sockets opened after going into background state".

## Karar

### 1. Değişmezler (her biri T-023'te bir teste karşılık gelir)

- **D1 — Önce yaz (write-ahead):** Aynı `(pid, start)` kimliğini içeren journal kaydı yazılıp `fsync` başarıyla dönmeden hiçbir sürece SIGSTOP gönderilmez. Çözmeyi garanti eden `ohm-thawd` süreci o an canlı değilse de gönderilmez.
- **D2 — Etkiler Ohm'un ömrüyle sınırlıdır:** Ohm hangi yoldan sonlanırsa sonlansın, durdurduğu her süreç SIGCONT alır ve koyduğu her `PRIO_DARWIN_BG` politikası kaldırılır. Hiçbir etki Ohm yeniden başladıktan sonra kendiliğinden geri gelmez.
- **D3 — Kimlik:** Ohm yalnız `(pid, ri_proc_start_abstime)` kaydıyla eşleşen ve aynı önyükleme oturumunda (`kern.bootsessionuuid`) başlamış süreçlere sinyal gönderir. Kimlik, sinyalden hemen önce `proc_pid_rusage` ile yeniden okunur. Mach mutlak zamanı her önyüklemede sıfırlandığı için önyükleme oturumu kontrolü zorunludur.
- **D4 — Son anda kontrol:** Aşağıdaki "asla dondurma" kuralları, SIGSTOP'tan hemen önce, aynı `Governor` turunda kontrol edilir.
- **D5 — Aktivasyon her zaman çözer:** Donuk bir uygulama aktive edilirse çözülür. Hiçbir kural ya da ayar bunu engelleyemez.
- **D6 — Tek yazar:** Journal'a aynı anda en fazla bir süreç yazar. Bu `flock` ile zorlanır.
- **D7 — Görünürlük:** Donuk bir uygulama varken bu durum menü çubuğunda görünür. "Hepsini çöz" en fazla iki tıklama uzaklıktadır ve uygulama olmadan da çalışır (`ohm thaw --all`).
- **D8 — Kapanış sırasında dondurma yok:** Oturum kapatma, yeniden başlatma veya kapatma başladığında her şey çözülür ve yeni dondurma yapılmaz.
- **D9 — Yalnız ön planda olmayan ve gizlenmiş uygulama:** Ön plandaki uygulama (`isActive`) hiçbir yoldan dondurulamaz; buna elle dondurma da dahildir. Her `.regular` uygulama, SIGSTOP'tan önce `hide()` ile gizlenir ve `isHidden` doğrulanır. Gerekçe (T-013): Öndeki bir uygulamanın yeniden aktive edilmesi `didActivateApplicationNotification` üretmiyor. Böyle bir uygulama donarsa D5'in tetikleyicisi hiç gelmez. Gizleme ise uygulamanın çalışıyor olmasını gerektirir, bu yüzden SIGSTOP'tan sonra yapılamaz.

### 2. Kapsam ve "asla dondurma" listesi

**Kapsam kapısı.** Kurallar yalnız şu koşulların hepsini sağlayan uygulamaları dondurabilir:
- `NSRunningApplication.activationPolicy == .regular` (Dock'ta simgesi olan bir uygulama),
- Ohm ile aynı kullanıcıya ait,
- yürütülebilir dosyası `/System/`, `/usr/`, `/Library/Apple/` altında değil,
- bundle ID'si `com.apple.` ile başlamıyor. v1 için tek istisna açık bir izin listesi: `com.apple.Safari`, `com.apple.Preview`,
- Ohm'un kendisi (`dev.ohm.*`, kendi pid'leri, `ohm-thawd`, widget, CLI) değil.

Arka plan süreçleri (`.accessory` ve `.prohibited` uygulamalar, paketsiz süreçler, ör. kaçak `node`) **yalnız elle** dondurulabilir. Bunun için kaçak süreç kartında ek bir onay istenir; üst süre sınırı 30 dk'dır ve kurallarla dondurulamazlar. Aktivasyon olayları olmadığı için bu süreçler UI, CLI, süre sınırı veya Ohm'un kapanışı ile çözülür. Dondurma yalnız o pid'e uygulanır; alt süreçleri çalışmaya devam eder ve arayüz bunu söyler.

**Dinamik vetolar** (her dondurmada, uygulamanın süreç ağacındaki her pid için, D4 gereği son anda):

| Veto | Nasıl ölçülür | Karşıladığı tehdit |
|---|---|---|
| Önde (D9, kesin veto) | `NSRunningApplication.isActive` | D5: öndeki uygulamanın yeniden aktivasyonu bildirim üretmez |
| Gizlenemedi | `hide()` sonrası 1 sn içinde `isHidden` doğru olmadı veya `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` hâlâ o pid'e ait katman 0 penceresi gösteriyor | T3 (bekleme imleci), D9 |
| Yakın zamanda aktifti | Son aktivasyondan bu yana geçen süre `< minHiddenSeconds` (genel alt sınır 300 sn; kural bunu yükseltebilir, düşüremez) | Cmd-Tab ile dönüş; titreme |
| Ses çalıyor veya kaydediyor | CoreAudio: pid → process object → `IsRunningOutput` / `IsRunningInput` | T4, T6 (arama, müzik) |
| Kamera kullanımda | `kCMIODevicePropertyDeviceIsRunningSomewhere` bir kamerada doğru mu (sistem geneli; süreç başına genel API yok) | T6. Kamera açıkken kurallar hiçbir şeyi dondurmaz. |
| Güç iddiası tutuyor | `IOPMCopyAssertionsByProcess`: uyku veya ekran uykusunu engelleyen herhangi bir iddia | T6 (indirme, video, yedekleme, derleme) |
| Event tap sahibi | `CGGetEventTapList` → `tappingProcess` ağaçta mı | T4 (sistem genelinde girdi takılması) |
| Paket dışı alt süreç var | Ağaçtaki bir pid'in, yürütülebilir dosyası paketin dışında olan canlı bir alt süreci var mı (terminaller, derleme çalıştıran IDE'ler, SSH) | T6 |
| Hata ayıklanıyor | `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_flags & P_TRACED` | Debugger oturumu |
| Kullanıcının listesi | Ayarlar'daki "asla dondurma" listesi | Kullanıcı tercihi |
| Genel durum | Kapanış süreci başladı (D8); uyanmadan sonraki 2 dk; `ohm-thawd` canlı değil (D1); journal yazılamıyor | T1, T2 |
| Kaydedilmemiş belge (isteğe bağlı) | Yalnız kullanıcı Erişilebilirlik iznini zaten vermişse: pencerelerin `AXEdited` özniteliği | T1, T3 |

**Kaydedilmemiş belge sezgisi v1'de zorunlu değil. Gerekçe:**
- SIGSTOP belleği silmez. Veri kaybı yalnız T1–T3 yoluyla olur ve bu yollar D1, D2, D7 ve D8 ile doğrudan kapatılıyor.
- Erişilebilirlik izni çok güçlü bir izin. Bir enerji aracının bu izni bu sezgi için istemesi kullanıcı güvenini zedeler.
- `AXEdited`'in AppKit'in `isDocumentEdited` durumunu yansıtıp yansıtmadığı doğrulanmadı.

Bu nedenle sezgi, izin zaten verilmişse ve T-023'te doğrulanırsa ek bir veto olarak kullanılır. İzin sırf bunun için istenmez.

**Kural kaydı sırasında** kapsam kapısının statik kısmı (bundle ID, yol, `com.apple.` kuralı, kullanıcı listesi) kontrol edilir (ADR 0003). Böylece hiçbir zaman dondurulamayacak bir hedef kurala hiç yazılamaz.

### 3. Süreç ağacı ve sıra

- **Ağaç** = kök pid (`NSRunningApplication.processIdentifier`) + sorumlu pid'i kök olan **ve** yürütülebilir dosyası uygulama paketinin içinde bulunan süreçler (ADR 0002'deki atıf kuralı). Paket dışı XPC servislerine (ör. `com.apple.WebKit.WebContent`) dokunulmaz, çünkü başka istemcilerle paylaşılıyor olabilirler.
- **Dondurma sırası: önce kök, sonra helper'lar.** Donma bekçisi (hang watchdog) çok süreçli uygulamalarda ana süreçtedir. Önce ana süreç durursa bekçi de durur ve helper'ları "yanıt vermiyor" diye sonlandıramaz (T5). Kök durduktan sonra yeni helper başlatılamaz. Bu yüzden helper listesi kök durduktan **sonra** çıkarılır ve yarış penceresi kapanır.
- **Çözme sırası: önce helper'lar, sonra kök.** Kök uyandığında bekçisi uzun bir sessizlik görür. Bu anda helper'lar zaten çalışıyor ve yanıt verebiliyor olur.

### 4. Dondurma ve çözme prosedürü (`Governor`, tek actor turu içinde)

```
freeze(app):
  pre: owner.lock bu süreçte tutuluyor; thawdAlive(); ¬powerOffInProgress; ¬postWakeQuiet
  guard ¬app.isActive else return .vetoed(.frontmost)                 // D9
  root ← identity(app.processIdentifier)
  tree ← enumerateTree(root)                          // vetolar için ön görüntü
  if let v = SafetyPolicy.vetoes(app, tree): return .vetoed(v)
  app.hide(); await isHidden ∧ ¬onScreenWindows(≤1 sn) else return .vetoed(.notHidden)   // D9: her zaman, SIGSTOP'tan önce
  guard ¬app.isActive else return .vetoed(.frontmost) // gizleme sırasında öne gelmiş olabilir
  g ← UUID()
  journal.append(freeze, g, [root]); fsync            // D1: başarısızsa → .failed, sinyal yok
  sigtable.add(root.pid)                              // C tarafı, async-signal-safe tablo
  guard identity(root.pid) == root else abort(g)      // D3
  kill(root.pid, SIGSTOP)
  helpers ← enumerateTree(root) − root                // kök durdu, yeni spawn yok
  journal.append(freeze, g, helpers); fsync
  for h in helpers: sigtable.add(h.pid); if identity(h.pid) == h { kill(h.pid, SIGSTOP) }
  verify: 100 ms içinde bütün pid'ler pbi_status == SSTOP; değilse thaw(g, .verifyFailed)

thaw(g, reason):
  for h in helpers(g).reversed(): if identity(h.pid) == h { kill(h.pid, SIGCONT) }
  if identity(root.pid) == root { kill(root.pid, SIGCONT) }
  sigtable.remove(g)
  journal.append(thaw, g, reason)                     // fsync gerekmez: kayıp olursa kurtarma SIGCONT'u tekrarlar, kimlik doğrulandığı için zararsız
```

- Donuk bir kök süreç dışarıdan sonlanırsa (Zorla Çık, çökme; `didTerminateApplicationNotification` veya kökte kqueue `NOTE_EXIT`), **helper'ları hemen çözülür.** Aksi halde yetim kalan durdurulmuş helper'lar sonsuza dek `T` durumunda kalır.
- Aynı şekilde, sonlanan bir helper grubundan düşülür.

### 5. Journal

**Konum:** `~/Library/Application Support/Ohm/Freeze/` (dizin izni `0700`). App Group kapsayıcısı kullanılmaz: bu dosyayı sandbox'lı hiçbir bileşen okumuyor. Böylece kritik yol, grup kapsayıcısının TCC davranışından (ADR 0001 § Riskler) etkilenmez.

| Dosya | Amaç |
|---|---|
| `journal.jsonl` | Yalnız sona ekleme yapılan kayıt |
| `owner.lock` | Journal'ın tek yazarı. Ohm yaşadığı sürece `LOCK_EX` tutar. |
| `thawd.lock` | `ohm-thawd` yaşadığı sürece `LOCK_EX` tutar. Ohm bunu canlılık yoklaması için kullanır. |

**Biçim:** JSON Lines, UTF-8, satır başına bir kayıt, her satır `\n` ile biter. Örnekteki `…` işaretleri yalnız kısaltmadır; gerçek kayıtta tam UUID bulunur.

```json
{"v":1,"seq":1,"ts":1790000000000,"op":"open","boot":"806C0BEF-A3DE-4482-BFAA-3DC5DC943BAA","owner":{"pid":812,"start":1140100000000}}
{"v":1,"seq":2,"ts":1790000061000,"op":"freeze","group":"0B1E…","app":"com.tinyspeck.slackmacgap","origin":"rule:8C0D5B2A-…","pids":[{"pid":1402,"start":1140144980638,"role":"root"}]}
{"v":1,"seq":3,"ts":1790000061004,"op":"freeze","group":"0B1E…","app":"com.tinyspeck.slackmacgap","origin":"rule:8C0D5B2A-…","pids":[{"pid":1408,"start":1140145012201,"role":"helper"}]}
{"v":1,"seq":4,"ts":1790000065000,"op":"ecore","group":"77AF…","app":"com.google.Chrome","origin":"manual","pids":[{"pid":990,"start":1139980000001,"role":"root"}]}
{"v":1,"seq":5,"ts":1790000400000,"op":"thaw","group":"0B1E…","reason":"activation"}
{"v":1,"seq":6,"ts":1790000500000,"op":"ecoreOff","group":"77AF…","reason":"ruleEnded"}
```

- `op` değerleri: `open` | `freeze` | `thaw` | `ecore` | `ecoreOff` | `recovered`. `reason` değerleri: `activation` | `ruleEnded` | `user` | `maxDuration` | `quit` | `powerOff` | `terminated` | `verifyFailed` | `recovery`.
- `start`, `ri_proc_start_abstime` değeridir (mach mutlak zamanı; yalnız `boot` ile aynı önyükleme oturumunda anlamlı).
- **E-core durumu yalnız bu journal'da ve `ECoreLane`'in bellekteki kaydında yaşar.** T-012, `getpriority`'nin BG politikasını yansıtmadığını gösterdi. Bu yüzden `ecore` kaydı, SIGSTOP'taki gibi, `setpriority` çağrısından **önce** yazılır ve `fsync` edilir. Böylece çökmeden sonra hangi süreçlerin geri alınacağı her zaman bilinir. Ohm, başka bir aracın koyduğu BG politikasını ayırt edemez (ADR 0003 § 2).

**Yazma:**
- Dosya `open(O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600)` ile açılır.
- Her kayıt tek bir `write()` çağrısıyla yazılır; kayıtlar 4 KB'ın altındadır. `freeze` ve `ecore` kayıtlarından sonra `fsync()` çağrılır.
- **`F_FULLFSYNC` kullanılmaz.** Tehdit modeli süreç ölümüdür, güç kaybı değil. Sürecin ölümünde çekirdeğin sayfa önbelleği korunur. Güç kaybında veya kernel panic'te bütün süreçler zaten ölür ve SIGSTOP durumu önyüklemeden sonra var olmaz; eski journal önyükleme oturumu kontrolüyle (D3) atılır. `fsync` yine de çağrılır, çünkü `EIO` ve `ENOSPC` gibi hataları SIGSTOP'tan **önce** yüzeye çıkarır.
- `write` veya `fsync` başarısız olursa dondurma iptal edilir, sinyal gönderilmez ve dondurma özelliği "journal yazılamıyor" gerekçesiyle devre dışı kalır.

**Okuma ve kurtarma (`JournalRecovery`, Ohm, `ohm-thawd` ve CLI aynı kodu kullanır):**
1. Çağıran `owner.lock` kilidini tutmalıdır.
2. `open` kaydındaki `boot`, şu anki `kern.bootsessionuuid` ile uyuşmuyorsa dosya hiçbir sinyal gönderilmeden sıfırlanır.
3. Kayıtlar sırayla okunur. Sonu `\n` ile bitmeyen veya ayrıştırılamayan **son** satır yok sayılır. Bu satır, yazarın `write` sırasında öldüğünü gösterir; D1 gereği o kayda ait SIGSTOP henüz gönderilmemiştir.
4. Ortadaki bir satır ayrıştırılamıyorsa journal bozuk kabul edilir. Muhafazakâr yol izlenir: ayrıştırılabilen **bütün** `freeze` ve `ecore` kayıtları, sonlarında `thaw` olsa bile geri alınır. Kimliği doğrulanmış bir sürece SIGCONT göndermek zararsızdır.
5. Açık kalan her `freeze` grubu için: önce helper'lar, sonra kök; kimlik doğrulandıktan sonra `SIGCONT`. Açık kalan her `ecore` grubu için: kimlik doğrulandıktan sonra `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`.
6. `recovered` kaydı yazılır (kaç süreç, hangi uygulamalar). Ohm bir sonraki açılışında bunu kullanıcıya gösterir.
7. **Sıkıştırma:** Açık grup yoksa dosya `ftruncate` ile sıfırlanır ve yeni bir `open` kaydı yazılır. Açık grup varsa `journal.jsonl.tmp` yazılır, `fsync` yapılır ve `rename` ile yerine konur. `ohm-thawd` dosyayı değil dizini izlediği için `rename` güvenlidir.

**Journal kaybolursa ikinci ağ:** Ohm açılışında, aynı kullanıcıya ait `.regular` uygulamaları `pbi_status == SSTOP` durumu için tarar. Journal'da olmayan donuk bir uygulama bulursa **kendiliğinden çözmez**, çünkü onu başka bir araç (ör. App Tamer) durdurmuş olabilir. Bunun yerine "Donuk görünen uygulamalar var: [Çöz]" bildirimi gösterir.

### 6. Çökme kurtarma: ayrı izleyici **ve** sonraki açılışta kurtarma (ikisi birden)

**Karar:** İki mekanizma birlikte kullanılır; ikisi de zorunludur.
1. **İzleyici:** `ohm-thawd` adlı küçük bir süreç, Ohm'dan bağımsız yaşar ve Ohm hangi yolla ölürse ölsün journal'daki her şeyi çözer. T-013 bu modeli ölçtü: ajan `kill -9` ile öldürüldükten 36–39 ms sonra çözdü.
2. **Sonraki açılışta kurtarma:** Ohm (ve `ohm thaw --all`) her açılışta aynı `JournalRecovery` kodunu çalıştırır. Bu mekanizma, izleyici de ölmüşse veya hiç çalışmıyorsa devreye girer. T-013'te ikisi birlikte öldürüldüğünde süreç `T` durumunda kaldı ve bu yolla çözüldü.

**İzleyicinin biçimi:** İzleyici `SMAppService.agent(plistName: "dev.ohm.thawd.plist")` ile launchd'ye kaydedilen bir LaunchAgent'tır. Plist `Ohm.app/Contents/Library/LaunchAgents/` altındadır ve şu ayarları taşır: `BundleProgram = Contents/MacOS/ohm-thawd`, `KeepAlive = true`, `RunAtLoad = true`. `ProcessType` varsayılan (Standard) bırakılır; `Background` seçilmez, çünkü çözme gecikmesini artırabilir.

**Bu biçim henüz doğrulanmadı.** T-013 ayrı bir süreç kullandı, `SMAppService` kaydını değil. Kaydın geliştirme imzasıyla (Apple Development) ve Developer ID ile macOS 26/27'de çalıştığı, `KeepAlive` ile izleyicinin yeniden başladığı T-023'ün kabul testidir (§ 10, test 13). Test geçmezse Alternatif B'ye düşülür: izleyiciyi Ohm kendisi `posix_spawn` ile başlatır, izleyici aynı kilit protokolünü kullanır ve sonraki açılışta kurtarma aynen kalır. Bu durumda "ikisi birden öldü" senaryosu yalnız sonraki açılış ve CLI ile karşılanır ve README'de açıkça yazılır.

**Gerekçe:**
- Faz 2 kapısı "Ohm'u zorla öldürme testinde (`kill -9`) dondurulmuş uygulama kalmaz" diyor. Yalnız sonraki açılışta kurtarma bu kapıyı **geçemez**: kullanıcı Ohm'u yeniden açmazsa uygulamalar donuk kalır ve T1 gerçekleşir.
- `SIGKILL` ve jetsam hiçbir süreç içi işleyiciye fırsat vermez. Bu yüzden çözme garantisi Ohm'dan bağımsız yaşayan bir süreçte olmalı.
- launchd gözetimi (`KeepAlive`), izleyicinin kendisi ölse bile yeniden başlatılmasını sağlar. Ohm'un kendi başlattığı bir alt süreçte (bkz. Alternatif B) bu yoktur.

**Kilit protokolü (yarışsız, sıfır CPU):**

```
ohm-thawd:
  flock(thawd.lock, LOCK_EX)                 // yaşam boyu; canlılık sinyali
  loop:
    bekle: journal'da açık freeze/ecore grubu olana kadar   // dizinde DispatchSource vnode; başlangıçta da bir kez kontrol
    flock(owner.lock, LOCK_EX)               // Ohm yaşarken BLOKLU bekler; Ohm hangi yolla ölürse ölsün çekirdek kilidi bırakır
    JournalRecovery.run()                    // § 5
    flock(owner.lock, LOCK_UN)

Ohm açılışı:
  owner.lock ← flock(LOCK_EX | LOCK_NB), 5 sn boyunca yeniden dene    // izleyici o an kurtarma yapıyor olabilir
  başarısız → başka bir Ohm çalışıyor: onu aktive et ve çık
  JournalRecovery.run()                      // üçüncü katman: kalıntı varsa temizle
  journal.append(open)

Ohm, her freeze öncesi:
  flock(thawd.lock, LOCK_SH | LOCK_NB) başarılı olursa → izleyici YOK → kilidi bırak, dondurmayı reddet (D1)
```

- **`O_CLOEXEC` zorunludur.** Kilit dosyaları `O_CLOEXEC` ile açılır. Ohm'un başlattığı herhangi bir alt süreç (Sparkle yükleyicisi, `open`) kilit tanımlayıcısını miras alırsa, Ohm öldükten sonra kilit bırakılmaz ve izleyici hiç uyanmaz. Ohm `fork()`'u exec'siz kullanmaz.
- **Sonuç:** `kill -9` sonrasında çözme gecikmesi ≈ çekirdeğin kilidi bırakması + journal okuma + `kill` çağrıları. Hedef <1 sn. T-013'te `kqueue NOTE_EXIT` kullanan izleyici 36–39 ms ölçtü. `flock` protokolü de aynı mertebede olmalı; T-023 bunu ölçer.
- **Neden `NOTE_EXIT` değil `flock`:** Spike'taki izleyici Ohm'un pid'ini `NOTE_EXIT` ile izledi. Üretimde `flock` seçildi, çünkü izleyicinin Ohm'un pid'ini öğrenmesi ve Ohm'dan önce başlaması arasında yarış yok. Pid yeniden kullanımı da sorun değil: kilidi çekirdek, süreç öldüğünde bırakır. Tek Ohm örneği garantisi de aynı kilitten gelir.

**Kayıt ve kullanıcı deneyimi:**
- İzleyici kurulumda değil, dondurma ilk kez etkinleştirildiğinde kaydedilir. Öncesinde bir açıklama ekranı gösterilir: "Dondurma, Ohm beklenmedik şekilde kapansa bile uygulamalarının donuk kalmaması için küçük bir yardımcı süreç kullanır. Giriş Öğeleri'nde 'Ohm' olarak görünür."
- `SMAppService.status != .enabled` ise (kullanıcı Giriş Öğeleri'nde kapattı veya onay bekleniyor) **dondurma kapalıdır.** Ayarlar'da `SMAppService.openSystemSettingsLoginItems()` düğmesi gösterilir. E-core ve ölçüm bundan etkilenmez.
- Dondurma özelliği kapatılır ve journal boşsa `unregister()` çağrılır. Homebrew cask'ın `uninstall` bölümü `launchctl bootout gui/$UID/dev.ohm.thawd` içerir.
- İzleyicinin bütçesi: ≤4 MB bellek, boşta 0 CPU (`flock` veya vnode beklemesinde bloklu). ADR 0001'deki bütçe tablosunda ayrı bir satırdır.

### 7. Katmanlı çözme: bütün tetikleyiciler

| Olay | Kaynak | Eylem | Hedef |
|---|---|---|---|
| Donuk uygulama aktive edildi (Dock, Cmd-Tab, `open`) | `NSWorkspace.didActivateApplicationNotification` | `thaw(.activation)`; `refreezeGrace` (10 dk gizli kalma) başlar | <300 ms; `open -a` ile ölçülen 17–18 ms (T-013). Dock ve Cmd-Tab: T-023'te elle. |
| Kural bitti | `Governor.reconcile` | `thaw(.ruleEnded)` | <1 sn |
| Kullanıcı "Çöz" / "Hepsini çöz" | UI, CLI soketi, App Intent | `thaw(.user)` | Anında |
| Süre sınırı | `Governor` zamanlayıcısı: `.regular` için `maxFrozenDuration` varsayılan 2 sa, elle dondurulan arka plan süreci için 30 dk | `thaw(.maxDuration)`; kural ancak `refreezeGrace` sonrası yeniden dondurabilir | T8'i sınırlar |
| Donuk kök süreç sonlandı | `didTerminateApplicationNotification`, kqueue `NOTE_EXIT` | Helper'ları çöz, grubu kapat | Anında |
| Ohm'un düzenli kapanışı, Sparkle güncellemesi | `applicationShouldTerminate` → `thawAll(.quit)` ve `ecoreOff`, ardından `.terminateNow` | Eşzamanlı, ≤2 sn | D2 |
| `SIGTERM`, `SIGINT`, `SIGHUP`, `SIGQUIT`; çökme sinyalleri (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGABRT`, `SIGFPE`) | `COhmSys` içindeki C `sigaction` işleyicisi | `_Atomic int32_t` tablosundaki (256 giriş) her pid'e `kill(pid, SIGCONT)`, sonra varsayılan eylemle sinyali yeniden yükselt | Birinci katman, en iyi çaba |
| `SIGKILL`, jetsam, işleyicinin çalışamadığı çökme | `ohm-thawd` (`owner.lock` bırakıldı) | `JournalRecovery` | İkinci katman, <1 sn |
| İzleyici de yok | Bir sonraki Ohm açılışı; `ohm thaw --all` (CLI kilidi kendisi alır) | `JournalRecovery` | Üçüncü katman |
| Oturum kapatma, yeniden başlatma, kapatma | `NSWorkspace.willPowerOffNotification` | `thawAll(.powerOff)`; yeni dondurma yok. İşlem iptal edilirse (Ohm 5 dk içinde sonlanmazsa) dondurma yeniden açılır. | D8 |
| Uyku | `willSleepNotification` | **Çözme yok** (gerekçe aşağıda) | – |
| Uyanma | `didWakeNotification` | Kimlikleri yeniden doğrula, ölen süreçleri düş; 2 dk yeni dondurma yok; süre sınırı duvar saatine göre işler, sınırı aşanlar çözülür | – |
| Hızlı kullanıcı değiştirme | `sessionDidResignActive` | İşlem yok. Oturum kapanırsa `willPowerOff` yolu çalışır. | – |

**Sinyal işleyicisi notları:**
- `kill()` POSIX'e göre async-signal-safe'tir.
- `proc_pidinfo` bu listede olmadığı için işleyici kimlik doğrulaması yapamaz. Tablodan ölen süreçler `didTerminate` ile hemen çıkarıldığı için yanlış pid riski dar bir pencereyle sınırlıdır. Kalan riskin sonucu, ilgisiz bir sürecin SIGCONT alması; bu çoğunlukla etkisizdir.
- Tablo dolarsa (256 pid) yeni dondurma reddedilir.
- İşleyici Swift'te değil C'de yazılır ve başka işleyicileri zincirler.

**Uykuda neden çözülmez:**
- Uykudan önce her donuk uygulamayı çözmek, uyku anında N uygulamayı birden uyandırır ve uykuyu geciktirir. Uyanınca da yeniden dondurmak gerekir ve bu, riskli pencereyi günde birkaç kez yeniden açar.
- Donuk bir uygulama dondurulduğundan beri yeni kaydedilmemiş durum üretemez. Uykuda ve hazırda beklemede (hibernation) bellek içeriği korunur.
- Uykuyu atlatamayan tek senaryo, pilin bitip hazırda bekleme görüntüsünün olmaması. Bu senaryoda donuk olsun olmasın bütün uygulamalar kaybedilir. Dondurma bu riski büyütmez.
- Bilinen yan etki: Donuk uygulamalar `willSleep` ve `didWake` bildirimlerini gerçek zamanında işleyemez. Çözüldüklerinde ağ bağlantılarını yeniden kurmaları gerekebilir. Bu, uzun bir uykudan dönen uygulamanın durumuyla aynıdır.

### 8. E-core politikasının geri alınması

- `PRIO_DARWIN_BG` sürecin kendi özelliğidir ve Ohm'dan bağımsız yaşar. Ohm ölürse politika uygulama kapanana kadar kalır. Bu veri kaybı değil ama D2'ye aykırı ve görünmez bir yavaşlık yaratır. Bu yüzden E-core da journal'a yazılır (`ecore` ve `ecoreOff`) ve çözmeyle aynı katmanlarla geri alınır: düzenli kapanış, sinyal işleyicisi (yalnız dondurma tablosu; E-core işleyicide geri alınmaz), izleyici ve sonraki açılış.
- E-core uygulamanın bütün ağacına uygulanır. İşi yapan çoğunlukla helper süreçlerdir (Chrome renderer'ları). Sonradan başlayan helper'lar `ambient` tick'lerinde (10 sn) yakalanır ve politikaya eklenir.
- **Geri alma:** `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`, yalnız Ohm'un journal'ına yazılmış ve kimliği doğrulanan pid'lere uygulanır. T-012 bunun hedef dışındaki bir süreçten çalıştığını gösterdi (P payı 0,00'dan 1,00'a döndü).
- **Durum doğrulaması:** `getpriority` BG durumunu yansıtmadığı için (T-012), politikanın gerçekten uygulandığı `ri_penergy_nj / ri_energy_nj` oranıyla doğrulanır. Yük altında bu oran birkaç tick içinde ~0'a inmelidir. Boştaki bir süreçte oran anlamsızdır; bu durumda doğrulama atlanır ve arayüz yalnız "uygulandı" der.
- **Yan etki (man sayfasından):** Politika disk G/Ç'sini kısar, arka plan durumundayken açılan soketlerin ağ G/Ç'sini de kısar. Politika kaldırıldığında bu soketlerin kısıtının kalkıp kalkmadığı Faz 0'da ölçülmedi. Açık kalan bir risk olarak arayüz "E-core'dan çıkarıldı; yeni bağlantılar normal hızda" notunu gösterir.

### 9. Kullanıcıya görünen durum

- **Menü çubuğu:** En az bir uygulama donuksa halkanın köşesinde ❄ ve sayı görünür.
- **Popover'da "Donuk" bölümü:** Uygulama, ne zamandan beri donuk olduğu, kaynağı (kural adı veya "elle") ve [Çöz] düğmesi. Sayı 0'dan büyükse "Hepsini çöz" her zaman görünür.
- **Ayarlar:**
  - "Dondurma koruması: Etkin (yardımcı süreç çalışıyor)" ya da kırmızı "Kapalı: [Giriş Öğelerini aç]".
  - "Asla dondurma" listesi ve her girdinin gerekçesi.
  - Genel süre sınırları.
- **Kural durumu:** Vetolar bildirimle değil, kural satırında gerekçesiyle gösterilir ("veto: ses çalıyor").
- **İlk dondurma:** Her kuralın ilk dondurmasında tek seferlik bir bildirim gösterilir. Onboarding metni T3'ü açıkça anlatır: "Donuk uygulamalar Zorla Çık penceresinde 'yanıt vermiyor' görünür. Zorla kapatmak kaydedilmemiş verini siler; önce uygulamaya tıkla, çözülsün."
- **Kurtarma sonrası:** "Ohm beklenmedik şekilde kapandı; 3 uygulama çözüldü." Bu mesaj `recovered` kaydından, bir sonraki açılışta gösterilir.
- **CLI:** `ohm status` donuk ve E-core'daki süreçleri listeler. `ohm thaw --all` uygulama olmadan da çalışır.
- **README'deki "Acil durum" bölümü:** Önce `ohm thaw --all`. CLI yoksa `ps -axo pid,stat,comm | awk '$2 ~ /T/'` ile donuk süreçler bulunur ve `kill -CONT <pid>` ile çözülür.

### 10. T-023 kabul testleri (kapı)

1. Bir uygulama donukken Ohm'a `kill -9` gönderilir. 1 sn içinde `ps -o stat= -p <pid>` sonucunda `T` görünmez.
2. Ohm ve `ohm-thawd` birlikte `kill -9` ile öldürülür. launchd izleyiciyi yeniden başlatır ve çözer. İzleyici devre dışıysa `ohm thaw --all` ve bir sonraki açılış çözer.
3. Test kancasıyla `SIGSEGV` tetiklenir. Sinyal işleyicisi çözer.
4. Journal'ın son satırı yarıda kesilir. Kurtarma o satırı yok sayar, diğerlerini çözer.
5. Farklı bir `boot` UUID'si taşıyan journal hiçbir sinyal göndermeden atılır.
6. pid'i eşleşen ama başlangıç zamanı farklı bir kayıt için sinyal gönderilmez.
7. Helper'lı bir test uygulamasında sıra doğrulanır: kök önce durur, helper önce uyanır.
8. `willPowerOff` sahte olarak gönderilir. Her şey çözülür ve dondurma reddedilir.
9. Her veto için bir test uygulaması: ses çalan, güç iddiası tutan, event tap kuran, paket dışı alt süreç (`sleep 1000`) başlatan. Dördü de dondurulmaz.
10. Donuk kök süreç dışarıdan öldürülür. Helper'ları `T` durumunda kalmaz.
11. Journal dizini salt okunur yapılır. Dondurma reddedilir ve hiçbir süreç SIGSTOP almaz.
12. `thawd.lock` tutulmuyorken (izleyici yok) dondurma reddedilir.
13. **`SMAppService` izleyicisi:** Uygulama Developer ID ile imzalıyken (Faz 4 öncesi geliştirme imzasıyla da) `register()` sonrasında `status == .enabled` olur. `ohm-thawd` `kill -9` ile öldürülünce launchd onu yeniden başlatır ve yeniden başlayan izleyici test 1'i geçer. Başarısızsa § 6'daki Alternatif B uygulanır.
14. **Elle (otomasyonla yapılamaz):** Donuk uygulama Dock simgesine tıklanarak ve Cmd-Tab ile seçilerek aktive edilir. Her iki yolda da uygulama 300 ms içinde yanıt verir.
15. Ön plandaki bir uygulamayı elle veya kuralla dondurma girişimi `.frontmost` ile reddedilir ve SIGSTOP gönderilmez (D9).
16. E-core uygulanmış bir test sürecinde Ohm `kill -9` ile öldürülür. İzleyici politikayı kaldırır; kanıt olarak yük altındaki sürecin `P_share` değeri 1,00'a döner.

Kural (T-013 kartıyla aynı): Testler yalnız testin kendi başlattığı süreçlere sinyal gönderir.

## Alternatifler

- **A. Yalnız bir sonraki açılışta kurtarma.** Tek başına reddedildi. `kill -9` kapısını geçemez; kullanıcı Ohm'u yeniden açmazsa uygulamalar süresiz donuk kalır ve bu T1'in kendisidir. İzleyiciyle birlikte ikinci katman olarak kullanılır (§ 6).
- **A2. Yalnız izleyici (sonraki açılışta kurtarma olmadan).** Reddedildi. T-013, izleyici de ölürse sürecin `T` durumunda kaldığını gösterdi. O senaryoyu yalnız açılışta kurtarma kapatır.
- **B. Ohm'un `posix_spawn` ile başlattığı bir alt izleyici (kqueue `NOTE_EXIT` ile ebeveyni izler).** Birincil yol olarak reddedildi. Onu yeniden başlatan kimse yok. `pkill -9 -f Ohm` gibi desenlerle ya da süreç grubu sinyalleriyle Ohm'la birlikte ölebilir. Artısı Giriş Öğeleri'nde görünmemesi. **T-023'ün 13 numaralı testi `SMAppService.agent` yolunu doğrulayamazsa yedek budur** (§ 6).
- **C. Root yetkili helper veya daemon.** Reddedildi. Aynı kullanıcının süreçlerine sinyal göndermek root gerektirmiyor. Daemon onayı daha ağır ve saldırı yüzeyi gereksiz büyür.
- **D. SIGSTOP yerine `task_suspend`.** Reddedildi. `task_for_pid` entitlement veya root ister. Ayrıca SIGSTOP durumu `ps` ile görünür ve dışarıdan `kill -CONT` ile düzeltilebilir. Bu, acil çıkış yolunun temelidir.
- **E. Uykudan önce hepsini çözmek.** Reddedildi (§ 7'deki gerekçe).
- **F. Kaydedilmemiş belge sezgisini zorunlu kılmak (Erişilebilirlik izni).** Reddedildi (§ 2'deki gerekçe). İzin varsa ek veto olarak kullanılır.
- **G. Dondurmayı hiç sunmamak, yalnız E-core.** Değerlendirildi. Ürün vaadinin bir parçası olduğu için reddedildi. T-013 aktivasyonda çözmeyi doğruladı. T-023'teki Dock ve Cmd-Tab testi (test 14) kalırsa dondurma elle yapılan ve süre sınırlı bir işleme indirilir; bu, G'ye yakın bir sonuçtur.
- **H. Journal'ı App Group kapsayıcısında tutmak.** Reddedildi. Okuyan sandbox'lı bir bileşen yok. Kritik yolun grup kapsayıcısı TCC davranışına bağımlı olması gereksiz risk.

## Sonuçlar ve riskler

- **(+)** Ohm'un hangi yolla sonlandığından bağımsız olarak (düzenli kapanış, sinyal, çökme, `SIGKILL`, jetsam) çözme garanti eden bağımsız bir süreç vardır. İzleyici de yoksa dondurma hiç yapılmaz.
- **(+)** Acil çıkış yolu (`ohm thaw --all`, `kill -CONT`) hiçbir Ohm sürecine bağımlı değildir.
- **(−)** Giriş Öğeleri'nde görünen ikinci bir süreç ve dondurmayı açmak için tek seferlik bir açıklama ekranı gerekir.
- **Kalan risk R2 (T8):** Donuk uygulamanın takvim alarmları ve mesajları gecikir. Süre sınırı (2 sa) bunu sınırlar. Kullanıcı takvim uygulamasını "asla dondurma" listesine ekleyebilir. Varsayılan listeye Calendar zaten `com.apple.` kuralıyla giriyor.
- **Kalan risk R3 (T6):** Güç iddiası tutmadan indirme veya yükleme yapan uygulamalarda aktarım yarıda kalabilir. Bu genellikle kurtarılabilir bir hatadır ama arayüz, dondurma açıklamasında bunu söyler.
- **Kalan risk R4:** Çok süreçli uygulamalar, çözüldükten sonra saat sıçramasını görüp kendi bekçileriyle helper'ları yeniden başlatabilir (Electron'da sayfanın yeniden yüklenmesi gibi). Çözme sırası (§ 3) bu riski azaltır, sıfırlamaz. Faz 0 yalnız tek süreçli TextEdit'i ölçtü. T-023, testin kendi açtığı helper'lı bir uygulamayla (ör. geçici profilli yeni bir Chrome örneği) sırayı ve çözme sonrası sekme sağlığını ölçer.
- **Kalan risk R5:** `SMAppService` ve Background Task Management davranışı macOS sürümleriyle değişebilir. Her büyük macOS sürümünde 1, 2 ve 13 numaralı testler yeniden çalıştırılır.

### Kabul edilen risk: Zorla Çık (T3)

**Risk:** Donuk bir uygulama, Zorla Çık penceresinde (Cmd-Option-Esc) "Yanıt Vermiyor" olarak görünür. Kullanıcı durumu uygulamanın kilitlendiği şeklinde yorumlayıp zorla kapatırsa uygulamanın kaydedilmemiş verisi kaybolur. Zorla kapatma `SIGKILL` gönderir; `SIGKILL` donuk süreçlerde de çalışır. Ohm bunu engelleyemez. Zorla Çık penceresinin açıldığını ucuza ve güvenilir biçimde algılamanın doğrulanmış bir yolu da yok.

**Neden kabul edildi:** Riski sıfırlamanın tek yolu dondurmayı hiç sunmamak (Alternatif G). Dondurma ürün vaadinin parçası. Aşağıdaki azaltmalarla, riskin gerçekleşmesi için kullanıcının donuk olduğunu gösteren göstergeyi görmezden gelip zorla kapatmayı seçmesi gerekir.

**Azaltmalar (hepsi zorunlu):**
1. **Görünürlük (D7):** Menü çubuğunda ❄ ve donuk sayısı; popover'da "Donuk" bölümü ve her zaman görünür "Hepsini çöz" düğmesi.
2. **Onboarding metni:** Dondurma ilk kez açıldığında şu metin gösterilir: "Donuk uygulamalar Zorla Çık penceresinde 'yanıt vermiyor' görünür. Zorla kapatmak kaydedilmemiş verini siler; önce uygulamaya tıkla, çözülsün."
3. **Gizleme (D9):** Donuk uygulama ekranda görünmez, bu yüzden bekleme imleci (beachball) çıkmaz. Kullanıcıyı Zorla Çık'a iten en yaygın tetikleyici bu imleçtir.
4. **Süre sınırı:** `maxFrozenDuration` (2 sa; elle dondurulan arka plan süreçleri için 30 dk) donuk kalma süresini sınırlar.
5. **Aktivasyonda çözme (D5):** Uygulamaya tıklamak, kullanıcının zaten ilk deneyeceği şeydir ve 17–18 ms içinde çözer.
6. **İsteğe bağlı kaydedilmemiş belge vetosu:** Kullanıcı Erişilebilirlik iznini zaten vermişse ve T-023 `AXEdited` sezgisini doğrularsa, düzenlenmiş belgesi olan uygulamalar hiç dondurulmaz (§ 2).
7. **Gözlem:** T-023 sırasında Zorla Çık penceresi açılınca bir `NSWorkspace` bildirimi gelip gelmediğine bakılır. Güvenilir bir sinyal bulunursa "Zorla Çık açılınca hepsini çöz" eklenir ve bu risk yeniden değerlendirilir.

## Spike'a bağlı (Faz 0 sonuçlarıyla çözüldü)

- **T-013 PASS (aktivasyon):** Donuk uygulama için de `didActivateApplicationNotification` geliyor; SIGCONT gecikmesi 17–18 ms. **Karar:** Kurallar `freeze` kullanabilir (ADR 0003). Öndeki uygulamanın yeniden aktivasyonu bildirim üretmediği için D9 eklendi: yalnız ön planda olmayan ve SIGSTOP'tan önce gizlenmiş uygulamalar dondurulur.
- **T-013 PASS (kurtarma):** Ayrı izleyici `kill -9` sonrasında 36–39 ms içinde çözdü. İkisi birlikte ölünce sonraki açılışta journal'dan kurtarma çözdü. **Karar:** İzleyici ve sonraki açılışta kurtarma birlikte kullanılır (§ 6).
- **T-012 PASS:** `setpriority(…, 0)` politikayı başka bir süreçten kaldırıyor, bu yüzden D2 E-core için de tam geçerli. `getpriority` durumu yansıtmıyor. **Karar:** `ECoreLane` kendi kaydını tutar; E-core durumu `setpriority`'den önce journal'a yazılır ve izleyici ile sonraki açılış bunu geri alır (§ 5, § 8, test 16).
- **Açık kalan tek yedekli karar (T-023 test 13):** İzleyicinin `SMAppService` LaunchAgent'ı biçimi doğrulanmadı. Başarısız olursa Alternatif B (Ohm'un `posix_spawn` ile başlattığı izleyici) ve sonraki açılışta kurtarma kullanılır.
- **Açık kalan doğrulamalar (T-023):** Dock ve Cmd-Tab ile çözme (test 14, elle). Helper'lı uygulamada sıra ve sekme sağlığı (R4). Süreç ağacının sorumlu pid ve paket yolu kuralıyla doğru kurulması (Chrome, Slack, Safari); kurulmazsa `ppid` zinciri ile paket yolu birlikte kullanılır. Test 14 başarısız olursa `freeze` kurallardan kaldırılır ve dondurma yalnız elle yapılan, en fazla 30 dk süren bir işleme iner.
