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

- **D1 — Önce yaz (write-ahead):** Aynı `(pid, start)` kimliğini içeren journal kaydı yazılıp `fsync` başarıyla dönmeden hiçbir sürece SIGSTOP gönderilmez ve hiçbir `setpriority(…, PRIO_DARWIN_BG)` çağrılmaz. Koruma modu (§ 6) hazır değilse de ikisi de yapılmaz.
- **D2 — Etkiler Ohm'un ömrüyle sınırlıdır:** Ohm hangi yoldan sonlanırsa sonlansın, durdurduğu her süreç SIGCONT alır ve koyduğu her `PRIO_DARWIN_BG` politikası kaldırılır. Hiçbir etki Ohm yeniden başladıktan sonra kendiliğinden geri gelmez.
- **D3 — Kimlik:** Ohm yalnız `(pid, ri_proc_start_abstime)` kaydıyla eşleşen ve aynı önyükleme oturumunda (`kern.bootsessionuuid`) başlamış süreçlere sinyal gönderir. Kimlik, sinyalden hemen önce `proc_pid_rusage` ile yeniden okunur. Mach mutlak zamanı her önyüklemede sıfırlandığı için önyükleme oturumu kontrolü zorunludur.
- **D4 — Son anda kontrol:** Kabul edilebilirlik (§ 4: işlem kuşağı, kapanış durumu, koruma modu, istenen durum ve bütün "asla dondurma" vetoları) son askıya alma noktasından **sonra** yeniden hesaplanır. Bu kontrol ile SIGSTOP arasında hiçbir `await` bulunmaz.
- **D5 — Aktivasyon her zaman çözer:** Donuk bir uygulama aktive edilirse çözülür. Hiçbir kural ya da ayar bunu engelleyemez.
- **D6 — Tek yazar:** Journal'a aynı anda en fazla bir süreç yazar. Bu `flock` ile zorlanır.
- **D7 — Görünürlük:** Donuk bir uygulama varken bu durum menü çubuğunda görünür. "Hepsini çöz" en fazla iki tıklama uzaklıktadır ve uygulama olmadan da çalışır (`ohm thaw --all`).
- **D8 — Kapanış sırasında dondurma yok:** Oturum kapatma, yeniden başlatma veya kapatma başladığında her şey çözülür ve yeni dondurma yapılmaz.
- **D9 — Yalnız ön planda olmayan ve gizlenmiş uygulama:** Ön plandaki uygulama (`isActive`) hiçbir yoldan dondurulamaz; buna elle dondurma da dahildir. Her `.regular` uygulama, SIGSTOP'tan önce `hide()` ile gizlenir ve `isHidden` doğrulanır. Gerekçe (T-013): Öndeki bir uygulamanın yeniden aktive edilmesi `didActivateApplicationNotification` üretmiyor. Böyle bir uygulama donarsa D5'in tetikleyicisi hiç gelmez. Gizleme ise uygulamanın çalışıyor olmasını gerektirir, bu yüzden SIGSTOP'tan sonra yapılamaz. Gizleme kasıtlıdır ve kullanıcıya kural onayında söylenir (ADR 0003 § 3, madde 8). Dondurma başarısız olursa, uygulama yalnız Ohm tarafından gizlendiyse yeniden gösterilir.
- **D10 — Ya hep ya hiç (geri alma):** İlk SIGSTOP'tan sonraki herhangi bir hata (journal yazma veya `fsync` hatası, kimlik uyuşmazlığı, yeni helper'da veto, `.unstableTree`, doğrulama zaman aşımı) **bütün grubu hemen geri alır**. Bu, o ana kadar durdurulan her pid'e ters sırayla SIGCONT gönderilmesi ve en iyi çabayla bir `thaw` kaydı yazılması demektir. Yarım dondurulmuş bir grup hiçbir zaman Governor'ın kaydına geçmez. İzleyiciye bırakılmaz, çünkü Ohm yaşadığı sürece izleyici devreye girmez.

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
| Genel durum | Kapanış süreci başladı (D8); uyanmadan sonraki 2 dk; koruma modu hazır değil (D1, § 6); journal yazılamıyor | T1, T2 |
| Kararsız veya güvensiz ağaç | Sabit nokta 3 turda kurulamadı (`.unstableTree`); bundle ID `freezeUnsafe` (`.unsafeTopology`, yalnız kurallar için) | T5 (§ 3) |
| Kaydedilmemiş belge (isteğe bağlı) | Yalnız kullanıcı Erişilebilirlik iznini zaten vermişse: pencerelerin `AXEdited` özniteliği | T1, T3 |

**Kaydedilmemiş belge sezgisi v1'de zorunlu değil. Gerekçe:**
- SIGSTOP belleği silmez. Veri kaybı yalnız T1–T3 yoluyla olur ve bu yollar D1, D2, D7 ve D8 ile doğrudan kapatılıyor.
- Erişilebilirlik izni çok güçlü bir izin. Bir enerji aracının bu izni bu sezgi için istemesi kullanıcı güvenini zedeler.
- `AXEdited`'in AppKit'in `isDocumentEdited` durumunu yansıtıp yansıtmadığı doğrulanmadı.

Bu nedenle sezgi, izin zaten verilmişse ve T-023'te doğrulanırsa ek bir veto olarak kullanılır. İzin sırf bunun için istenmez.

**Kural kaydı sırasında** kapsam kapısının statik kısmı (bundle ID, yol, `com.apple.` kuralı, kullanıcı listesi) kontrol edilir (ADR 0003). Topoloji izin listesi bu statik doğrulayıcıda henüz denetlenmez; Governor çalışma anında `.unverifiedTopology` veto nedeniyle uyarı verir. Kural kaydı arayüzünün bu nedeni kullanıcıya göstermesi bağlama işidir; T-026b kapsamında `OhmRules` / `RuleValidator` değiştirilmez.

### 3. Süreç ağacı ve sıra

