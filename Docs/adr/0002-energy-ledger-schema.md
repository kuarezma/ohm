# ADR 0002: Enerji defteri (ledger) şeması, atıf ve pil dakikası

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü bekleniyor.
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0001 (tek yazar, okuyucular, `SampleTick`), T-022 (uygulama), T-033 (widget ve CLI), T-041 (tahmin)

## Bağlam

Ohm'un ana vaadi "pil fişi": uygulama başına enerji, "pil dakikası" ve "pil yüzdesi" olarak gösteriliyor. Bunun için dört sorunun cevabı gerekiyor:

1. **Neye atfedilir?** Bir pid geçicidir. Süreç adı belirsizdir (`python3` iki ayrı araç olabilir). Chrome tek bir uygulama olarak görünür ama arkasında onlarca `Google Chrome Helper (Renderer)` süreci çalışır. Safari'nin sayfaları `com.apple.WebKit.WebContent` XPC süreçlerinde çalışır ve bu süreçlerin yolu Safari paketinin dışındadır.
2. **Nasıl saklanır?** Hafiflik bütçesi (ADR 0001) dakikada bir tek yazma işlemi öngörüyor. Widget ve CLI aynı veriyi salt okunur açıyor.
3. **Pil dakikası nedir?** Joule ölçülür, ama kullanıcı dakika görmek istiyor. Dönüşümün dürüst bir tanımı gerekiyor.
4. **Neye atfedilemez?** Ekran, radyolar, SSD ve platformun boştaki gücü hiçbir sürece ait değil. Plan bunları "Diğer (ekran, radyo)" satırında göstermeyi öngörüyor.

Kaynak olgular (SDK başlığından doğrulandı): `RUSAGE_INFO_CURRENT == RUSAGE_INFO_V6`; `struct rusage_info_v6` içinde `ri_energy_nj`, `ri_penergy_nj` (P-core payı), `ri_proc_start_abstime` ve `ri_user_time`/`ri_system_time` alanları var. `responsibility_get_pid_responsible_for_pid` başlıkta yok ama `libquarantine.dylib`'den export ediliyor ve bu makinede (macOS 27.0) çalışıyor. Bu fonksiyon özel SPI, bu yüzden `dlsym` ile opsiyonel olarak yüklenir.

## Karar

### 1. Atıf (attribution)

Kalıcı anahtar `AppKey(kind, value)`:

| `kind` | Değer | Ne zaman |
|---|---|---|
| `0` bundleID | `CFBundleIdentifier` (ör. `com.google.Chrome`) | Süreç bir `.app` paketine atfedilebiliyorsa |
| `1` executableName | Yürütülebilir dosyanın adı (ör. `node`) | Paketsiz ikili dosya. Homebrew'in sürüm numaralı yolları (`Cellar/node/22.1/...`) sürümler arasında tek satırda toplansın diye ad kullanılır. |
| `2` processName | `proc_name(pid)` | Yol okunamıyor (başka bir kullanıcının süreci vb.) |

pid anahtar olarak **kullanılmaz**, yalnız çalışma anındaki önbellekte `ProcessIdentity(pid, start)` olarak tutulur.

Çözüm algoritması (`AttributionResolver`, sonucu `ProcessIdentity` başına önbellekte tutulur):

```
resolve(pid):
  path ← proc_pidpath(pid)                        // başarısızsa → (processName, proc_name(pid))
  own  ← outermostApp(path)                       // yol bileşenlerinden ".app" ile BİTEN ilki
  r    ← responsiblePID(pid)                      // SPI yoksa veya hata verirse r ← pid
  if r ≠ pid ∧ alive(r):
      rApp ← outermostApp(proc_pidpath(r))
      if rApp ≠ nil ∧ (own = rApp                 // paket içi helper: Chrome Helper → Chrome
                       ∨ isServiceOrExtension(path)):   // yolda ".xpc/" veya ".appex/": WebContent → Safari
          return bundleKey(rApp)
  if own ≠ nil: return bundleKey(own)
  return (executableName, lastPathComponent(path))
```

