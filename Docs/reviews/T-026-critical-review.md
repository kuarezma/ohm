# T-026 kritik review: dondurma güvenliği P1'leri ve topoloji izin listesi

- İnceleyen: Opus 5.5 (opus-high ajanı), salt okunur
- Kapsam: `/Users/ugurmac/Desktop/worktrees/t026-freeze-safety` içindeki commit edilmemiş diff (taban 8042507), `.card.md`, `.result.md`, ADR 0004, T-001b bulguları #1–4 ve #8
- Kapı: Şef kapıyı sandbox dışında koştu (Journal 14/14, Governor 45/45). Ben testleri yeniden koşmadım. Tek deneyim şuydu: `proc_pid_rusage` kendi pid'imde `rc=0`, root'a ait pid 1'de `rc=-1 errno=1 (EPERM)` döndü (P2-2'nin kanıtı).
- Karar: **MERGE-WITH-FOLLOWUP**

## Özet

Kartın beş maddesi kodda karşılanmış. Kimlik yoklaması `.unknown` döndüğünde yeni kodda donuk bir süreci unutan bir yol bulmadım. Boot okunamazsa Governor etkiyi kernel çağrısından önce reddediyor. Kurtarma da yanlış boot'a ait pid'e sinyal göndermiyor. Swift 6 tarafında yeni `await` noktası yok. Test beklentileri zayıflatılmamış.

P1 bulmadım. Buna karşılık beş P2 var:
- İki canlılık sorunu: `.unknown` sonsuza kadar sürerse sonsuz döngü ve kaçış yolu yok; ayrıca çıkış olayı yok sayılıyor.
- Bir E-core davranış gerilemesi.
- Bir karar çelişkisi: `.runaway` ile ADR §2 çakışıyor.
- Ohm açıkken yeniden deneme yapılmıyor.

Ürün tarafında Governor henüz bağlanmadı. `OhmApp` `Governor` ya da `JournalSession` oluşturmuyor, `app/ohm/main.swift` ise 19 satırlık bir taslak. Bu yüzden P2'ler bağlama işinden önce kapatılabilir.

## P1

Yok.

## P2