- **Ağaç** = kök pid (`NSRunningApplication.processIdentifier`) + sorumlu pid'i kök olan **ve** yürütülebilir dosyası uygulama paketinin içinde bulunan süreçler (ADR 0002'deki atıf kuralı). Paket dışı XPC servislerine (ör. `com.apple.WebKit.WebContent`) dokunulmaz, çünkü başka istemcilerle paylaşılıyor olabilirler.
- **Dondurma sırası: önce kök, sonra helper'lar.** Donma bekçisi (hang watchdog) çok süreçli uygulamalarda çoğunlukla ana süreçtedir. Önce ana süreç durursa bekçi de durur ve helper'ları "yanıt vermiyor" diye sonlandıramaz (T5).
- **Kökü durdurmak ağacı dondurmaz.** Hâlâ çalışan helper'lar kendi alt süreçlerini başlatabilir. Bu yüzden helper'lar **sabit noktaya kadar** durdurulur (§ 4): numaralandır, yenileri durdur, tekrarla; en fazla 3 tur. Üç turda ağaç büyümeyi bırakmazsa bütün grup geri alınır ve `.unstableTree` vetosu döner.
- **Çözme sırası: önce helper'lar, sonra kök.** Kök uyandığında bekçisi uzun bir sessizlik görür; bu anda helper'lar zaten çalışıyor ve yanıt verebiliyor olur.
- **İki yönlü bekçiler kapatılamaz, algılanır.** Helper tarafında kökü izleyen bir bekçi varsa, hangi çözme sırası seçilirse seçilsin, bekçi uyandığında son kalp atışının donmadan önce olduğunu görür. Bu yüzden her çözmeden 5 sn sonra bir **sağlık kontrolü** yapılır. Kök ya da gruptaki herhangi bir helper bu sürede sonlanmışsa uygulamanın bundle ID'si `freezeUnsafe` olarak işaretlenir (`~/Library/Application Support/Ohm/freeze-health.json`). Kurallar bu uygulamayı artık dondurmaz (`.unsafeTopology` vetosu). Elle dondurma yalnız uyarıyla mümkündür. Bu işaret muhafazakârdır: Chrome'un boştaki renderer'ı kapatması gibi olağan çıkışlar da işareti koyar; kullanıcı Ayarlar'dan işareti kaldırabilir. Çözme sırasında kimliğe bağlı `NOTE_EXIT` izlemesi sağlık penceresi bitene kadar sürer; bu penceredeki kesin çıkış `.unknown` yoklamasında da sağlık sinyalidir. `.verifyFailed` nedeniyle çözmede de pencere korunur; ölçüm hatası tek başına işaret koymaz, kesin çıkış koyar. Pencere bitince kaynak ve timer bırakılır; aynı kimliğin yeni bir dondurma/E-core grubunca kullanılan kaynağı korunur. Ohm kapanırken bekleyen sağlık kontrolleri iptal edilir.
- **Otomatik dondurma (`EffectOrigin.rule`)** yalnız doğrulanmış topoloji izin listesindeki bundle'lar için yapılır; listede olmayan veya bundle ID'si bulunmayan hedef `.unverifiedTopology` ile reddedilir. Başlangıç listesi yalnız **`com.apple.TextEdit`** içerir. Kaynak: T-013 gerçek TextEdit spike'ı, `spikes/README.md` § T-013 (ajan öldüğünde izleyiciyle ve iki süreç öldüğünde journal'la kurtarma; `main` 5773b60). Bu liste diğer kapsam kapılarını veya dinamik vetoları kaldırmaz; E-core'a uygulanmaz. Kullanıcı onaylı (`.manual`, `.cli`, `.runaway`) dondurmada topoloji izin listesi aranmaz, mevcut güvenlik vetoları ve arka plan ek onayı geçerlidir. `isAutomatic` yalnız `.rule` için doğrudur; sağlık ve kamera vetolarındaki `isRule` aynı tanımı kullanır. Varsayılan yapılandırmada doğrulanmış topoloji listesindeki uygulamalar Apple paketi olduğu için otomatik (kural) dondurma fiilen kapalıdır; liste kanıtla genişletilir.
- **Listeyi genişletme:** Yeni bundle için gerçek uygulamayla kök/helper ağacı, sabit noktaya ulaşma, helper doğması ve iki yönlü watchdog davranışı; normal çözme, ajan `kill -9`, izleyiciyle birlikte ölüm ve journal kurtarması doğrulanıp ölçüm/uygulama sürümü raporlanmalıdır. Kanıt kritik review'dan geçtikten sonra `SafetyPolicy.verifiedFreezeTopologies` güncellenir. Başka bundle'lar varsayımla eklenmez. Sağlık kontrolü (`freezeUnsafe`) ek koruma olarak kalır; izin listesi ilk denemenin riskini sınırlar.

### 4. Dondurma ve çözme prosedürü (`Governor`)

**İşlem kuşağı (generation).** `Governor` bir `generation: UInt64` sayacı tutar. Sayaç şu olaylarda artar: `willPowerOff`, uyku, uyanma, `DesiredState` değişimi, koruma modu değişimi (§ 6), `thawAll`, Ohm'un kapanışa başlaması. Her dondurma işlemi başlarken sayacı kopyalar (`op.token`). Sayaç değişmişse işlem iptal edilmiş sayılır.

**Kabul edilebilirlik (`admissible(op)`)** kontrolü her çağrıda hepsini baştan hesaplar:
- `op.token == generation`,
- `protectionReady()` (§ 6, moda göre),
- `¬powerOffInProgress ∧ ¬postWakeQuiet ∧ ¬shuttingDown`,
- istenen durum bu dondurmayı hâlâ istiyor (kaynak kural aktif ve bastırılmamış, ya da elle istek geri alınmamış),
- `¬app.isActive` ve son aktivasyondan beri geçen süre `≥ minHiddenSeconds` (birleşmiş değer, ADR 0003 § 3),
- § 2'deki **bütün** vetolar yeni bir ağaç görüntüsü üzerinde boş,
- bu uygulama için başka bir grup veya süren bir işlem yok,
- kural kaynaklıysa `¬freezeUnsafe(app)`.

