# T-001b — ADR'lere ikinci görüş (GPT-6.1 Sol high, salt okunur) ve şef kararları

Tarih: 2026-09-29. İnceleyen: GPT-6.1 Sol high (Codex, salt okunur). Karar: şef (Opus 5.5 medium).
P1'ler şef tarafından kodda doğrulandı: `Freezer.swift:131,140`, `JournalRecovery.swift:75-77,126`, `ThawWatcher.swift` `case .spawned` (`recoverOnce` sonucu okunmadan `exit(0)`).

## Kararlar

| # | Önem | Karar | Görev |
|---|------|-------|-------|
| 1 | P1 | Kabul. `matches` yerine her yolda `IdentityStatus`; yalnız `.gone`/`.mismatch` üyeyi düşürür, `.unknown` kaydı korur. | T-026 |
| 2 | P1 | Kabul. Bilinmeyen boot ≠ farklı boot: grup `retained`'da kalır, yeniden denenir; güvenilir boot yoksa yeni kalıcı etki uygulanmaz. | T-026 |
| 3 | P1 | Kabul. `spawnedWatcher` yalnız açık etki kalmadığında çıkar; başarısızlıkta artan aralıkla yeniden dener. | T-026 |
| 4 | P2 | Kabul (kullanıcı kararı şefe bıraktı, 2026-09-30). Otomatik dondurma (kural, kaçak süreç) yalnız doğrulanmış topoloji izin listesindeki bundle'lar için; listede yoksa `FreezeVeto.unverifiedTopology`, E-core serbest. Elle dondurma serbest; sağlık kontrolü ek koruma olarak kalır. ADR 0004'e işlenir. | T-026 |
| 5–7, 9 | P2 | Kabul. Doğal dil koşulu sessizce düşmez; eksik alan varsayılanla doldurulmaz, `.ready` öncesi doğrulama; `pendingInactive` katkıyı korur; ad çözümü belirsizlikte soru sorar. | T-028 |
| 8 | P2 | Kabul. Uzlaştırmada mevcut E-core grubunun parametreleri yenilenir. | T-026 |
| 10–16 | P2 | Kabul. Ledger: dakika sınırında orantılı bölme, rollup `rolled_through_hour`'dan, fiş/P_ref saatlik+dakikalık birleşim, karma fişte kaynak ayrımı, V×I kaynak kimliği, `readable_cpu_uj`, WAL ile birlikte yedek. | T-027 |
| 17 | P2 | Kabul. Sınırsız `AsyncStream` geri basınç sayılmaz; sınırlı ve toplamları koruyan aktarım. | T-029 |
| 18 | P2 | Kabul. GPU muhasebesi T-021 ölçümüne göre ayrı toplam satırı; ADR 0002 formülü buna göre tek karara indirilir, M3/macOS 27 kapsamı yazılır. | T-027 |

## Sol'un tam raporu

ADR 0004’ün kurtarma garantisini engelleyen **üç P1 bulgu** var. Diğer bulgular P2 düzeyinde davranış, hesap veya karar çelişkileri. İnceleme salt okunur yapıldı; hiçbir dosya değiştirilmedi, build veya test çalıştırılmadı.

1. **P1 — ADR 0004: Kimlik yoklaması hatası, donuk helper’ın öldüğü kabul edilerek kaydını silebiliyor.**

   `matches`, başlangıç zamanı okunamadığında da `false` dönüyor. Dondurma doğrulaması bu helper’ı gruptan ve çökme tablosundan çıkarıyor; uyanma yolu da aynı sonucu `processExited` olarak işliyor. Helper gerçekte hâlâ donuksa sonraki çözme onu kapsamaz; grubun `thaw` kaydı da journal’daki kurtarma bilgisini kapatır. Bu, ADR’nin “yoklama hatası çözülmemiştir, unutulmaz” kararına aykırı.

   **Kanıt:** [ADR 0004:424](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:424), [Signaling.swift:20–21](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Signaling.swift:20), [Freezer.swift:130–140](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Freezer.swift:130), [Governor.swift:284–286](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Governor.swift:284), [Governor.swift:501–504](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Governor.swift:501).

   **Önerilen karar:** Bu yolların tamamında `IdentityStatus` kullanılsın. Yalnız `.gone` ve `.mismatch` üyeyi düşürsün; `.unknown` geri alma ve yeniden deneme kaydını korusun.