- **`outermostApp`** en dıştaki paketi seçer. Chrome'un iç içe `Google Chrome Helper (Renderer).app` paketi, sorumlu pid bilgisi olmasa bile `/Applications/Google Chrome.app`'e toplanır.
- **Terminal'den başlatılan `node` veya `cargo` Terminal'e yazılmaz.** Sorumlu pid'leri Terminal olsa bile bu süreçler paket içinde değil ve XPC servisi değil; kendi satırlarını alırlar. Kullanıcının görmek istediği "node yedi" bilgisidir, "Terminal yedi" değil.
- **`bundleKey(appPath)`:** Paketin `Info.plist` dosyasındaki `CFBundleIdentifier` değeri. Bu değer yoksa `CFBundleExecutable` ile `kind = 1` kullanılır.
- **`app.category`:** Yolu `/System/`, `/usr/`, `/Library/Apple/` altında olan veya bundle ID'si `com.apple.` ile başlayan ama kullanıcının açtığı normal bir uygulama olmayan süreçler `category = 1` (macOS hizmetleri) alır. Arayüz bunları varsayılan olarak tek bir "macOS hizmetleri" satırında toplar ve satır açılabilir.
- **Bilinen sınır:** Terminal'den çalıştırılan ve `Xcode.app` içinde duran araç zinciri ikilileri (`swift-frontend`) Xcode'a yazılır. v1'de bu kabul edildi.

### 2. Sayaçtan deltaya

- Delta, aynı `ProcessIdentity` için iki okuma arasındaki farktır. Bir kimlik ilk kez görüldüğünde iki durum var:
  - Süreç bir önceki tick'ten **sonra** başlamışsa (`start ≥ önceki tick`), sayacın tamamı bu aralığa yazılır.
  - Aksi halde (Ohm yeni açıldı veya `suspended` durumdan dönüldü) yalnız taban çizgisi alınır ve delta 0 olur. Ohm'dan önceki enerji bugüne yazılmaz.
- Sayaç geriye giderse (beklenmez) delta 0 alınır, taban çizgisi yenilenir ve olay loglanır.
- Tick aralığı bir dakika sınırını geçiyorsa delta iki dakikaya süreyle orantılı bölünür.
- Aralıklar monotonik saatle ölçülür. Dakika anahtarı duvar saatinden hesaplanır (`t_min = floor(unix_sn / 60)`, UTC). Saat geri atlarsa aynı dakikaya ikinci yazma `UPSERT` ile toplanır.
- `EnergyLedger` tick'leri bellekte dakika kovalarında toplar ve dakika sınırında **tek transaction** ile yazar. Çökmede en fazla 1 dakikalık veri kaybolur.
- **Eşik:** Bir dakikada 1 mJ'den (1000 µJ) az harcayan uygulama için satır yazılmaz. Enerjisi `system_1m.tail_uj` alanına eklenir. Böylece seyrek tablo korunur ve toplamlar yine tutar.

### 3. Şema (v1, DDL)

Birim: **mikrojoule (µJ), `INTEGER`**. 1 W × 60 sn = 6·10⁷ µJ. `INTEGER` (int64) taşma riski yok. Zaman: UTC unix dakikası ve saati.