```
freeze(op) async -> FreezeOutcome:
  // FAZ A — askıya alınabilir hazırlık. TEK askıya alma noktası: gizleme beklemesi.
  guard admissible(op) else return .vetoed(reasons)
  op.hiddenByOhm ← ¬app.isHidden
  if op.hiddenByOhm { app.hide() }
  await waitUntil(app.isHidden ∧ ¬onScreenWindows(app), timeout: 1 sn)
      // Bu bekleme sırasında actor yeniden girişlidir (reentrant): willPowerOff, kural silinmesi,
      // aktivasyon, izleyicinin ölümü veya thawAll işlenmiş olabilir. Bu yüzden Faz B her şeyi yeniden doğrular.

  // FAZ B — askıya almasız bölge: buradan dönüşe kadar hiçbir `await` yok.
  // Governor kendi DispatchSerialQueue yürütücüsünde çalışır (ADR 0001 § 3); bloklayan beklemeler bu kuyruktadır.
  guard admissible(op) ∧ app.isHidden ∧ ¬onScreenWindows(app) else { restoreHide(op); return .vetoed(reasons) }
  g ← UUID(); stopped ← []
  do {
    journal.append(freeze, g, [root], hiddenByOhm: op.hiddenByOhm); fsync     // D1
    stopOne(root, &stopped)            // kimliği doğrula (D3) → sigtable.add → SIGSTOP → stopped.append
    fixed ← false
    for pass in 1...3 {                // sabit nokta (§ 3)
      new ← enumerateTree(root) − stopped
      if new.isEmpty { fixed ← true; break }
      if let v = SafetyPolicy.vetoes(app, new) { throw Veto(v) }             // yeni helper ses çalıyor, tap kurmuş vb.
      journal.append(freeze, g, new); fsync
      for h in new { stopOne(h, &stopped) }
    }
    guard fixed else throw Veto(.unstableTree)
    verifyStoppedBlocking(stopped, limit: 100 ms, poll: 5 ms)   // pbi_status == SSTOP; askıya alma değil, kuyrukta bloklayan bekleme
  } catch {
    rollback(g, stopped, reason: error)                        // D10
    restoreHide(op)
    return .failed(error) / .vetoed(v)
  }
  register(g, stopped, op); scheduleMaxDuration(g)
  return .frozen(g)

rollback(g, stopped, reason):          // D10 — en iyi çaba; hiçbir adım bir öncekinin başarısına bağlı değil
  for p in stopped.reversed(): if identity(p) == p { kill(p.pid, SIGCONT) }   // son durdurulan ilk çözülür
  sigtable.remove(stopped)
  try? journal.append(thaw, g, reason: .rollback)   // yazılamazsa: kurtarma kimliği doğrulanmış SIGCONT'u tekrarlar (zararsız)
  if reason is JournalError { disableEffects(.journalUnwritable) }

restoreHide(op):
  if op.hiddenByOhm ∧ app hâlâ çalışıyor ∧ ¬app.isActive { app.unhide() }     // yalnız Ohm gizlediyse; kullanıcının gizlediğine dokunulmaz

thaw(g, reason):                        // senkron, askıya almasız
  for h in helpers(g).reversed(): if identity(h) == h { kill(h.pid, SIGCONT) }
  if identity(root) == root { kill(root.pid, SIGCONT) }
  sigtable.remove(g)
  journal.append(thaw, g, reason)       // fsync gerekmez: kayıp olursa kurtarma SIGCONT'u tekrarlar, kimlik doğrulandığı için zararsız
  scheduleHealthCheck(g, after: 5 sn)   // § 3
```

- **Askıya almasız adımlar (açıkça):** Faz B'nin tamamı; `rollback`, `restoreHide` ve `thaw`. Bunların hiçbiri `await` içermez. Tek bloklayan bekleme `verifyStoppedBlocking`'tir (en fazla 100 ms, Governor kuyruğunda) ve `fsync` çağrılarıdır. Bu sürede kuyruğa giren bir aktivasyon çözmesi en fazla bu kadar gecikir. 300 ms bütçesi korunur; T-023 bunu ölçer.
- **Başarılı dondurmadan sonra gizleme geri alınmaz.** Kural bitince veya süre dolunca yapılan çözmede uygulama gizli kalır; gösterilmesi pencereleri beklenmedik anda ekrana getirirdi. Kullanıcı uygulamaya geçince macOS onu zaten gösterir. `hiddenByOhm` bilgisi yalnız başarısız bir dondurmada geri yükleme için kullanılır ve journal kaydında tanı amacıyla tutulur.
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
- `write` veya `fsync` başarısız olursa:
  - Grubun ilk kaydında hata olursa hiçbir sinyal gönderilmez.
  - Sonraki bir kayıtta hata olursa (kök zaten durdurulmuşsa) D10 gereği bütün grup hemen geri alınır.
  - Her iki durumda da dondurma ve E-core "journal yazılamıyor" gerekçesiyle devre dışı kalır. Mevcut etkiler çözülür ve geri alınır.

**Okuma ve kurtarma (`JournalRecovery`, Ohm, `ohm-thawd` ve CLI aynı kodu kullanır):**
1. Çağıran `owner.lock` kilidini tutmalıdır.
2. Grubun `open` kaydındaki `boot` ve şu anki `kern.bootsessionuuid` **ikisi de okunabiliyor ve farklıysa** o grup hiçbir sinyal gönderilmeden bırakılır. Güncel boot geçici okunamıyorsa sinyal gönderilmez, grup özgün boot segmentiyle korunur ve yeniden denenir. Grubun boot'u hiç kayıtlı değilse (`missingRecordedBoot`) doğrulama mümkün değildir: grup tutulur, tek bildirim yazılır, otomatik yeniden deneme listesine alınmaz. Güncel güvenilir boot yokken `.bootUnverified`, çözülemeyen eski etkiler varken `.recoveryPending` vetosu yeni dondurma ve E-core uygulamasını engeller. Kullanıcının `thawAll(.user)` isteği veya CLI'nin ortak `JournalSession.thawAll` yolu doğrulanabilenleri çözer; doğrulanamayan grupları sinyal göndermeden `userForcedUnverified` nedeniyle journal'da kapatır. Bu kayıt kapatma işlemi sürecin gerçekten çözüldüğünü kanıtlamaz; pid/start/boot doğrulaması atlanmaz. CLI komutu bu ortak kurtarma yoluna bağlıdır; kilit başka süreçteyse veya geri alma tamamlanmadıysa sıfırdan farklı çıkış verir. `forcedClosedGroups` sinyal gönderildiğini kanıtlamadığından ayrıca uyarı ve başarısız çıkış üretir.
3. Kayıtlar sırayla okunur. Sonu `\n` ile bitmeyen veya ayrıştırılamayan **son** satır yok sayılır. Bu satır, yazarın `write` sırasında öldüğünü gösterir; D1 gereği o kayda ait SIGSTOP henüz gönderilmemiştir.
4. Ortadaki bir satır ayrıştırılamıyorsa journal bozuk kabul edilir. Muhafazakâr yol izlenir: ayrıştırılabilen **bütün** `freeze` ve `ecore` kayıtları, sonlarında `thaw` olsa bile geri alınır. Kimliği doğrulanmış bir sürece SIGCONT göndermek zararsızdır.
5. Açık kalan her `freeze` grubu için: önce helper'lar, sonra kök; kimlik doğrulandıktan sonra `SIGCONT`. Açık kalan her `ecore` grubu için: kimlik doğrulandıktan sonra `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`. Kimlik okumasındaki `.unknown` kaydı düşürmez: doğrulama, uyanma, workspace sonlanma bildirimi ve geri alma yollarında takip korunur. `EPERM` sonrası bağımsız uid yoklamasında farklı kullanıcı görülürse `.mismatch` sayılır; aynı uid veya okunamayan uid `.unknown` kalır. Sürecin kendisine bağlı `NOTE_EXIT` kesin bilgidir: pid yoklamasına bakmadan üye ve crash tablosu kaydı düşürülür, yeniden kullanılan pid'e sinyal gönderilmez. Başarısız geri alma artan aralıkla yeniden denenir. Uyanmadaki ölçüm hatası sağlık işareti oluşturmaz; sağlık kontrolü yalnız kesin ölüm/kimlik değişimi veya doğrulanmış zombi için `freezeUnsafe` işareti koyar.
6. `recovered` kaydı yazılır (kaç süreç, hangi uygulamalar). Ohm bir sonraki açılışında bunu kullanıcıya gösterir.
7. **Sıkıştırma:** Açık grup yoksa dosya `ftruncate` ile sıfırlanır ve yeni bir `open` kaydı yazılır. Açık grup varsa `journal.jsonl.tmp` yazılır, `fsync` yapılır ve `rename` ile yerine konur. Değişmeyen yeniden deneme sonucu için dosya yeniden yazılmaz ve `fsync` yapılmaz. `ohm-thawd` dosyayı değil dizini izlediği için `rename` güvenlidir.