2. **P1 — ADR 0004: Önyükleme kimliği okunamayınca açık etkilerin kalıcı kaydı kaybediliyor.**

   Kurtarma, bilinmeyen `boot` için sinyal göndermemekte haklı; ancak grubu `retained` içine almadan devam ediyor. Ardından journal yeniden yazılıyor ve yalnız kaç sürecin doğrulanamadığını söyleyen bildirim kalıyor. Geçici bir `sysctl` hatası böylece sonraki kurtarma denemesinin kullanacağı pid, başlangıç zamanı ve etki türünü silebiliyor. ADR’nin önerdiği SSTOP taraması E-core politikasını bulamaz; ADR zaten `getpriority` ile bunun okunamadığını belirtiyor.

   **Kanıt:** [ADR 0004:410](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:410), [ADR 0004:189](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:189), [JournalRecovery.swift:75–81](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmJournal/JournalRecovery.swift:75), [JournalRecovery.swift:119–126](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmJournal/JournalRecovery.swift:119).

   **Önerilen karar:** Bilinmeyen oturum, farklı olduğu doğrulanmış oturumdan ayrılmalı. Mevcut kimlik bilgileri korunmalı, kurtarma yeniden denenmeli; güvenilir `boot` kaydı oluşturulamıyorsa yeni kalıcı etkiler uygulanmamalı.

3. **P1 — ADR 0004: `spawnedWatcher`, başarısız kurtarmadan sonra da çıkıyor.**

   Bu mod `recoverOnce` sonucunu kontrol etmeden `exit(0)` çağırıyor. Kilit alma, journal yenileme veya SIGCONT/BG kaldırma başarısız olduğunda süreç yine sonlanıyor. Ohm zaten öldüğü için izleyiciyi yeniden başlatamaz; launchd gözetimi de bu modda yoktur. Tek bir kurtarma hatası uygulamayı sonraki Ohm açılışına kadar donuk veya yavaşlatılmış bırakabilir.

   **Kanıt:** [ADR 0004:230](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:230), [ADR 0004:411](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:411), [ThawWatcher.swift:54–58](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmJournal/ThawWatcher.swift:54), [ThawWatcher.swift:88–98](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmJournal/ThawWatcher.swift:88).

   **Önerilen karar:** `spawnedWatcher` yalnız kurtarma tamamlanıp açık etki kalmadığında çıkmalı. Başarısızlıkta LaunchAgent yolundaki gibi artan aralıklarla yeniden denemeli.

4. **P2 — ADR 0004: `freezeUnsafe` dışında kalmak, ilk dondurmanın güvenli olduğunu kanıtlamıyor.**

   Otomatik dondurma için sabit nokta ve negatif listenin dışında olma yeterli kabul edilmiş. Oysa ADR’nin kendi kabul senaryosu, helper bekçisinin çözülünce sonlanabileceğini gösteriyor. Beş saniye sonraki sağlık kontrolü sonraki dondurmaları engeller; ilk işlemde kaybedilmiş helper durumunu geri getiremez. Spike ise yalnız TextEdit’i ölçmüş.

   **Kanıt:** [ADR 0004:92–93](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:92), [ADR 0004:345](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:345), [ADR 0004:372](/Users/ugurmac/Desktop/macbook/Docs/adr/0004-freeze-safety.md:372), [Governor.swift:596–600](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Governor.swift:596).

   **Önerilen karar:** Otomatik dondurma, gerçek uygulamayla doğrulanmış topolojilerin izin listesiyle başlamalı. Sağlık kontrolü ek koruma olarak kalmalı; doğrulanmamış çok süreçli uygulamalar için ilk denemenin riski açıkça karara bağlanmalı.

5. **P2 — ADR 0003: Doğal dil katmanı geçerli saat koşulunu sessizce kaldırabiliyor.**

   DTO dönüşümü, cümlede `:` yoksa `timeBetween` koşulunu siliyor. Örneğin “22 ile 7 arasında Slack’i dondur” için model doğru saat alanları üretse bile koşul kaldırılır. Tek koşul buysa derleyici `.all([])` üretip `.ready` dönebilir; motor boş `all` koşulunu doğru değerlendirir. Saatle sınırlı istek koşulsuz isteğe dönüşür.

   **Kanıt:** [ADR 0003:293](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:293), [NLRuleParser.swift:241–245](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/NLRuleParser.swift:241), [RuleCompiler.swift:203–229](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleCompiler.swift:203), [RuleEngine.swift:406–414](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleEngine.swift:406).

   **Önerilen karar:** Koşul kaldırma, uyarısız `.ready` sonucuna ulaşmamalı. İfade korunamıyorsa `.unsupported` veya açıklama sorusu dönmeli; boş koşul listesi reddedilmeli.