```sql
-- Veritabanı oluşturulurken, ilk tablodan ÖNCE:
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA journal_mode = WAL;
-- Her bağlantıda (yazar):
PRAGMA synchronous = NORMAL;      -- WAL'da commit başına fsync yok; çökmede son commit'ler kaybolabilir, bozulma olmaz
PRAGMA foreign_keys = ON;
PRAGMA cache_size = -512;         -- 512 KB

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;
-- anahtarlar: 'reader_compat' (bu DB'yi okuyabilecek en düşük okuyucu şema sürümü),
--            'rolled_through_hour' (son rollup yapılan saat), 'created_at'

CREATE TABLE app (
  id           INTEGER PRIMARY KEY,
  kind         INTEGER NOT NULL CHECK (kind IN (0, 1, 2)),  -- 0 bundleID, 1 executableName, 2 processName
  key          TEXT    NOT NULL,
  display_name TEXT    NOT NULL,
  bundle_path  TEXT,                                        -- son görülen .app yolu (ikon için); paketsizse NULL
  category     INTEGER NOT NULL DEFAULT 0 CHECK (category IN (0, 1)),  -- 0 kullanıcı uygulaması, 1 macOS hizmeti
  first_seen   INTEGER NOT NULL,                            -- unix sn
  last_seen    INTEGER NOT NULL,
  UNIQUE (kind, key)
) STRICT;

-- Uygulama başına dakikalık dilim. Satır yalnız energy_uj ≥ 1000 ise yazılır.
CREATE TABLE slice_1m (
  t_min      INTEGER NOT NULL,                              -- floor(unix_sn / 60)
  app_id     INTEGER NOT NULL REFERENCES app(id),
  source     INTEGER NOT NULL CHECK (source IN (0, 1, 2)),  -- 0 AC, 1 pil, 2 bilinmiyor
  energy_uj  INTEGER NOT NULL CHECK (energy_uj  >= 0),      -- Σ Δri_energy_nj / 1000
  penergy_uj INTEGER NOT NULL CHECK (penergy_uj >= 0),      -- Σ Δri_penergy_nj / 1000 (P-core payı)
  cpu_ms     INTEGER NOT NULL CHECK (cpu_ms     >= 0),      -- Σ Δ(ri_user_time + ri_system_time)
  PRIMARY KEY (t_min, app_id, source)
) STRICT, WITHOUT ROWID;

-- Sistem düzeyi dakikalık dilim (dakika içinde güç kaynağı değişirse kaynak başına bir satır).
CREATE TABLE system_1m (
  t_min            INTEGER NOT NULL,
  source           INTEGER NOT NULL CHECK (source IN (0, 1, 2)),
  covered_ms       INTEGER NOT NULL CHECK (covered_ms BETWEEN 0 AND 60000),  -- örneklerin kapsadığı süre
  battery_uj       INTEGER,        -- ∫ V·I dt, yalnız pildeyken; ölçüm yoksa NULL
  cpu_p_uj         INTEGER,        -- IOReport (T-010); yoksa NULL
  cpu_e_uj         INTEGER,
  gpu_uj           INTEGER,
  ane_uj           INTEGER,
  dram_uj          INTEGER,
  attributed_uj    INTEGER NOT NULL,   -- bu (t_min, source) için Σ slice_1m.energy_uj
  tail_uj          INTEGER NOT NULL,   -- eşik altı uygulamaların toplamı (satırı yazılmayanlar)
  unreadable_count INTEGER NOT NULL,   -- enerjisi okunamayan süreç sayısı (dakikanın son tick'i)
  battery_pct      INTEGER,            -- dakika sonu, IOPS yüzdesi
  voltage_mv       INTEGER,            -- dakika ortalaması
  raw_charge_mah   INTEGER,            -- AppleRawCurrentCapacity (coulomb sayacı), dakika sonu
  fcc_mah          INTEGER,            -- FullChargeCapacity (sağlık düzeltmeli)
  thermal_max      INTEGER,            -- dakikadaki en yüksek ThermalLevel
  PRIMARY KEY (t_min, source)
) STRICT, WITHOUT ROWID;

-- Saatlik rollup (90 gün).
CREATE TABLE slice_1h (
  t_hour     INTEGER NOT NULL,                              -- floor(unix_sn / 3600)
  app_id     INTEGER NOT NULL REFERENCES app(id),
  source     INTEGER NOT NULL,
  energy_uj  INTEGER NOT NULL,
  penergy_uj INTEGER NOT NULL,
  cpu_ms     INTEGER NOT NULL,
  PRIMARY KEY (t_hour, app_id, source)
) STRICT, WITHOUT ROWID;
CREATE INDEX slice_1h_by_app ON slice_1h (app_id, t_hour);  -- uygulama detay grafiği

CREATE TABLE system_1h (
  t_hour         INTEGER NOT NULL,
  source         INTEGER NOT NULL,
  covered_ms     INTEGER NOT NULL,
  battery_uj     INTEGER,
  battery_cov_ms INTEGER NOT NULL,     -- battery_uj'nin gerçekten ölçüldüğü süre (NULL'lar hariç)
  cpu_p_uj INTEGER, cpu_e_uj INTEGER, gpu_uj INTEGER, ane_uj INTEGER, dram_uj INTEGER,
  attributed_uj  INTEGER NOT NULL,
  tail_uj        INTEGER NOT NULL,
  charge_used_mah INTEGER,             -- saat içindeki pil serilerinde Σ max(0, Δraw_charge_mah)
  voltage_mv_avg INTEGER,
  fcc_mah        INTEGER,              -- saat sonundaki değer
  thermal_max    INTEGER,
  PRIMARY KEY (t_hour, source)
) STRICT, WITHOUT ROWID;

-- Örnekleme boşlukları (arayüzde "veri yok" gölgesi; covered_ms'i açıklar).
CREATE TABLE sampling_gap (
  start_s INTEGER NOT NULL,
  end_s   INTEGER NOT NULL CHECK (end_s >= start_s),
  reason  TEXT NOT NULL CHECK (reason IN ('sleep', 'suspended', 'not_running', 'clock_jump')),
  PRIMARY KEY (start_s, reason)
) STRICT, WITHOUT ROWID;

PRAGMA user_version = 1;
```