**Journal kaybolursa ikinci ağ:** Ohm açılışında, aynı kullanıcıya ait `.regular` uygulamaları `pbi_status == SSTOP` durumu için tarar. Journal'da olmayan donuk bir uygulama bulursa **kendiliğinden çözmez**, çünkü onu başka bir araç (ör. App Tamer) durdurmuş olabilir. Bunun yerine "Donuk görünen uygulamalar var: [Çöz]" bildirimi gösterir.

### 6. Çökme kurtarma: ayrı izleyici **ve** sonraki açılışta kurtarma (ikisi birden)

**Karar:** İki mekanizma birlikte kullanılır; ikisi de zorunludur.
1. **İzleyici:** `ohm-thawd` adlı küçük bir süreç, Ohm'dan bağımsız yaşar ve Ohm hangi yolla ölürse ölsün journal'daki her şeyi çözer. T-013 bu modeli ölçtü: ajan `kill -9` ile öldürüldükten 36–39 ms sonra çözdü.
2. **Sonraki açılışta kurtarma:** Ohm (ve `ohm thaw --all`) her açılışta aynı `JournalRecovery` kodunu çalıştırır. Bu mekanizma, izleyici de ölmüşse veya hiç çalışmıyorsa devreye girer. T-013'te ikisi birlikte öldürüldüğünde süreç `T` durumunda kaldı ve bu yolla çözüldü.

**İzleyicinin biçimi:** İzleyici `SMAppService.agent(plistName: "dev.ohm.thawd.plist")` ile launchd'ye kaydedilen bir LaunchAgent'tır. Plist `Ohm.app/Contents/Library/LaunchAgents/` altındadır ve şu ayarları taşır: `BundleProgram = Contents/MacOS/ohm-thawd`, `KeepAlive = true`, `RunAtLoad = true`. `ProcessType` varsayılan (Standard) bırakılır; `Background` seçilmez, çünkü çözme gecikmesini artırabilir.

**Bu biçim henüz doğrulanmadı.** T-013 ayrı bir süreç kullandı, `SMAppService` kaydını değil. Kaydın geliştirme imzasıyla (Apple Development) ve Developer ID ile macOS 26/27'de çalıştığı ve `KeepAlive` ile izleyicinin yeniden başladığı, T-023'ün 13 numaralı kabul testidir.