6. **P2 — ADR 0003: Deterministik derleyici, vaat edilen şema doğrulamasını yapmıyor.**

   Derleyici eksik yüzdeyi `0`, eksik veya bozuk saatleri `00:00` yapıyor ve `.ready` öncesinde `RuleValidator` çağırmıyor. Böylece eksik `batteryAtOrAbove` eşiği her geçerli pil yüzdesinde doğru olabilir; eksik saat çifti tam gün penceresine dönüşebilir. `RuleValidator` da yüzde aralığını ve zorunlu koşul alanlarını doğrulamıyor.

   **Kanıt:** [ADR 0003:172](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:172), [ADR 0003:231](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:231), [RuleCompiler.swift:226–260](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleCompiler.swift:226), [RuleValidator.swift:19–77](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleValidator.swift:19).

   **Önerilen karar:** Eksik zorunlu alanlar davranış değiştiren varsayılanlarla doldurulmamalı. Üretilen şema ve derlenen kural doğrulanmadan `.ready` dönülmemeli.

7. **P2 — ADR 0003: Kapanış gecikmesi boyunca etki korunmuyor.**

   Koşul yanlış olunca motor `pendingInactive` durumuna geçiyor; fakat katkıları yalnız `.active` kurallardan topluyor. Termal kuralın 60 saniyelik kapanış gecikmesi başlamışken E-core isteği ilk değerlendirmede kalkıyor. Koşul süre dolmadan yeniden doğru olursa etki tekrar ekleniyor. ADR’nin gecikmeyle önlemek istediği açma-kapama davranışı gerçekleşiyor.

   **Kanıt:** [ADR 0003:136–145](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:136), [RuleEngine.swift:185–207](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleEngine.swift:185), [RuleEngine.swift:239](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleEngine.swift:239).

   **Önerilen karar:** `pendingInactive` boyunca düzey katkısı korunmalı; yalnız gerçek `inactive` geçişinde kaldırılmalı.

8. **P2 — ADR 0003: Birleşmiş E-core parametresi değişince mevcut gruba aktarılmıyor.**

   Mevcut grup için `ensureECore` yalnız helper ekliyor; grubun `params` değerini yenilemiyor. Önce `.keep` uygulanıp sonra başka katkı nedeniyle birleşim `.release` olursa, uygulama arka plandayken mevcut grup eski parametreyle kalır. Aktivasyon işleyicisi bu eski `.keep` değerini okuyarak politikayı kaldırmaz.

   **Kanıt:** [ADR 0003:158–166](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:158), [Governor.swift:261–263](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Governor.swift:261), [Governor.swift:654–658](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/Governor.swift:654), [ECoreLane.swift:43–52](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmGovernor/ECoreLane.swift:43).

   **Önerilen karar:** Her uzlaştırmada mevcut grubun parametreleri güncel birleşimden yenilenmeli; aktivasyonda geri alma bu güncel değere dayanmalı.

9. **P2 — ADR 0003: Uygulama adı çözümü belgelenen belirsizlik davranışını sağlamıyor.**

   Varsayılan çözücü çalışan ve kurulu uygulamaları taramak yerine sabit isim tablosunu kullanıyor. Bilinmeyen ad için tek, kimliksiz `AppRef` döndürüyor; derleyici tek aday gördüğü için açıklama sorusu üretmiyor. Ön plandaki uygulama koşullarında ise birden fazla adayın doğrudan ilki seçiliyor. Bu, yanlış veya hiç çalışmayacak hedefin onaya hazır görünmesine yol açıyor.

   **Kanıt:** [ADR 0003:310](/Users/ugurmac/Desktop/macbook/Docs/adr/0003-rule-dsl.md:310), [RuleCompiler.swift:27–43](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleCompiler.swift:27), [RuleCompiler.swift:118–133](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleCompiler.swift:118), [RuleCompiler.swift:250–255](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmRules/RuleCompiler.swift:250).

   **Önerilen karar:** Sabit tablo tek başına uygulama kimliği kanıtı sayılmamalı. Çözülemeyen ve çok adaylı adlar, hedeflerde ve koşullarda aynı açıklama yoluna gitmeli.