### P2-1. Kalıcı "doğrulanamaz" durumu sonsuz yeniden deneme doğuruyor ve kaçış yolu yok
- **Yer:** `JournalRecovery.swift:30` (`needsRetry` içinde `unverifiedBoot`), `:93-96` (`g.boot == nil` olan grup her seferinde tutuluyor); `ThawWatcher.swift:67-78` (spawned), `:88-103` (agent); `T026JournalRegressionTests.swift:32-59` bu davranışı istenen davranış olarak sabitliyor.
- **Senaryo A (boot'u nil grup):** Journal'da `open` kaydı olmayan ya da `open(boot: nil)` altında kalan bir grup var. Bunun nedeni HEAD sürümü Ohm'un sysctl başarısızken yazdığı eski journal olabilir. Bir diğer olasılık, ilk `open` satırı bozulmuş bir journal'dır (corrupt modda sonraki bütün gruplar `boot=nil` alır). Güncel boot okunabilse bile bu grup **hiçbir zaman** doğrulanamaz; yeniden başlatmadan sonra da durum aynıdır. Sonuçlar:
  - Spawned izleyici hiç çıkmaz.
  - LaunchAgent `waitForOpenGroups` içinde hiç uyumaz. Her 5 saniyede bir `flock`, okuma, sysctl, `fsync` ve `rename` ile yeniden yazma ve bir log satırı üretir; bu, yeniden başlatmalar boyunca sürer (günde yaklaşık 17 bin fsync).
  - Her Ohm açılışı yeni bir spawned izleyici başlatır. Bu izleyici `thawd.lock` üzerinde bloklanıp kalır, Ohm kapanırken de durdurulmaz (`stopSpawnedWatcher` yalnız journal boşken çağrılır). Sonuçta açılış başına bir yetim süreç birikir.
  - `ohm thaw --all` aynı `JournalRecovery`'yi kullandığı için bu grubu kapatamaz. Testteki "kullanıcı çözümü" (`T026RegressionTests.swift:276-284`, elle `thaw` satırı ekleme) üründe karşılığı olmayan bir yoldur.
- **Senaryo B (EPERM ile `.unknown`):** Takip edilen bir pid öldükten sonra başka bir kullanıcının, örneğin root'un süreci tarafından yeniden kullanılırsa `proc_pid_rusage` EPERM döner, yoklama da kalıcı olarak `.unknown(EPERM)` olur. Bunu doğruladım: pid 1'de `errno=1`. Kurtarmada `unresolved`, Governor'da `pendingUndo` kalıcı hale gelir. Bu durumda da izleyici hiç çıkmaz ve 5 saniyelik döngü sürer. Governor tarafında `pendingUndo` 5 saniyede bir sonsuza kadar denenir, `ThawTable` yuvası da sızar.
- **Öneri:**
  1. "Güncel boot geçici olarak okunamıyor" (yeniden dene) ile "grubun boot'u kayıtlı değil" (hiç doğrulanamaz) durumlarını ayır. İkincisi için bir kez bildirim yaz. Grubu `needsRetry` dışında tut: ya eski davranışa dönüp düşür ya da kayıt `ts` < `kern.boottime` ise başka boot'a ait say ve at.
  2. `.unknown(EPERM)` için ikinci bir yoklama ekle. `sysctl KERN_PROC_PID` ya da `proc_pidinfo` ile pid'in uid'i okunur. Uid Ohm'un uid'inden farklıysa (Ohm yalnız kendi uid'ine sinyal gönderebilir) `.mismatch` say.
  3. Belirli sayıda denemeden sonra izleyiciler için aralığı büyüt (≥ 60 sn) ve kqueue ile journal değişikliğini bekle.
  4. `ohm thaw --all` için açık bir "zorla kapat" yolu tanımla.

### P2-2. Çıkış olayı kesin bilgi olduğu halde `.unknown`/`.match` yoklaması üyeyi grupta tutuyor
- **Yer:** `Governor.swift:514-531` (özellikle `:523-527`), `ECoreLane.swift:86-96`.
- **Senaryo:** Bir helper'ın `DispatchSource` çıkış olayı gelir (kqueue `NOTE_EXIT` pid numarasına değil sürecin kendisine bağlıdır, yani bu üye kesin olarak ölmüştür). `processExited` önce `unwatch(pid)` çağırır, sonra yoklama yapar.
  - Pid, çıkış olayı ile Task'ın çalışması arasında root'a ait bir süreç tarafından yeniden kullanıldıysa `.unknown(EPERM)` döner. Üye grupta kalır, artık izlenmez, çözmede `unresolved` olur ve P2-1B'deki kalıcı döngüye girer.
  - Pid zombi ise (donuk kök çocuğunu biçemez) `.match` döner ve üye yine grupta kalır. Bu durum zararsızdır, çünkü zombiye SIGCONT gönderilir.
- **Öneri:** Çıkış kaynağından gelen çağrıya `authoritative: true` geçir ve bu durumda yoklamadan bağımsız olarak üyeyi düşür. Yoklamaya dayalı karar yalnız `.didWake` ve `.terminated` yollarında kalsın.

### P2-3. E-core `params` yenilemesi kökene bakmıyor; elle açılan grubun `.release` politikası kural tarafından ezilebiliyor
- **Yer:** `Governor.swift:660` (`lane.updateParams` her `ensureECore` çağrısında), `ECoreLane.swift:27-29`, rule sonu kaldırma `Governor.swift:184`.
- **Senaryo:**
  1. Kullanıcı uygulama X için elle E-core açar. `manualECore` params her zaman `.release`'tir.
  2. Aynı bundle için `whileFrontmost: .keep` olan bir kural etkin hale gelir. `reconcile`, `ensureECore(params: .keep)` çağırır ve grubun params'ı `.keep` olur.
  3. X öne gelince E-core kaldırılmaz. Kural bittiğinde `:184` yalnız `origin.isRule` gruplarını kaldırdığı için bu elle açılmış grup kalır ve params `.keep` olarak takılı kalır. Ön plandaki uygulama E-core'da kalır, bu da kullanıcıya görünür bir yavaşlıktır.
  HEAD'de params yalnız uygulama anında atanıyordu, bu yüzden bu gerileme T-026 ile geldi.
- **Öneri:** Yenilemeyi yalnız grubun kökeni kural olduğunda yap. Ya da birleştirmede daha güvenli olanı seç: `.release`, `.keep`'i yener. Karışık köken için bir regresyon testi ekle.

### P2-4. `.runaway`'in "otomatik" sayılması ADR 0004 §2 ile çelişiyor (karar gerekli)
- **Yer:** `Governing.swift:24-29` (`isAutomatic`), `SafetyPolicy.swift:152,164-170`, `Governor.swift:444`; ADR 0004 `:57` ile `:93`; ADR 0003 `:113`; `RuleValidator.swift:52-53`; `Governing.swift:60`.
- **Durum:**
  - Kodda `.runaway` kökeni yalnız kaçak süreç kartındaki **kullanıcı onaylı** eylemden gelir. Kurallar kaçak hedefle dondurma yapamaz (`RuleValidator:53`: "kaçak süreçler yalnız kullanıcı onayıyla dondurulur"). `reconcile` her zaman `.rule` kökeni üretir.
  - ADR 0004 §2 `:57`, arka plan ve paketsiz süreçlerin (ör. `node`) "yalnız elle, kaçak süreç kartında ek onayla" dondurulacağını söyler.
  - Yeni `:93` satırı ise `.runaway`'i otomatik sayıyor ve bundle ID'si olmayan hedefi reddediyor.
- **Sonuç:** Kart yolunun kendisi (`backgroundNeedsConfirmation`, `SafetyPolicy.swift:198`) kodda duruyor, ama TextEdit dışındaki her hedef, özellikle paketsiz kaçak süreçler, artık `.unverifiedTopology` alıyor. Yani §2'deki ek onay yolu fiilen ulaşılamaz hale geldi ve ADR kendi içinde çelişiyor.
- **Buna bağlı ürün etkisi:** Varsayılan `GovernorConfig.appleAllowlist` = {Safari, Preview} (`Governor.swift:27`). TextEdit bu yüzden `.appleBundle` vetosu alıyor. Topoloji listesi ile Apple izin listesinin kesişimi boş, bu da üretimde **hiçbir uygulamanın otomatik dondurulamayacağı** anlamına geliyor. Testler TextEdit'i yalnız `testConfig` içinde izinli yapıyor (`Support.swift:345`). `.result.md` bunu dürüstçe belirtmiş, ama ADR'de açıkça yazmıyor.
- **Öneri:** Şef ya da kullanıcı karar vermeli.
  - (a) `.runaway` kullanıcı onaylı sayılsın ve `isAutomatic` yalnız `.rule` olsun. T-001b #4 metnindeki "kaçak süreç" ifadesi, koddaki onaylı kart yoluyla uyumlu olacak şekilde düzeltilsin.
  - (b) Ya da §2 `:57` "kaçak süreç kartından dondurma kapalı" diye güncellensin ve UI'daki Dondur düğmesi kaldırılsın.
  Her iki durumda ADR'ye "varsayılan yapılandırmada otomatik dondurma fiilen kapalı" cümlesi eklenmeli.

### P2-5. Ohm açıkken tutulan (bilinmeyen boot veya çözülmemiş) gruplar için kimse yeniden denemiyor
- **Yer:** `JournalRecovery.swift:190-198` (`JournalSession.open` kurtarmayı bir kez koşar), `ThawWatcher.swift:106-117` (izleyici `owner.lock` üzerinde bloklanır), Governor'da kurtarmayı yeniden deneyen bir kanca yok.
- **Senaryo:** Ohm çöker ve dondurulmuş gruplar kalır. Yeni Ohm açıldığı anda sysctl geçici olarak başarısız olursa gruplar tutulur ve Governor devre dışı kalır. Bu doğru davranış. Ama Ohm açık kaldığı sürece (günlerce olabilir) `owner.lock`'u tuttuğu için izleyici deneyemez, Ohm da yeniden denemez. Önceki oturumun uygulamaları bu süre boyunca SIGSTOP'ta kalır. Kartın 2. maddesindeki "grubu koru, yeniden dene" isteği bu en olası durumda karşılanmıyor. Güvenlik açısından HEAD'den kötü değil (HEAD'de de sinyal gönderilmiyordu), ama söz verilen davranış eksik.
- **Öneri:** `JournalSession`'a, tutulan kilitle çağrılabilen bir `retryRecovery()` ekle. Governor `tick` içinde, son rapor `needsRetry` ise bunu sınırlı aralıkla çağırsın. Başarılı olursa yeni bir `FreezeJournal` açılsın ve `disabledReason` temizlensin. Bu karmaşıksa en azından UI'da görünür bir uyarı ve "Ohm'u yeniden başlat" önerisi olsun.

## P3

1. **Uyanmada `.unknown` sağlık işaretini yanlış tetikliyor.** `Governor.swift:289-299` `.unknown` için `thawGroup(.verifyFailed)` çağırıyor. `:552-553` bu nedenle sağlık kontrolü planlıyor, `:622-627` ise `isLive` false döndüğü için yoklama hatasında bundle'ı `freezeUnsafe` işaretliyor. Yani bir yoklama hatası kalıcı bir "güvensiz" işaretine dönüşüyor. Öneri: `.unknown` nedeniyle yapılan çözmede sağlık kontrolünü atla, ya da `healthCheck` içinde yalnız `.gone` durumunu say. Ayrıca `:297-298`'de helper `.unknown` olduktan sonra `break` yok. Aynı grup için gereksiz `thawGroup` ve `processExited` çağrıları yapılıyor; zararsız ama gürültülü.
2. **"Otomatik" tanımı tutarsız.** Sağlık vetosu (`.unsafeTopology`) ve kamera vetosu `forRule: origin.isRule` ile çalışıyor (`SafetyPolicy.swift:213,223`; `Governor.swift:445,461`; `Freezer.swift:78`). Yeni `isAutomatic` tanımı `.runaway`'i de kapsıyor, ama `.runaway` bu vetoları atlıyor. P2-4'teki karara göre hizalanmalı.
3. **Veto nedeni yanıltıcı.** Boot yokken veto nedeni `.journalUnwritable` (`Governor.swift:105`). Kullanıcı ve destek için ayrı bir `.bootUnverified` nedeni daha doğru bir teşhis verir.
4. **Kural kaydı yeni kapıyı bilmiyor.** Kural kaydında statik kapsam denetimi (`SafetyPolicy.staticScopeVetoes`, yorumu ADR 0003'e atıf yapıyor) topoloji listesini içermiyor. Kullanıcı, çalışma anında hep `.unverifiedTopology` alacak bir dondurma kuralı oluşturabilir. Kural kaydında da reddedilmeli ya da uyarılmalı.
5. **Corrupt modda boot aidiyeti (PLAUSIBLE, büyük ölçüde önceden var olan sorun).** `JournalRecord.swift:140-142`'de bozuk bir `open` satırından sonraki gruplar bir önceki segmentin boot'unu devralıyor. T-026, her tutulan grup için ayrı `open` satırı ve bir de kuyruk `open(cur)` satırı ekleyerek `open` satırı sayısını artırdı. Kuyruk satırı bozulursa yeni gruplar `nil` boot devralır ve kalıcı olarak tutulur (P2-1). Güncel segmentin `open` satırı bozulursa güncel gruplar eski boot'a atfedilir ve sinyalsiz atılır (dondurulmuş kalır). Öneri: corrupt modda bozuk satırdan sonraki grupları "boot doğrulanmadı" say.
6. **Spawned izleyici log'u sınırsız büyüyebilir.** Spawned izleyici her denemede miras aldığı stdout'a bir satır yazıyor. P2-1 senaryosunda log sınırsız büyür. Tekrarlanan aynı satırı bastırmak yeterli olur.

## Sorulara yanıtlar

1. **`.unknown` durumunda unutma:**
   - Freezer: `stopOne` ve `verifyStoppedBlocking` `.unknown` görünce hata fırlatıyor; tüm `stopped` listesi rollback'e gidiyor; `unresolved` → `pendingUndo` ve `ThawTable` korunuyor.
   - Governor: uyanmada grubu çözüyor, `processExited` üyeyi tutuyor.
   - ECoreLane: `apply`/`extend` yalnız `.match` durumunda uyguluyor, `dropMember` üyeyi tutuyor, `finish` `unresolved` döndürüyor.
   - JournalRecovery: `pending` ile tutuyor.
   Yeni kodda unutma yolu bulmadım. Tersine, `.unknown` sonsuza kadar sürerse sızıntı ve döngü **var**: P2-1 ve P2-2.
2. **Boot kapısı:**
   - Dondurma: Faz A'da `admissible` gizlemeden önce, Faz B'de freezer'dan önce `.journalUnwritable` veriyor.
   - E-core: `ensureECore` bunu `apply`/`extend`'den önce veriyor.
   - `tick` içindeki `extend` yalnız var olan gruplara uygulanıyor; init'te devre dışı kalan bir Governor'da grup yok.
   - Kurtarma bilinmeyen boot ile sinyal göndermiyor. Tutulan grup kendi `open(boot: g.boot)` segmentini alıyor, yeni eklemeler kuyruktaki `open(cur)` altına düşüyor. `FreezeJournal.init` yalnız son `open` güncel boot'a eşitse boot kabul ediyor.
   Yanlış boot'a SIGCONT/setpriority gönderen yeni bir yol bulmadım. Corrupt modda risk sürüyor (P3-5).
3. **ThawWatcher:** Kilit tutulurken döngü yok; `recoverOnce` her deneme sonunda `owner.lock`'u bırakıyor, beklemesi en fazla 5 saniye ve flock bloklanırken CPU harcamıyor. İki yazarın çakışması mümkün değil, çünkü bütün yazımlar `owner.lock` altında ve Ohm bu kilidi ömrü boyunca tutuyor. Eski spawned izleyici `thawd.lock`'u tutarken yeni Ohm'u da işlevsel olarak koruyor. Sorun canlılıkta: P2-1'deki sonsuz 5 saniyelik döngü ve yetim izleyici birikimi.
4. **Topoloji:** `.manual`/`.cli` muafiyeti doğru, E-core'a da uygulanmıyor. Ancak `.runaway`'i otomatik saymak §2'deki arka plan ek onay yolunu fiilen kapatıyor (P2-4). `backgroundNeedsConfirmation` kodu bozulmamış.
5. **Swift 6 concurrency:** Yeni yolların hepsi senkron, yeni bir `await` noktası eklenmemiş. `for g in groups.values` kopya üzerinde dönüyor. `switch` içindeki `continue`/`break` anlamları doğru. Faz B'de askıya alma yok. Re-entrancy hatası bulmadım. `reconcile`'da `await`'ten önce yakalanan `effect` önceden vardı ve `generation` kontrolüyle korunuyor.
6. **Test beklentileri:** Zayıflatılmamış.
   - `Support.swift:345` TextEdit'i yalnız test yapılandırmasında Apple izin listesine ekliyor. `extra_scope` (`OhmGovernorTests.swift:669`) varsayılan `GovernorConfig()` ile `.appleBundle` beklentisini koruyor.
   - `OhmGovernorTests.swift:456`: `ruleDeleted` tetikleyicisi TextEdit'e geçmek zorundaydı, yoksa Faz A'da veto alınır ve yarış yoluna hiç girilmezdi. `hideCalls == 1` beklentisi yarış yoluna gerçekten girildiğini kanıtlıyor.
   - `T024RegressionTests.swift:138`: dondurma erken reddedilseydi E-core uygulanır ve `eCoreRootPids.isEmpty` beklentisi kırılırdı. Yani test hâlâ anlamlı.
   Eksik test: karışık kökenli E-core params (P2-3) ve kesin çıkış olayı (P2-2).

## Karar

**MERGE-WITH-FOLLOWUP.** P1 yok. P2-2 ve P2-3 küçük düzeltmeler; P2-1 ve P2-5 canlılık işi. Bunların hepsi ürün bağlanmadan (Governor/JournalSession/CLI) önce kapatılmalı. P2-4 kod hatası değil, bir karar çelişkisi. ADR'deki `:57` / `:93` çelişkisi, kaçak süreç kartı bağlanmadan önce şef ya da kullanıcı kararıyla giderilmeli.