**Koruma modları (#4, #5).** Governor her an tam olarak bir modda çalışır. Kalıcı etkilerin (dondurma **ve** E-core) ikisi de mod `none` değilken uygulanabilir:

| Mod | Ne zaman | İzleyici | Hazırlık (`protectionReady()`) |
|---|---|---|---|
| `launchAgent` | `SMAppService.agent(…).status == .enabled` | launchd, `KeepAlive` | `status == .enabled` **ve** `thawd.lock` başka bir süreçte tutuluyor (LOCK_SH yoklaması başarısız) |
| `spawnedWatcher` | LaunchAgent kapalı, onay bekliyor, reddedildi veya test 13 kaldı | Ohm, `ohm-thawd --spawned` sürecini `posix_spawn` ile ve `POSIX_SPAWN_SETSID` bayrağıyla başlatır. Böylece izleyici Ohm'un süreç grubunda olmaz ve grup sinyallerinden etkilenmez. | Çocuk süreç canlı **ve** `thawd.lock` tutuluyor; önceki oturumun izleyicisi kilidi zaten tutuyorsa bu koruma yeni çocuk başlatmadan devralınır. Bu durumda Governor her tick'te kilidi yoklar, kaybolursa etkileri geri alıp izleyiciyi yeniden başlatır. Çocuk ölürse Ohm onu hemen yeniden başlatır; başlatamazsa mod `none` olur. Hazır olmayan kendi çocuğunu temizlerken `waitpid` ile sahiplik doğrulanır; başlangıç kimliği okunamasa da çocuk öldürülüp biçilir. `ECHILD` ise sinyal gönderilmez; devralınan izleyiciye dokunulmaz. |
| `none` | İkisi de hazır değil | – | Hazır değil: yeni dondurma ve yeni E-core yok. Mevcut etkiler hemen çözülür ve geri alınır. Ölçüm çalışmaya devam eder. |

- **Mod seçimi:** Açılışta ve `SMAppService` durumu değiştiğinde yapılır. Sıra `launchAgent`, sonra `spawnedWatcher`. Her mod değişimi işlem kuşağını artırır (§ 4).
- **`spawnedWatcher` modunun sınırı:** Ohm ve izleyici birlikte ölürse onları kimse yeniden başlatmaz. Bu senaryoyu sonraki açılışta kurtarma ve `ohm thaw --all` karşılar; README bunu açıkça yazar. `spawnedWatcher` izleyicisi Ohm öldüğünde kurtarmayı yapar; journal boşalınca, yalnız boot'u hiç kaydedilmemiş gruplar kalınca veya 16 başarısız denemeden sonra kendiliğinden çıkar. Son iki durumda kalıntı kayıtlar korunur ve tek uyarı yazılır; kullanıcı çözümü veya sonraki Ohm açılışı gerekir. Başka izleyici `thawd.lock` tutuyorsa yeni spawned süreç beklemeden çıkar; açılış başına bloklu yetim izleyici birikmez. `launchAgent` izleyicisi ise sürekli yaşar.
- **E-core neden korumaya bağlandı:** D2 gereği etkiler Ohm'dan uzun yaşamamalı. E-core görünmez bir yavaşlıktır. Ohm çökerse ve kullanıcı Ohm'u yeniden açmazsa, uygulama kapanana kadar (günlerce) sürebilir. "Oturum kapsamlı, sonraki açılışta geri alınır" seçeneği reddedildi, çünkü tam da bu senaryoyu kapatmıyor. `spawnedWatcher` kullanıcı onayı gerektirmediği için bu kısıt pratikte E-core'u kapatmaz. Mod ancak iki yol da başarısız olursa `none` olur.
- **Kayıt ömrü:** İzleyici (`launchAgent` kaydı veya `spawnedWatcher` süreci), journal'da yeniden denenebilir bir dondurma veya E-core grubu varken kaldırılmaz veya durdurulmaz; spawned süreç için yukarıdaki sınırlı kurtarma bütçesi istisnadır. Boot'u hiç kayıtlı olmayan gruplar tek başına izleyiciyi süresiz yaşatmaz. `unregister()` yalnız journal boşken ve hem dondurma hem E-core özelliği kapalıyken çağrılır.
- **Spawned kurtarma hataları (T-026):** `recoverOnce` sonucu `nil`, yeniden yazım başarısız, çözülmemiş kimlik/sinyal veya bilinmeyen boot ise izleyici `thawd.lock` kilidini tutarak 0,1 → 0,2 → 0,4 → … → kalıcı hatalarda en fazla 300 saniye aralıkla yeniden dener. Bekleme kqueue ile journal/dizin değişince erken sonlanır. Tekrarlanan aynı kurtarma özeti log'a yeniden yazılmaz. LaunchAgent aynı artan aralığı kullanır; yalnız eksik kayıtlı boot kaldığında değişiklik bekler. Ohm açıkken `FreezeJournal.retryRecovery` / `JournalSession.retryRecovery`, zaten tutulan `owner.lock` altında çalışır; Governor `tick` bunu 5 → 10 → … → 300 sn aralıkla çağırır, başarıyla yenilenen writer'ın boot'unu kabul eder ve kurtarma vetosunu kaldırır. Yazım hatası vetosu otomatik kaldırılmaz.

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

Ohm, her freeze ve E-core öncesi (protectionReady'nin parçası):
  flock(thawd.lock, LOCK_SH | LOCK_NB) başarılı olursa → izleyici YOK → kilidi bırak, işlemi reddet (D1)
```

- **`O_CLOEXEC` zorunludur.** Kilit dosyaları `O_CLOEXEC` ile açılır. Ohm'un başlattığı herhangi bir alt süreç (Sparkle yükleyicisi, `open`) kilit tanımlayıcısını miras alırsa, Ohm öldükten sonra kilit bırakılmaz ve izleyici hiç uyanmaz. Ohm `fork()`'u exec'siz kullanmaz.
- **Sonuç:** `kill -9` sonrasında çözme gecikmesi ≈ çekirdeğin kilidi bırakması + journal okuma + `kill` çağrıları. Hedef <1 sn. T-013'te `kqueue NOTE_EXIT` kullanan izleyici 36–39 ms ölçtü. `flock` protokolü de aynı mertebede olmalı; T-023 bunu ölçer.
- **Neden `NOTE_EXIT` değil `flock`:** Spike'taki izleyici Ohm'un pid'ini `NOTE_EXIT` ile izledi. Üretimde `flock` seçildi, çünkü izleyicinin Ohm'un pid'ini öğrenmesi ve Ohm'dan önce başlaması arasında yarış yok. Pid yeniden kullanımı da sorun değil: kilidi çekirdek, süreç öldüğünde bırakır. Tek Ohm örneği garantisi de aynı kilitten gelir.

**Kayıt ve kullanıcı deneyimi:**
- LaunchAgent kurulumda değil, dondurma veya E-core ilk kez kullanıldığında kaydedilir. Öncesinde bir açıklama ekranı gösterilir: "Ohm, beklenmedik şekilde kapansa bile uygulamalarının donuk ya da yavaşlatılmış kalmaması için küçük bir yardımcı süreç kullanır. Giriş Öğeleri'nde 'Ohm' olarak görünür."
- Kayıt reddedilir veya onay beklenirse Ohm `spawnedWatcher` moduna geçer; özellikler kapanmaz. Ayarlar'da "Koruma: sınırlı (Ohm ve yardımcı birlikte kapanırsa yalnız sonraki açılışta çözülür) — [Giriş Öğelerini aç]" satırı gösterilir. Bu satırın düğmesi `SMAppService.openSystemSettingsLoginItems()` çağırır.
- Mod `none` ise Ayarlar'da kırmızı "Koruma kapalı: dondurma ve E-core devre dışı" gösterilir. Ölçüm etkilenmez.
- Homebrew cask'ın `uninstall` bölümü `launchctl bootout gui/$UID/dev.ohm.thawd` içerir.
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

- `PRIO_DARWIN_BG` sürecin kendi özelliğidir ve Ohm'dan bağımsız yaşar. Ohm ölürse politika uygulama kapanana kadar kalır. Bu veri kaybı değil ama D2'ye aykırı ve görünmez bir yavaşlık yaratır. Bu yüzden E-core da journal'a yazılır (`ecore` ve `ecoreOff`) ve çözmeyle aynı katmanlarla geri alınır: düzenli kapanış, sinyal işleyicisi (yalnız dondurma tablosu; E-core işleyicide geri alınmaz), izleyici ve sonraki açılış. E-core da dondurma gibi koruma modu `none` değilken uygulanabilir (§ 6).
- E-core uygulamanın bütün ağacına uygulanır. İşi yapan çoğunlukla helper süreçlerdir (Chrome renderer'ları). Sonradan başlayan helper'lar `ambient` tick'lerinde (10 sn) yakalanır ve politikaya eklenir.
- **Geri alma:** `setpriority(PRIO_DARWIN_PROCESS, pid, 0)`, yalnız Ohm'un journal'ına yazılmış ve kimliği doğrulanan pid'lere uygulanır. T-012 bunun hedef dışındaki bir süreçten çalıştığını gösterdi (P payı 0,00'dan 1,00'a döndü).
- **Durum doğrulaması:** `getpriority` BG durumunu yansıtmadığı için (T-012), politikanın gerçekten uygulandığı `ri_penergy_nj / ri_energy_nj` oranıyla doğrulanır. Yük altında bu oran birkaç tick içinde ~0'a inmelidir. Boştaki bir süreçte oran anlamsızdır; bu durumda doğrulama atlanır ve arayüz yalnız "uygulandı" der.
- **Yan etki (man sayfasından):** Politika disk G/Ç'sini kısar, arka plan durumundayken açılan soketlerin ağ G/Ç'sini de kısar. Politika kaldırıldığında bu soketlerin kısıtının kalkıp kalkmadığı Faz 0'da ölçülmedi. Açık kalan bir risk olarak arayüz "E-core'dan çıkarıldı; yeni bağlantılar normal hızda" notunu gösterir.

### 9. Kullanıcıya görünen durum

- **Menü çubuğu:** En az bir uygulama donuksa halkanın köşesinde ❄ ve sayı görünür.
- **Popover'da "Donuk" bölümü:** Uygulama, ne zamandan beri donuk olduğu, kaynağı (kural adı veya "elle") ve [Çöz] düğmesi. Sayı 0'dan büyükse "Hepsini çöz" her zaman görünür.
- **Ayarlar:**
  - Koruma modu (§ 6): "Koruma: tam (launchd yardımcısı)", "Koruma: sınırlı (Ohm'un başlattığı yardımcı) — [Giriş Öğelerini aç]" ya da kırmızı "Koruma kapalı: dondurma ve E-core devre dışı".
  - Kurallarca dondurulmayan (`freezeUnsafe`) uygulamaların listesi ve işareti kaldırma düğmesi (§ 3).
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
13. **`SMAppService` izleyicisi:** Uygulama Developer ID ile imzalıyken (Faz 4 öncesi geliştirme imzasıyla da) `register()` sonrasında `status == .enabled` olur. `ohm-thawd` `kill -9` ile öldürülünce launchd onu yeniden başlatır ve yeniden başlayan izleyici test 1'i geçer. Başarısızsa `launchAgent` modu devre dışı bırakılır ve ürün `spawnedWatcher` moduyla çıkar (§ 6, test 22).
14. **Elle (otomasyonla yapılamaz):** Donuk uygulama Dock simgesine tıklanarak ve Cmd-Tab ile seçilerek aktive edilir. Her iki yolda da uygulama 300 ms içinde yanıt verir.
15. Ön plandaki bir uygulamayı elle veya kuralla dondurma girişimi `.frontmost` ile reddedilir ve SIGSTOP gönderilmez (D9).
16. E-core uygulanmış bir test sürecinde Ohm `kill -9` ile öldürülür. İzleyici politikayı kaldırır; kanıt olarak yük altındaki sürecin `P_share` değeri 1,00'a döner. Test, dondurmanın **hiç açılmadığı** temiz bir oturumda yapılır (yalnız E-core kullanan kullanıcı; #5).
17. **Geri alma (D10), hata enjeksiyonu:** Kök durdurulduktan sonra ikinci journal kaydı yazılamaz (test kancası). 100 ms içinde kök ve durdurulmuş helper'lar `T` durumunda değildir, grup Governor kaydında yoktur, dondurma ve E-core devre dışıdır. Aynı test kimlik uyuşmazlığı ve doğrulama zaman aşımı için de tekrarlanır.
18. **Yarış (#2):** Gizleme beklemesi sırasında sırayla şunlar tetiklenir: `willPowerOff`, kuralın silinmesi, izleyicinin öldürülmesi, test uygulamasının ses çalmaya başlaması, uygulamanın aktive edilmesi. Hiçbirinde SIGSTOP gönderilmez ve Ohm'un gizlediği uygulama yeniden gösterilir.
19. **Helper üreten ağaç (#3):** Helper'ı her 1 ms'de yeni bir alt süreç başlatan bir test uygulaması `.unstableTree` vetosu alır. Hiçbir süreç `T` durumunda kalmaz.
20. **Helper bekçisi (#3):** Helper'ı, kökün kalp atışı 2 sn'den eskiyse çıkan bir test uygulaması 10 sn dondurulup çözülür. Sağlık kontrolü uygulamayı `freezeUnsafe` işaretler ve sonraki kural dondurması `.unsafeTopology` ile reddedilir.
21. **Gizlemenin geri yüklenmesi (#14):** Görünür bir test uygulamasının dondurması veto ile başarısız olur; uygulama yeniden gösterilir. Zaten gizli olan bir uygulamanın başarısız dondurması onu gizli bırakır.
22. **`spawnedWatcher` uçtan uca (#4):** LaunchAgent kaydı kapalıyken mod `spawnedWatcher` olur. Dondurma ve E-core çalışır; Ohm `kill -9` ile öldürülünce 1 sn içinde çözülür ve politika kaldırılır. İzleyici çocuğu öldürülünce Ohm onu yeniden başlatır; başlatamazsa mod `none` olur ve mevcut etkiler geri alınır.
23. **Aktivasyon gecikmesi Faz B altında:** Doğrulama beklemesi ve `fsync` sürerken gelen aktivasyon çözmesi yine 300 ms içinde tamamlanır.

Kural (T-013 kartıyla aynı): Testler yalnız testin kendi başlattığı süreçlere sinyal gönderir.

## Alternatifler

- **A. Yalnız bir sonraki açılışta kurtarma.** Tek başına reddedildi. `kill -9` kapısını geçemez; kullanıcı Ohm'u yeniden açmazsa uygulamalar süresiz donuk kalır ve bu T1'in kendisidir. İzleyiciyle birlikte ikinci katman olarak kullanılır (§ 6).
- **A2. Yalnız izleyici (sonraki açılışta kurtarma olmadan).** Reddedildi. T-013, izleyici de ölürse sürecin `T` durumunda kaldığını gösterdi. O senaryoyu yalnız açılışta kurtarma kapatır.
- **B. Ohm'un `posix_spawn` ile başlattığı bir alt izleyici (kqueue `NOTE_EXIT` ile ebeveyni izler).** Tek başına birincil yol olarak reddedildi, `spawnedWatcher` modu olarak kabul edildi (§ 6). Zayıflığı: onu Ohm dışında yeniden başlatan kimse yok ve `pkill -9 -f Ohm` gibi desenlerle Ohm'la birlikte ölebilir. `POSIX_SPAWN_SETSID` bayrağı süreç grubu sinyallerini engeller, ama bu deseni engellemez. Artısı Giriş Öğeleri'nde görünmemesi ve kullanıcı onayı gerektirmemesi.
- **C. Root yetkili helper veya daemon.** Reddedildi. Aynı kullanıcının süreçlerine sinyal göndermek root gerektirmiyor. Daemon onayı daha ağır ve saldırı yüzeyi gereksiz büyür.
- **D. SIGSTOP yerine `task_suspend`.** Reddedildi. `task_for_pid` entitlement veya root ister. Ayrıca SIGSTOP durumu `ps` ile görünür ve dışarıdan `kill -CONT` ile düzeltilebilir. Bu, acil çıkış yolunun temelidir.
- **E. Uykudan önce hepsini çözmek.** Reddedildi (§ 7'deki gerekçe).
- **F. Kaydedilmemiş belge sezgisini zorunlu kılmak (Erişilebilirlik izni).** Reddedildi (§ 2'deki gerekçe). İzin varsa ek veto olarak kullanılır.
- **G. Dondurmayı hiç sunmamak, yalnız E-core.** Değerlendirildi. Ürün vaadinin bir parçası olduğu için reddedildi. T-013 aktivasyonda çözmeyi doğruladı. T-023'teki Dock ve Cmd-Tab testi (test 14) kalırsa dondurma elle yapılan ve süre sınırlı bir işleme indirilir; bu, G'ye yakın bir sonuçtur.
- **H. Journal'ı App Group kapsayıcısında tutmak.** Reddedildi. Okuyan sandbox'lı bir bileşen yok. Kritik yolun grup kapsayıcısı TCC davranışına bağımlı olması gereksiz risk.

## Sonuçlar ve riskler

- **(+)** Ohm'un hangi yolla sonlandığından bağımsız olarak (düzenli kapanış, sinyal, çökme, `SIGKILL`, jetsam) çözme ve geri alma garanti eden bağımsız bir süreç vardır. Koruma modu `none` ise ne dondurma ne E-core yapılır.
- **(+)** Acil çıkış yolu (`ohm thaw --all`, `kill -CONT`) hiçbir Ohm sürecine bağımlı değildir.
- **(−)** `launchAgent` modunda Giriş Öğeleri'nde görünen ikinci bir süreç ve tek seferlik bir açıklama ekranı gerekir. `spawnedWatcher` modu bunu gerektirmez ama daha zayıf koruma verir (§ 6).
- **(−)** Dondurma prosedürü karmaşıklaştı: işlem kuşağı, iki faz, sabit nokta, geri alma ve sağlık kontrolü. Bu karmaşıklık T-023'teki 23 kabul testiyle karşılanır; T-024 kritik review'u bu bölüme odaklanmalıdır.
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
- **Açık kalan tek yedekli karar (T-023 test 13):** `launchAgent` modu doğrulanmadı. Başarısız olursa ürün `spawnedWatcher` moduyla ve sonraki açılışta kurtarmayla çıkar (§ 6, test 22).
- **Açık kalan doğrulamalar (T-023):** Dock ve Cmd-Tab ile çözme (test 14, elle). Helper'lı uygulamada sıra ve sekme sağlığı (R4). Süreç ağacının sorumlu pid ve paket yolu kuralıyla doğru kurulması (Chrome, Slack, Safari); kurulmazsa `ppid` zinciri ile paket yolu birlikte kullanılır. Test 14 başarısız olursa `freeze` kurallardan kaldırılır ve dondurma yalnız elle yapılan, en fazla 30 dk süren bir işleme iner.

## T-023 sonuçları (2026-09-29, M3, macOS 27, Xcode 27)

Otomatik testler: `cd app/OhmCore && swift test --filter "OhmJournalTests|OhmGovernorTests"` (31 test). Test 1–3, 16 ve 22 ayrı süreçlerle (`OhmTestHost`: Ohm yerine geçen süreç, izleyici, çöken süreç) çalışır; testler yalnız kendi başlattıkları süreçlere sinyal gönderir.

- **Test 13 — PASS (Apple Development imzası).** Uygulamanın imzalı kopyasında `SMAppService.agent(plistName: "dev.ohm.thawd.plist").register()` → `status == .enabled`, launchd `ohm-thawd`'ı çalıştırdı. İzleyici `kill -9` ile öldürülünce launchd onu ~2 sn içinde yeniden başlattı; yeniden başlayan izleyiciyle test 1: `kill -9` sonrasında 43 ms'de `T` → `S`. Test 2 (Ohm ve izleyici birlikte `kill -9`): launchd'nin yeniden başlattığı izleyici 0,3 sn içinde çözdü. Kayıt test sonunda `unregister()` ile kaldırıldı. **Developer ID imzasıyla denenmedi** (Faz 4'te tekrarlanır).
- **Test 14 — MANUAL.** Uygulama henüz `WorkspaceObserver` → `Governor.handle(_:)` bağlantısını içermiyor (OhmApp T-023 kapsamında değil). Bağlantı yapıldığında kullanıcı şunu yapar: (1) Ohm'da bir test uygulamasını elle dondur (menü çubuğunda ❄ görünür), (2) Dock simgesine tıkla, (3) uygulama 300 ms içinde yanıt vermeli (pencere gelir, `ps -o stat= -p <pid>` `T` göstermez), (4) yeniden dondur, Cmd-Tab ile seç, aynı kontrol. Ölçülebilen kısım test 23'tedir (Faz B altında aktivasyon → SIGCONT 92 ms).
- **Azaltma 7 (Zorla Çık bildirimi)** gözlenmedi; açık kalır.

**ADR'nin sustuğu yerde seçilen (daha güvenli) davranışlar ve düzeltmeler:**
1. § 2 "Hata ayıklanıyor": `pbi_flags` için doğru bayrak `PROC_FLAG_TRACED` (2); `P_TRACED` çekirdeğin `p_flag` bitidir.
2. Ağaç = sorumlu pid'i kök olan **veya** `ppid` zinciri köke ulaşan, yürütülebilir dosyası paket içinde olan süreçler (birleşim). Yollar `realpath` ile karşılaştırılır (`/var` → `/private/var`).
3. Numaralandırma ile SIGSTOP arasında **kaybolan** bir helper atlanır (durduracak bir şey yok); başlangıç zamanı **farklı** olan pid D10 gereği geri alma tetikler.
4. Kurtarmada `boot` bilinmiyorsa (`open` kaydı yok veya `sysctl` başarısız) bu **eşleşme sayılmaz** (D3, T-024 #6): sinyal gönderilmez, grup `unverifiedBoot` olarak raporlanır ve `recovered` notuna yazılır; bu süreçleri açılıştaki SSTOP taraması ve kullanıcı ("Çöz" / `ohm thaw --all`) karşılar.
5. `recovered` kaydı kendinden önceki grupları kapatır. İzleyici her kurtarmadan sonra journal'ı izlemeyi kurduktan **sonra** yeniden kontrol eder (T-024 #3); kurtarma bitemediyse (çözülemeyen üye, yeniden yazma hatası) 0,1 sn'den 300 sn'ye kadar artan aralıkla yeniden dener (T-026b). İzleyici journal **dosyasını ve** dizini izler: sona ekleme dizini değiştirmez.
6. `spawnedWatcher` izleyicisi açık grup beklemeden doğrudan `owner.lock`'ta bloklanır (Ohm onu kilidi tutarken başlatır) ve tek kurtarmadan sonra çıkar. Çocuk varsayılan sinyal durumlarıyla ve boş maskeyle başlatılır. Başlatma beklemez; hazır olma (`thawd.lock`) Governor tarafından askıya alınarak en çok 2 sn beklenir, olmazsa çocuk öldürülür ve mod `none` olur (T-024 #5).
7. `reason` değerlerine `rollback` (§ 4 sözde kodu), `protectionLost`, `journalUnwritable`, `frontmost` eklendi. `recovered` kaydı `count` ve `apps` alanlarını taşır; helper'lar 32'lik kayıtlara bölünür (< 4 KB).
8. **2026-09-30 — T-064 ürün kararı:** Yalnız E-core için Apple/sistem kapsam vetoları, `activationPolicy == .regular` olan ve yürütülebilir dosyasının `realpath` ile çözülmüş yolu `/Applications/**`, `/System/Applications/**` veya Safari için `/System/Cryptexes/App/System/Applications/**` altındaki bir `.app` paketinde bulunan kullanıcı uygulamalarında kaldırılır (Xcode, TextEdit, Safari). Yol çözülemezse istisna uygulanmaz. `/System/Library/**`, `/usr/**`, `/Library/Apple/**`, `.accessory`/`.prohibited` Apple süreçleri ve sistem daemon'ları korunur; Ohm'un kendisi, kendi pid'leri, paket içindeki ohm-thawd ve mevcut kullanıcı listesi vetoları kaldırılmaz. Mevcut üçüncü taraf/elle E-core kapsamı ve izin listesi davranışı korunur. Dondurmanın `appleBundle`, `systemPath` ve topoloji kuralları değişmez. Gerekçe: E-core dondurmaz; `PRIO_DARWIN_BG` journal ve izleyici korumasıyla geri alınabilir (§ 8), bu yüzden Apple kullanıcı uygulamalarını tamamen dışlamak gereksizdir.
9. İşlem sürerken görülen bir aktivasyon, `isActive` henüz güncellenmemiş olsa bile `.frontmost` vetosudur (`NSRunningApplication` özellikleri ana run loop turunda yenilenir).
10. Sağlık kontrolü `terminated`, `quit`, `powerOff` ve `rollback` çözmelerinden sonra yapılmaz; ebeveyni tarafından henüz toplanmamış (zombi) bir üye "sonlanmış" sayılır.
11. Güç iddiası vetosu: seviyesi 0 olmayan **her** IOPM iddiası. Ölçemeyen bir güvenlik yoklaması (CoreAudio, CMIO, IOPM, event tap, `proc_pidinfo`, alt süreç listesi) "güvenli" sayılmaz: `.safetyProbeFailed` vetosu döner (T-024 #7). `AXEdited` vetosu doğrulanmadığı için uygulanmadı.
12. "Hepsini çöz" (`.user`) yalnız dondurmayı çözer; `quit`, `powerOff`, `protectionLost`, `journalUnwritable` E-core'u da kaldırır. Sinyal yolları pid ≤ 1'i reddeder.

### T-024 review düzeltmeleri (2026-09-29)

Her düzeltmenin bir regresyon testi var (`OhmGovernorTests/T024RegressionTests.swift`, `OhmJournalTests` içindeki `T-024` testleri). Eski API ile yazılabilenler (#1a, #1b, #2a, #2b, #4, #5a–c, #6 kurtarma) düzeltmeden önceki kodda (`faf7bdd`) çalıştırıldı ve kaldı. API değiştiren düzeltmelerin testleri (#1c, #1 kurtarma, #3, #6 işleyici, #7) ise düzeltme satırı geçici olarak geri alınarak çalıştırıldı ve kaldı; düzeltmeyle geçiyorlar.

1. **Başarısız geri alma unutulmaz.** Her üye için sonuç ayrılır: sürdürüldü / süreç yok (ESRCH) / pid başka süreçte → çözüldü; yoklama hatası veya başarısız `kill`/`setpriority` → çözülmedi. Çözülmeyen üyeler bellekte (`pendingUndo`) ve çökme tablosunda kalır, grubun `thaw`/`ecoreOff` kaydı yazılmaz (journal'da açık kalır, izleyici kapsar); Governor artan aralıkla ve her tick'te yeniden dener. Kurtarma da çözülemeyen üyeleri yeni journal'da açık tutar.
2. **Journal yenileme hatası etkileri durdurur.** Yazma, `fsync` veya sıkıştırma hatasından sonra yazar kalıcı olarak "bozuk"tur ve her ekleme hata verir (yarım satıra yapışan kayıt ve ardından SIGSTOP olamaz). Kurtarmanın yeniden yazması başarısızsa `JournalSession.open` hata verir; açılışta son satırı `\n` ile bitmeyen dosya reddedilir.
3. **İzleyici penceresi** (yukarıda madde 5).
4. **Uzlaştırma bayat istekle devam etmez.** `reconcile` her `await`'ten sonra işlem kuşağını kontrol eder; değiştiyse döngüden çıkar. E-core parametreleri anlık `desired`'dan okunur.
5. **Koruma hazır değilken etki yok.** `tick` önce hazırlığı kontrol eder; hazır değilse yeni helper'a BG konmaz, mevcut dondurma ve E-core geri alınır ve Governor `protectionMode` olarak `none` bildirir. İzleyici başlatma beklemesi Governor kuyruğunu bloklamaz (test: bekleme sürerken aktivasyon < 1 ms'de işlendi). Faz B'deki en çok 100 ms'lik doğrulama beklemesi ve `fsync` § 4 gereği kuyrukta kalır (test 23: 92 ms).
6. **Çökme işleyicisinde katı D3.** Tablo `(pid, ri_proc_start_abstime)` çiftlerini tutar. İşleyici her girdiyi `proc_pid_rusage` ile yeniden doğrular ve yalnız eşleşene SIGCONT gönderir. `proc_pid_rusage` macOS 27'de yazmaç taşıma + `__proc_info` sistem çağrısı saplamasına (`svc #0x80`, 336) kuyruk çağrısıdır (lldb ile sökülerek doğrulandı): kilit ve bellek ayırma yok, dolayısıyla async-signal-safe. Her büyük macOS sürümünde yeniden sökülerek doğrulanır (R5). Doğrulanamayan girdi atlanır; onu izleyici çözer.
7. **Yoklama hatası veto'dur** (yukarıda madde 11).
- **Gözlem:** İşleyici önceki işleyicilere zincirlenmez (async-signal-safe oldukları bilinmiyor); varsayılan eylemi geri yükleyip sinyali yeniden yükseltir.

## T-026b takip notları

- E-core parametre yenilemesi yalnız kural kökenli gruba uygulanır. Elle açılan grubun `.release` politikası bir kuralın `.keep` politikasıyla ezilemez; kural bitince ön plandaki manuel grup takılı kalmaz.
- Bozuk bir orta satır, geçerli yeni `open` satırına kadar boot aidiyetini `nil` yapar. Önceki segmentin boot'u sonraki gruplara taşınmaz. Bu olasılık regresyon testiyle yeniden üretildi.