10. **P2 — ADR 0002: Dakika sınırını geçen enerji, tamamıyla bitiş dakikasına yazılıyor.**

    ADR süreyle orantılı bölme istiyor; `record` ise yalnız bitiş zamanından tek kova seçiyor. Uzun aralıkta enerji tüm süre üzerinden hesaplanırken kapsam 60 saniyeye kırpılıyor. Örneğin 120 saniyelik 1 W örneği, 120 J enerji ve 60 saniye kapsam olarak saklanıp 2 W referans güç üretebilir. Gece yarısını geçen normal tick de önceki günün enerjisini sonraki güne taşır.

    **Kanıt:** [ADR 0002:66–67](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:66), [EnergyLedger.swift:142–160](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:142).

    **Önerilen karar:** Ölçüm aralığı dakika sınırlarında bölünmeli; enerji ve kapsam aynı parçalarla dağıtılmalı. Kapsamı kırpıp enerjiyi korumak kullanılmamalı.

11. **P2 — ADR 0002: Bakım kesintisinden sonra özetlenmemiş geçmiş silinebiliyor.**

    ADR bitmiş bütün saatlerin özetlenmesini ve son üç saatin ayrıca yeniden hesaplanmasını istiyor. Kod başlangıcı doğrudan `max(minH, nowHour - 3)` yapıyor; `rolled_through_hour` değerini okumuyor. Üç saatten eski, henüz özetlenmemiş dakika verileri atlanıyor. Sonraki budamada bu veriler saatlik karşılığı olmadan silinebilir.

    **Kanıt:** [ADR 0002:236–239](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:236), [EnergyLedger.swift:347–365](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:347).

    **Önerilen karar:** Son tamamlanmış saatten itibaren eksikler önce özetlenmeli; son üç saat yeniden hesaplanmalı. Dakika verisi, saatlik karşılığı tamamlanmadan budanmamalı.

12. **P2 — ADR 0002: Fiş ve yedi günlük referans, yalnız 48 saat tutulan tablolardan okunuyor.**

    `receipt` uygulama ve sistem toplamlarında yalnız `*_1m` tablolarını kullanıyor. `P_ref` ve pil gerilimi de yedi günlük sınır koymasına rağmen yalnız bu tablolardan hesaplanıyor. Saatlik veri saklansa bile 48 saatten eski fiş görünmez; yedi günlük referans gerçekte en fazla kalan dakika verisini kapsar.

    **Kanıt:** [ADR 0002:229–242](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:229), [ADR 0002:263–265](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:263), [LedgerReader.swift:73–87](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:73), [LedgerReader.swift:169–197](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:169), [LedgerReader.swift:212–223](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:212).

    **Önerilen karar:** Eski dönemler saatlik, yeni dönemler dakikalık tablolardan çakışmadan okunmalı. Aynı birleşim `P_ref` için de kullanılmalı.

13. **P2 — ADR 0002: Karma fişte adaptör enerjisi pil dakikasına çevriliyor; yeterlilik sınırı uygulanmıyor.**

    `source == nil` olduğunda uygulamanın AC, pil ve bilinmeyen kaynak enerjileri birlikte toplanıyor. Pil referansı varsa bu toplam pil dakikası ve pil yüzdesine çevriliyor. Ayrıca referans için bir saat veya bugünden on dakika şartı yerine herhangi bir pozitif kapsam yeterli kabul edilmiş.

    **Kanıt:** [ADR 0002:258–273](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:258), [LedgerReader.swift:179–189](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:179), [LedgerReader.swift:218–222](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:218), [LedgerReader.swift:258–267](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:258).

    **Önerilen karar:** Karma fişte kaynaklar ayrı toplanmalı; yalnız pil enerjisi dakikaya/yüzdeye, AC enerjisi Wh sütununa gitmeli. Referansın süre şartları açıkça uygulanmalı.

14. **P2 — ADR 0002: V×I yedeği, SystemLoad ölçümü olarak kaydediliyor.**

    Örnekleyici V×I sonucunu `.batteryVI` kaynağıyla veriyor. Ledger ise `systemSource` değerine bakmadan her `systemLoad` watt değerini `sysloadUj` içine koyuyor. Flush bu kovayı `sys_src = 0` seçiyor. Böylece yedek kaynak kullanımı SystemLoad gibi görünür; belgelenen kaynak açıklaması yanlış olur.

    **Kanıt:** [ADR 0002:246–255](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:246), [BatterySampler.swift:124–128](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmSampling/BatterySampler.swift:124), [EnergyLedger.swift:153–160](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:153), [EnergyLedger.swift:281–288](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:281).

    **Önerilen karar:** Enerji, taşıdığı kaynak kimliğine göre ham alana kaydedilmeli; etkin kaynak bu ayrım korunarak seçilmeli.