Yazma örneği (dakika flush'ı, transaction içinde):

```sql
INSERT INTO slice_1m (t_min, app_id, source, energy_uj, penergy_uj, cpu_ms)
VALUES (:t, :app, :src, :e, :pe, :cpu)
ON CONFLICT (t_min, app_id, source) DO UPDATE SET
  energy_uj  = energy_uj  + excluded.energy_uj,
  penergy_uj = penergy_uj + excluded.penergy_uj,
  cpu_ms     = cpu_ms     + excluded.cpu_ms;
```

Bugünün fişi (1 dakikalık dilimler 48 saat tutulduğu için "bugün" ve "dün" yerel gün sınırlarıyla kesin hesaplanır):

```sql
SELECT a.kind, a.key, a.display_name, a.category,
       SUM(s.energy_uj) AS energy_uj, SUM(s.penergy_uj) AS penergy_uj
FROM slice_1m AS s JOIN app AS a ON a.id = s.app_id
WHERE s.t_min >= :local_midnight_min AND s.t_min < :now_min AND s.source = 1
GROUP BY s.app_id
ORDER BY energy_uj DESC;
```

### 4. Saklama ve rollup

| Tablo | Saklama | Tahmini boyut |
|---|---|---|
| `slice_1m`, `system_1m` | 48 saat | Dakikada ~40 aktif uygulama × 2880 ≈ 115 bin satır, ~4 MB |
| `slice_1h`, `system_1h` | 90 gün | ~60 uygulama × 24 × 90 ≈ 130 bin satır, ~5 MB |
| `sampling_gap` | 90 gün | Önemsiz |
| `app` | Referansı kalmayan ve `last_seen` > 90 gün olan satır silinir | Önemsiz |

`EnergyLedger.maintain(now:)` açılışta ve her saat başından 5 dk sonra `.background` QoS ile çalışır. Adımlar tek transaction içindedir:

1. **Rollup:** Bitmiş her saat için `slice_1h` ve `system_1h` hesaplanır. Hesap, o saatin bütün `*_1m` satırlarından baştan yapılır (`INSERT … ON CONFLICT DO UPDATE SET … = excluded.…`, yani toplama değil değiştirme). Bu yüzden işlem idempotent'tir. Geç gelen veriye karşı her çalışmada son 3 saat yeniden hesaplanır. `meta.rolled_through_hour` güncellenir.
2. **Budama:** `DELETE FROM slice_1m WHERE t_min < :now_min - 2880` (birincil anahtar `t_min` ile başladığı için aralık silmesi ucuz). Aynı işlem `system_1m` için yapılır. Saatlik tablolar ve boşluklar için sınır 90 gündür.
3. **Alan geri kazanma:** `PRAGMA incremental_vacuum(256)` ve `PRAGMA wal_checkpoint(PASSIVE)`.

**Saat dilimi:** Saatlik kovalar UTC'dir. 48 saatten eski geçmişte gün sınırı yerel saate göre saatlik kovalardan kurulur. Yarım veya çeyrek saatlik ofset kullanan bölgelerde (ör. UTC+5:30, +5:45) bu, eski günlerde ±30/45 dakikalık sınır hatası demektir. Bugünün ve dünün fişi bu hatadan etkilenmez.

### 5. Pil dakikası ve pil yüzdesi

Tanımlar (yalnız **pildeyken**, `source = 1` harcanan enerji için):

```
E_app       = Σ energy_uj(app, aralık, source=1) · 10⁻⁶                        [J]
E_full      = fcc_mah · V̄ · 3.6                                                 [J]   (1 mAh × 1 V = 3.6 J)
              V̄ = pildeyken ortalama gerilim (V), son 7 gün
P_ref       = E_batt(son 7 gün, pilde) / T_batt(son 7 gün, pilde)               [W]
              E_batt: coulomb sayacından Σ charge_used_mah · V̄ · 3.6 (varsa),
                      yoksa Σ battery_uj · 10⁻⁶
              T_batt: aynı ölçümün kapsadığı süre (battery_cov_ms)
pil_yüzdesi = 100 · E_app / E_full
pil_dakikası = E_app / P_ref / 60
```

- **Anlamı:** "Bu uygulamanın pildeyken harcadığı enerji, senin tipik kullanımında X dakikalık pile denk." Eşdeğeri: `pil_yüzdesi × (tam pilin tipik ömrü)`.
- **`P_ref` için yeterlilik:** Son 7 günde en az 1 saatlik pil ölçümü olmalı. Yoksa bugünün pil ölçümü kullanılır (en az 10 dk). O da yoksa dakika gösterilmez; yalnız yüzde ve Wh gösterilir.
- **Şarjdayken** harcanan enerji pil dakikasına çevrilmez. Fişte ayrı bir "şarjdayken: X Wh" sütunu olarak gösterilir.
- **"Diğer (ekran, radyo)" satırı**, fiş aralığının tamamı üzerinden hesaplanır. Dakika başına hesaplanıp sonra kırpılmaz; böylece örnekleme zamanlaması kaynaklı kaymalar birbirini götürür:
  ```
  Diğer = max(0, Σ battery_uj − Σ (attributed_uj + tail_uj))   yalnız battery_uj IS NOT NULL olan dakikalar
  ```
  Toplam, tanım gereği ölçülen pil enerjisine eşittir: uygulamalar + eşik altı + Diğer = pil.
- **IOReport varsa (T-010)** detay görünümü "Diğer" satırını ikiye ayırır. Birinci parça ekran, radyo ve platform: `battery − (cpu_p + cpu_e + gpu + ane + dram)`. İkinci parça atfedilemeyen işlem gücü (sistem, kısa ömürlü ve okunamayan süreçler): `(cpu_p + cpu_e + gpu + ane) − (attributed + tail)`.
- **Tutarsızlık bayrağı:** Bir aralıkta `Σ(attributed + tail) > Σ battery · 1.05` ise, atfedilen enerji ölçülen pil enerjisinden fazla demektir. Bu durumda arayüz "ölçüm tutarsız" uyarısı gösterir ve Diğer satırı 0 yazılmak yerine gizlenir. Bu, T-011 modelinin gerçek dünyada sapmasını görünür kılar.

### 6. Dürüst sınırlar (arayüzdeki "bu sayı ne demek?" metninin kaynağı)

1. `ri_energy_nj` bir **model tahminidir** (çekirdeğin enerji modeli), doğrudan ölçüm değildir. CPU'yu kapsar. GPU'yu kapsayıp kapsamadığını T-011 belirleyecek.
2. Ekran, Wi-Fi, Bluetooth, SSD, hoparlör, platformun boştaki gücü ve dönüştürme kayıpları **hiçbir uygulamaya atfedilemez**. Bunlar "Diğer" satırına gider. Bir uygulamanın ekranı açık tutması ya da ağı meşgul etmesi fişte görünmez.
3. İki örnek arasında doğup ölen süreçlerin enerjisi kaybolur ve "Diğer"e düşer. Popover kapalıyken bu pencere 10 sn'dir. Uzun ömürlü bir süreç öldüğünde de son aralığı kaybolur.
4. Root ve başka kullanıcıların süreçleri okunamaz (sayı `unreadable_count` ile gösterilir). Bunların enerjisi de "Diğer"e gider. WindowServer, uygulamalar adına ekran birleştirme (compositing) işi yapar ama root süreç olduğu için bu maliyet de "Diğer"dedir.
5. **"Harcadı" ile "kapatırsan kazanırsın" aynı şey değildir.** Platformun boştaki gücü uygulama kapansa da harcanır. Arayüz "yedi" fiilini kullanır, "kazandırır" vaadi vermez. E-core tasarruf tahminleri ayrıca "tahmini" etiketi taşır.
6. **Dakika kullanıcıya göre ölçeklenir.** Aynı joule, hafif kullanan birinde daha çok dakikaya denk gelir. Yüzde ise kullanımdan bağımsızdır. Arayüz her ikisini de gösterir.
7. **Ohm'un yüzdesi macOS'un yüzdesiyle aynı olmayabilir.** macOS'un pil yüzdesi yumuşatılmış ve doğrusal olmayan bir göstergedir. Ohm'un yüzdesi enerji tabanlıdır ve tam kapasiteye (FCC, sağlık düzeltmeli) göre hesaplanır.

### 7. Migration'lar

- Sürüm `PRAGMA user_version` ile tutulur. Migration'lar Swift içinde sıralı bir dizidir: `[Migration(version: Int, sql: String)]`. Her biri `BEGIN IMMEDIATE … COMMIT` içinde, yalnız yazar (`OhmApp`) tarafından uygulanır.
- **Yalnız ekleme politikası:** Yeni tablo veya NULL olabilen yeni sütun eklemek `reader_compat` değerini değiştirmez. Böylece eski widget veya CLI yeni veritabanını okumaya devam eder. Sütun silmek, yeniden adlandırmak veya anlamını değiştirmek `reader_compat` değerini yükseltir.
- **Okuyucu kuralı:** `LedgerReader` önce `reader_compat ≤ bildiğiSürüm` kontrolü yapar. Değer daha yüksekse "Ohm'u güncelleyin" döner ve çökmez. `user_version = 0` ise veritabanı boş kabul edilir.
- **Sürüm düşürme:** Yazar kendi bildiğinden yüksek bir `user_version` görürse veritabanını açmaz. Dosyayı `ledger.sqlite.v<N>.bak` olarak kenara taşır ve yeni bir veritabanı başlatır.
- **Bozulma:** Açılışta `PRAGMA quick_check` başarısız olursa aynı işlem uygulanır (kenara taşı, yeniden oluştur). Ledger türetilmiş ölçüm verisidir, kullanıcı belgesi değildir. Kaybı kabul edilebilir, uygulamanın açılmaması kabul edilemez.
- T-041 (tahmin) ek özellik tabloları gerektirirse bunlar `version 2` migration'ı olarak eklenir.

## Alternatifler

1. **pid veya süreç adıyla anahtarlama.** Reddedildi. pid yeniden başlatmada ve uygulama yeniden açıldığında değişir, bu yüzden günlük toplam kurulamaz. Süreç adı ise Chrome'un helper'larını ayrı satırlara böler.
2. **Yalnız sorumlu pid ile atıf.** Reddedildi. Terminal'den çalıştırılan her şey Terminal'e yazılır ve kaçak `node` görünmez olur. Ayrıca SPI kaybolursa bütün atıf çöker. Önerilen algoritma paket yolunu birincil, SPI'yi tamamlayıcı kullanır.
3. **Her tick'i ham olarak saklamak (10 sn ve 1 sn).** Reddedildi. Hacim 6–60 kat artar, dakikalık çözünürlükten fazlasına hiçbir görünüm ihtiyaç duymuyor ve her tick'te yazmak diski uyandırır.
4. **Saatlik kovaları yerel saatle tutmak.** Reddedildi. Yaz saati geçişlerinde (DST) belirsiz ve tekrar eden saatler oluşur. UTC ve 48 saatlik kesin dakika penceresi daha basit.
5. **Pil dakikası = E_app / anlık sistem gücü.** Reddedildi. O anki yük değiştikçe aynı joule farklı dakika gösterir ve fiş kendi kendine oynar. 7 günlük ortalama sabit ve açıklanabilir.
6. **"Diğer" satırını hiç göstermemek.** Reddedildi. Planın dürüstlük notuna aykırı. Kullanıcı fişin toplamının pil düşüşünü açıklamadığını görür ve ölçüme güvenmez.

## Sonuçlar ve riskler

- **(+)** Fişin toplamı ölçülen pil enerjisine eşittir. Bilinmeyen kısım saklanmaz, adıyla gösterilir.
- **(+)** Tüm hesap SQL ve saf Swift'tir. T-022 donanım olmadan, sabit test verisiyle doğrulanabilir.
- **(−)** Responsibility SPI özel bir API'dir. macOS güncellemesiyle kaybolabilir. Kaybolursa paket yolu kuralı yine çalışır. Yalnız paket dışı XPC servisleri (WebKit WebContent) kendi satırlarına düşer ve Safari'nin fişi eksik görünür.
- **Risk:** `V × I` tick anlarında alınan nokta örnekleridir, dakika içi ani yükleri kaçırabilir. `P_ref` bu yüzden coulomb sayacını tercih eder. Dakikalık "Diğer" hesabı ise aralık toplamı üzerinden yapılır, tek tek dakikalar üzerinden yapılmaz.
- **Risk:** Bir dakikada 1 mJ eşiği, çok sayıda küçük sürecin enerjisini `tail_uj` alanına taşır. Bu enerji fişte "küçük süreçler" olarak ayrıca gösterilebilir.

## Spike'a bağlı

- **T-011:** `ri_energy_nj`'nin GPU'yu kapsayıp kapsamadığı. Kapsıyorsa ek iş yok. Kapsamıyorsa GPU enerjisi "atfedilemeyen işlem gücü" olarak kalır ve arayüz metni "CPU enerjisi" diye düzeltilir.
- **T-011:** Atıf algoritmasının Chrome, Safari ve bir Electron uygulaması üzerinde beklenen gruplamayı verip vermediği (spike, `responsiblePID` ve `outermostApp` sonuçlarını karşılaştırarak basmalı). Geçmezse `ppid` zinciri ile paket yolu birlikte kullanılır.
- **T-011:** Okunamayan süreç sayısı. Sayı yüksekse (ör. %30'dan fazla enerji okunamıyorsa) "Diğer" satırı büyür ve arayüz metni buna göre yazılır.
- **T-010:** IOReport varsa `cpu_*`, `gpu_uj`, `ane_uj` ve `dram_uj` sütunları dolar ve "Diğer" satırı ikiye bölünür. Yoksa bu sütunlar NULL kalır; şema değişmez.
- **T-010 (pil okuması):** `AppleRawCurrentCapacity` alanının pilde en az dakikalık çözünürlükle güncellenip güncellenmediği. Güncellenmiyorsa `P_ref` yalnız `∫ V·I` ile hesaplanır.