15. **P2 — ADR 0002: Okunamayan süreç tahmini, okunabilen CPU enerjisini çıkarmıyor.**

    Şema aynı patlama penceresinin okunabilen CPU toplamını istiyor. Ledger her patlama için `readable_cpu_uj: 0` yazıyor. Okuyucu bu sıfırı CPU toplamından çıkararak okunabilir süreçlerin enerjisini de “okunamayan sistem” tahminine katıyor. Sonuç “Diğer” satırından “Sistem” satırına yanlış enerji aktarılmasıdır.

    **Kanıt:** [ADR 0002:189–190](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:189), [ADR 0002:283–286](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:283), [EnergyLedger.swift:222–229](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:222), [LedgerReader.swift:128–145](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:128).

    **Önerilen karar:** Okunabilir CPU enerjisi aynı patlama penceresinde biriktirilmeli. Bu değer mevcut değilse sıfır varsaymak yerine tahmin gösterilmemeli.

16. **P2 — ADR 0002: Kenara alınan veritabanı, WAL içindeki kayıtları korumuyor.**

    Sürüm düşürme veya bozulma yolunda yalnız ana dosya taşınıyor; `-wal` ve `-shm` siliniyor. Ana dosyanın taşınma hatası da yutuluyor. Başka bir okuyucu bağlantısı açıkken WAL henüz checkpoint edilmemiş commit’ler taşıyabilir; yalnız ana dosyanın yedeği bu kayıtları içermez. SQLite, WAL’ın veritabanının kalıcı durumunun parçası olduğunu açıklıyor. [SQLite WAL belgesi](https://sqlite.org/wal.html).

    **Kanıt:** [ADR 0002:327–328](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:327), [EnergyLedger.swift:131–137](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/EnergyLedger.swift:131).

    **Önerilen karar:** Yedekleme, veritabanı ve WAL durumunu birlikte korumalı. Yedek başarıyla oluşturulmadan yan dosyalar silinmemeli ve yeni veritabanına geçilmemeli.

17. **P2 — ADR 0001: Sınırsız `AsyncStream`, iddia edilen geri basıncı sağlamıyor.**

    ADR, tüketicinin `ledger.record` çağrısını beklemesini doğal geri basınç olarak tanımlıyor. Ancak üretici bağımsız döngüde çalışıp `.unbounded` akışa senkron `yield` yapıyor; tüketicinin ilerlemesini beklemiyor. Ledger yavaşlar veya tüketim durursa bekleyen tick’ler sınırsız büyür. Bu, hafiflik bütçesi ve kayıpsız aktarım gerekçesini geçersiz kılıyor.

    **Kanıt:** [ADR 0001:186](/Users/ugurmac/Desktop/macbook/Docs/adr/0001-modules-and-concurrency.md:186), [ADR 0001:206](/Users/ugurmac/Desktop/macbook/Docs/adr/0001-modules-and-concurrency.md:206), [SamplingEngine.swift:85](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmSampling/SamplingEngine.swift:85), [SamplingEngine.swift:149](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmSampling/SamplingEngine.swift:149), [SamplingEngine.swift:180–185](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmSampling/SamplingEngine.swift:180).

    **Önerilen karar:** Üreticinin tüketiciyi beklediği aktarım veya enerji toplamlarını koruyan sınırlı biriktirme seçilmeli. Sınırsız tampon, geri basınç olarak kabul edilmemeli.

18. **P2 — ADR 0002: GPU için aynı belgede iki farklı geçerli karar bulunuyor.**

    Formül ve tablo GPU’yu yalnız bilgi satırı kabul ediyor. T-021 sonucu ise GPU’nun süreç enerjisine dahil olmadığını kaydedip ayrı toplam satırına alınmasını kararlaştırıyor. Kod hâlâ `other = R − S` kullanıyor; GPU’yu kalandan çıkarmıyor. Dolayısıyla ölçüm sonucu, normatif formül ve uygulama aynı kararı temsil etmiyor.

    **Kanıt:** [ADR 0002:286–302](/Users/ugurmac/Desktop/macbook/Docs/adr/0002-energy-ledger-schema.md:286), [spikes/README.md:139](/Users/ugurmac/Desktop/macbook/spikes/README.md:139), [LedgerReader.swift:154–156](/Users/ugurmac/Desktop/macbook/app/OhmCore/Sources/OhmLedger/LedgerReader.swift:154).

    **Önerilen karar:** Tek geçerli GPU muhasebesi seçilmeli. Ölçülen M3/macOS 27 kapsamıyla sınırlı ayrı toplam kararı uygulanacaksa formül, korunum ve ölçüm kapsamı birlikte tanımlanmalı; diğer cihazlara bu sonuç doğrulanmadan genellenmemeli.


