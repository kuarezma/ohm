# ADR 0002: Enerji defteri (ledger) şeması, atıf ve pil dakikası

- **Durum:** Önerildi (T-001). Şef review'u ve T-001b ikinci görüşü bekleniyor. Faz 0 spike sonuçları işlendi (`spikes/README.md`, `main` 5773b60).
- **Tarih:** 2026-09-29
- **İlgili:** ADR 0001 (tek yazar, okuyucular, `SampleTick`), T-022 (uygulama), T-033 (widget ve CLI), T-041 (tahmin)

## Bağlam

Ohm'un ana vaadi "pil fişi": uygulama başına enerji, "pil dakikası" ve "pil yüzdesi" olarak gösteriliyor. Bunun için dört sorunun cevabı gerekiyor:

1. **Neye atfedilir?** Bir pid geçicidir. Süreç adı belirsizdir (`python3` iki ayrı araç olabilir). Chrome tek bir uygulama olarak görünür ama arkasında onlarca `Google Chrome Helper (Renderer)` süreci çalışır. Safari'nin sayfaları `com.apple.WebKit.WebContent` XPC süreçlerinde çalışır ve bu süreçlerin yolu Safari paketinin dışındadır.
2. **Nasıl saklanır?** Hafiflik bütçesi (ADR 0001) dakikada bir tek yazma işlemi öngörüyor. Widget ve CLI aynı veriyi salt okunur açıyor.
3. **Pil dakikası nedir?** Joule ölçülür, ama kullanıcı dakika görmek istiyor. Dönüşümün dürüst bir tanımı gerekiyor.
4. **Neye atfedilemez?** Ekran, radyolar, SSD ve platformun boştaki gücü hiçbir sürece ait değil. Plan bunları "Diğer (ekran, radyo)" satırında göstermeyi öngörüyor.

Kaynak olgular (SDK başlığından doğrulandı): `RUSAGE_INFO_CURRENT == RUSAGE_INFO_V6`; `struct rusage_info_v6` içinde `ri_energy_nj`, `ri_penergy_nj` (P-core payı), `ri_proc_start_abstime` ve `ri_user_time`/`ri_system_time` alanları var. `responsibility_get_pid_responsible_for_pid` başlıkta yok ama `libquarantine.dylib`'den export ediliyor ve bu makinede (macOS 27.0) çalışıyor. Bu fonksiyon özel SPI, bu yüzden `dlsym` ile opsiyonel olarak yüklenir.

Faz 0 ölçümleri (M3, macOS 27, sudo yok):
- **T-011 PASS:** Sayaçlar aynı kullanıcının süreçleri için çalışıyor. `yes` = 4,35 W, `P_share` 1,00. 668 pid'in 268'i (~%40) `EPERM` döndürüyor; bunlar root ve başka kullanıcıların süreçleri. CPU zamanı alanları mach tick cinsinden.
- **T-010 PARTIAL:** IOReport CPU, DRAM ve ANE enerji sayaçları saniyelik güncellenmiyor, yalnız seyrek patlamalar halinde geliyor. `GPU Energy` (nJ) saniyelik canlı. Sistem gücü `PowerTelemetryData.SystemLoad` ile pilde ve adaptörde okunabiliyor (boşta 3,8 W, tek `yes` ile 7,4 W) ve ~20 sn'de bir güncelleniyor. `Voltage × Amperage` yalnız deşarjda sistem gücüdür; adaptörde şarj gücünü gösterir.

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
- Kimlik `ProcessIdentity(pid, ri_proc_start_abstime)` olarak tutulur; spike'ta kullanılan yöntem budur. Başlangıç zamanı, enerjiyle aynı `proc_pid_rusage` çağrısından gelir ve ek sistem çağrısı gerektirmez.
- `ri_user_time` ve `ri_system_time` mach tick cinsindendir. `cpu_ms`'e `mach_timebase_info` ile çevrilir.
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
  -- Ham ölçümler (tanı ve çapraz kontrol için; fiş bunları doğrudan KULLANMAZ):
  sysload_uj       INTEGER,        -- ∫ PowerTelemetryData.SystemLoad dt (basamak fonksiyonu); pilde ve AC'de; yoksa NULL
  sysload_cov_ms   INTEGER NOT NULL DEFAULT 0,  -- sysload_uj'nin gerçekten ölçüldüğü süre
  batt_vi_uj       INTEGER,        -- ∫ V·I dt, yalnız deşarjda; yoksa NULL
  batt_vi_cov_ms   INTEGER NOT NULL DEFAULT 0,  -- batt_vi_uj'nin gerçekten ölçüldüğü süre
  -- Etkin sistem enerjisi (§ 5): fiş satırları ve P_ref YALNIZ bunu kullanır.
  sys_src          INTEGER NOT NULL CHECK (sys_src IN (0, 1, 2)),  -- 0 SystemLoad, 1 V·I (deşarj), 2 yok
  sys_uj           INTEGER,        -- seçilen kaynağın enerjisi; sys_src = 2 ise NULL
  sys_cov_ms       INTEGER NOT NULL DEFAULT 0,  -- seçilen kaynağın kapsadığı süre
  att_cov_uj       INTEGER NOT NULL DEFAULT 0,  -- attributed_uj + tail_uj'nin sys_cov_ms içine düşen kısmı
  gpu_uj           INTEGER,        -- IOReport "GPU Energy" (nJ, canlı) / 1000; ayrı toplam satırı (§ 5; M3/macOS 27 ölçümü)
  attributed_uj    INTEGER NOT NULL,   -- bu (t_min, source) için Σ slice_1m.energy_uj
  tail_uj          INTEGER NOT NULL,   -- eşik altı uygulamaların toplamı (satırı yazılmayanlar)
  residual_uj      INTEGER GENERATED ALWAYS AS (sys_uj - att_cov_uj) VIRTUAL,  -- işaretli fark; negatif = fazla atıf
  readable_count   INTEGER NOT NULL,   -- enerjisi okunabilen süreç sayısı (dakikanın son tick'i)
  unreadable_count INTEGER NOT NULL,   -- EPERM dönen süreç sayısı (root ve diğer kullanıcılar)
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
  t_hour           INTEGER NOT NULL,
  source           INTEGER NOT NULL,
  covered_ms       INTEGER NOT NULL,
  sysload_uj       INTEGER,
  sysload_cov_ms   INTEGER NOT NULL,
  batt_vi_uj       INTEGER,
  batt_vi_cov_ms   INTEGER NOT NULL,
  sys_uj           INTEGER,            -- Σ system_1m.sys_uj (kaynak dakika dakika seçilmiş olarak)
  sys_cov_ms       INTEGER NOT NULL,
  sys_vi_ms        INTEGER NOT NULL,   -- sys_cov_ms'in V·I yedeğinden gelen kısmı (arayüzde not için)
  att_cov_uj       INTEGER NOT NULL,
  gpu_uj           INTEGER,
  attributed_uj    INTEGER NOT NULL,
  tail_uj          INTEGER NOT NULL,
  residual_uj      INTEGER GENERATED ALWAYS AS (sys_uj - att_cov_uj) VIRTUAL,
  readable_avg     INTEGER NOT NULL,   -- saat içindeki ortalama okunabilen süreç sayısı
  unreadable_avg   INTEGER NOT NULL,
  charge_used_mah  INTEGER,            -- saat içindeki pil serilerinde Σ max(0, Δraw_charge_mah); T-041 ve çapraz kontrol
  voltage_mv_avg   INTEGER,
  fcc_mah          INTEGER,            -- saat sonundaki değer
  thermal_max      INTEGER,
  PRIMARY KEY (t_hour, source)
) STRICT, WITHOUT ROWID;

-- IOReport "Energy Model" patlamaları (T-010: CPU/DRAM/ANE sayaçları seyrek yayımlanıyor).
-- Her satır bir önceki patlamadan bu patlamaya kadar olan pencereyi kapsar. Canlı gösterimde kullanılmaz;
-- yalnız uzun pencere ortalaması ve "Sistem (okunamayan süreçler)" tahmini için. 90 gün tutulur.
CREATE TABLE energy_burst (
  start_s          INTEGER NOT NULL,
  end_s            INTEGER NOT NULL CHECK (end_s > start_s),
  cpu_uj           INTEGER,            -- "CPU Energy" deltası (mJ etiketi → µJ)
  dram_uj          INTEGER,
  ane_uj           INTEGER,
  readable_cpu_uj  INTEGER NOT NULL,   -- aynı pencerede okunabilen süreçlerin Σ Δri_energy_nj / 1000
  covered_ms       INTEGER NOT NULL,   -- pencerede Ohm'un örnekleme yaptığı süre (uyku/boşluk hariç)
  PRIMARY KEY (start_s)
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
| `sampling_gap`, `energy_burst` | 90 gün | Önemsiz (patlamalar seyrek) |
| `app` | Referansı kalmayan ve `last_seen` > 90 gün olan satır silinir | Önemsiz |

`EnergyLedger.maintain(now:)` açılışta ve her saat başından 5 dk sonra `.background` QoS ile çalışır. Adımlar tek transaction içindedir:

1. **Rollup:** `rolled_through_hour + 1`'den bitmiş saatlere devam edilir; dilim olmadan yalnız sistem ölçümü olan saatler de işlenir. İlk çalışmada bütün mevcut bitmiş saatler ve karşılığı eksik saatler yakalanır. Bitmiş her saat için `slice_1h` ve `system_1h` hesaplanır. Hesap, o saatin bütün `*_1m` satırlarından baştan yapılır (`INSERT … ON CONFLICT DO UPDATE SET … = excluded.…`, yani toplama değil değiştirme). Bu yüzden işlem idempotent'tir. Geç gelen veriye karşı her çalışmada son 3 saat yeniden hesaplanır. `meta.rolled_through_hour` güncellenir.
2. **Budama:** Yalnız `(saat, uygulama, kaynak)` / `(saat, kaynak)` saatlik karşılığı oluşturulmuş dakika satırları silinir: `DELETE FROM slice_1m WHERE t_min < :now_min - 2880` (birincil anahtar `t_min` ile başladığı için aralık silmesi ucuz). Aynı işlem `system_1m` için yapılır. Saatlik tablolar, `sampling_gap` ve `energy_burst` için sınır 90 gündür.
3. **Alan geri kazanma:** `PRAGMA incremental_vacuum(256)` ve `PRAGMA wal_checkpoint(PASSIVE)`.

**Okuma ve çakışma:** Fiş ve son 7 günlük `P_ref`, dakika ve saatlik tabloları birlikte kullanır. Saklama sınırı saatin ortasını kesebilir: o saatin eski kısmı, saatlik toplamdan hâlâ tutulan dakika toplamları çıkarılarak bulunur. Böylece enerji ve kapsam iki kez sayılmaz; tam 48 saat budama korunur. `meta.minutes_pruned_before` aynı bakım transaction’ında budama sınırını tutar; saatlik kalanın zaman aralığı bu sınırda biter, güncel dakika sorgusuna sızmaz. Eski kısmın zaman çözünürlüğü saattir. Güncel dakika aralıkları `[başlangıç, bitiş)` olarak kullanılır.

**Ölçüm aralığı:** Tick bitiş anına yazılmaz; `[wallClock − interval, wallClock)` dakika sınırlarından bölünür. Süreç enerjisi, P-core enerjisi ve CPU zamanı aynı oranlarla, toplam tamsayı korunacak şekilde dağıtılır. Sistem enerjisi, kapsam ve `att_cov_uj` aynı ölçülmüş parçalara gider; ölçülmeyen tick enerjisi dakika-geneli bir kapsam oranıyla yeniden atfedilmez; GPU kendi `gpuInterval` aralığıyla ayrıca bölünür. Uyku kapsam değildir, `sampling_gap` kaydıdır. Tick içinde kaynak değişiminin anı verilmediğinden bütün tick'in pil/AC kimliği uçtaki `BatteryState`'tir.

**Saat dilimi:** Saatlik kovalar UTC'dir. 48 saatten eski geçmişte gün sınırı yerel saate göre saatlik kovalardan kurulur. Yarım veya çeyrek saatlik ofset kullanan bölgelerde (ör. UTC+5:30, +5:45) bu, eski günlerde ±30/45 dakikalık sınır hatası demektir. Bugünün ve dünün fişi bu hatadan etkilenmez.

### 5. Etkin sistem enerjisi, pil dakikası ve fiş satırları

**Etkin sistem enerjisi (tek kaynak).** Hem fiş satırları hem `P_ref` yalnız `sys_uj` ve `sys_cov_ms` alanlarını kullanır. Ham `sysload_uj` ve `batt_vi_uj` yalnız tanı içindir. Kaynak her ölçüm parçasında seçilir ve dakika flush'ında aynı kaynak kimliğiyle biriktirilir:

```
SystemPower.systemSource = systemLoad:         sysload_uj ve sysload_cov_ms
SystemPower.systemSource = batteryVI:          batt_vi_uj ve batt_vi_cov_ms (yalnız deşarjda)
SystemLoad yok, source = pil, deşarj:           V·I yedeği
Adaptörde SystemLoad yok:                      sistem enerjisi yok
sys_uj, sys_cov_ms = her parçada seçilmiş etkin enerjinin ve kapsamın toplamı
sys_vi_ms = etkin kapsamın V·I ile ölçülen kısmı
sys_src = SystemLoad kullanıldıysa 0; yalnız V·I varsa 1; ölçüm yoksa 2
att_cov_uj = (attributed_uj + tail_uj) · sys_cov_ms / covered_ms
```

- İki kaynak aynı büyüklüğü (sistemin çektiği gücü) ölçtüğü için bir aralıkta dakika dakika karışabilir. Arayüz, sistem ölçümünün aralığın yüzde kaçını kapsadığını ve bunun yüzde kaçının V·I yedeğinden geldiğini gösterir.
- Adaptörde ve `SystemLoad` yokken `sys_src = 2` olur. Bu dakikalar kalan (residual) satırlarına ve `P_ref`'e girmez. Uygulama satırları ise bu dakikaları da kapsar, çünkü süreç enerjisi sistem ölçümünden bağımsızdır.

**Pil dakikası ve pil yüzdesi** (yalnız **pildeyken**, `source = 1` harcanan enerji için):

```
E_app        = Σ energy_uj(app, aralık, source = 1) · 10⁻⁶                          [J]
E_full       = fcc_mah · V̄ · 3.6                                                     [J]   (1 mAh × 1 V = 3.6 J)
               V̄ = pildeyken ortalama gerilim (V), son 7 gün
P_ref        = (Σ sys_uj · 10⁻⁶) / (Σ sys_cov_ms · 10⁻³)                             [W] = [J] / [s]
               toplamlar: source = 1 ∧ sys_src ≠ 2 olan dakikalar, son 7 gün
pil_yüzdesi  = 100 · E_app / E_full
pil_dakikası = E_app / P_ref / 60
```

- **Birim testi (zorunlu):** `sys_uj = 60 000 000` (60 J) ve `sys_cov_ms = 60 000` (60 s) için `P_ref = 1 W`. Aynı veriyle `E_app = 30 J` ise `pil_dakikası = 0,5`.
- **Anlamı:** "Bu uygulamanın pildeyken harcadığı enerji, senin tipik kullanımında X dakikalık pile denk." Eşdeğeri: `pil_yüzdesi × (tam pilin tipik ömrü)`.
- **`P_ref` için yeterlilik:** Son 7 günde en az 1 saatlik `sys_cov_ms` (pilde) olmalı. Yoksa bugünün pil ölçümü kullanılır (en az 10 dk). O da yoksa dakika gösterilmez; yalnız yüzde ve Wh gösterilir.
- **Şarjdayken** harcanan enerji pil dakikasına çevrilmez. Fişte ayrı bir "şarjdayken: X Wh" sütunu olarak gösterilir. `SystemLoad` adaptörde de geçerli olduğu için kalan satırları şarjdayken de hesaplanır.
- `charge_used_mah` (coulomb sayacı) `P_ref` için kullanılmaz. Çapraz kontrol ve T-041 için saklanır.

**Fiş satırları.** Bütün değerler fiş aralığının tamamı üzerinden toplanır; dakika başına hesaplanıp kırpılmaz. Böylece `SystemLoad`'ın ~20 sn'lik güncelleme gecikmesi ve örnekleme zamanlaması kaynaklı kaymalar aralık üzerinde birbirini götürür.

```
E_sys = Σ sys_uj                          ölçülen sistem enerjisi (sys_src ≠ 2 olan dakikalar)
C     = Σ att_cov_uj                      aynı sürede atfedilen enerji (uygulamalar + macOS hizmetleri + küçük süreçler)
Δ     = E_sys − C = Σ residual_uj         İŞARETLİ fark; ledger'da saklanır ve arayüzde gösterilir
R     = max(0, Δ)                         atfedilemeyen kalan
ρ     = Σ_b max(0, cpu_uj − readable_cpu_uj) · 10⁻⁶ / (Σ_b covered_ms · 10⁻³)   [W]; son 7 günün geçerli CPU patlamaları b
T_cov = Σ sys_cov_ms · 10⁻³                                                      [s]
G     = Σ gpu_uj                          ayrı GPU toplam satırı; uygulamalara atfedilmez
S     = min(max(0, R − G), ρ · T_cov · 10⁶) "Sistem (okunamayan süreçler)" [µJ]; geçerli CPU patlaması varsa
D     = max(0, R − S − G)                  "Diğer (ekran, radyo)"; patlama yoksa sistem de bu satırdadır
Δ_GPU = E_sys − C − G                     GPU dahil korunum/tolerans farkı
```

| Fiş satırı | Değer | Not |
|---|---|---|
| Uygulamalar (`category = 0`) | `slice_*` toplamları | Pil dakikası ve yüzdesi burada |
| macOS hizmetleri (`category = 1`) | `slice_*` toplamları | Okunabilen sistem süreçleri (aynı kullanıcı); tek satırda toplanır, açılabilir |
| Küçük süreçler | Σ `tail_uj` | Dakikada 1 mJ eşiğinin altı |
| Sistem (okunamayan süreçler) | `S` | Root ve başka kullanıcıların süreçleri (~%40 pid; `unreadable_count / (readable_count + unreadable_count)` oranı satırın açıklamasında gösterilir). Canlı ölçülemez; IOReport patlamalarından tahmin edilir ve "tahmini" etiketi taşır. |
| Diğer (ekran, radyo) | `D` | Ekran, Wi-Fi, Bluetooth, SSD, platformun boştaki gücü ve dönüştürme kayıpları; geçerli CPU patlaması yoksa okunamayan sistem süreçleri de dahildir |
| GPU | `G` | Canlı `GPU Energy`. Toplama dahildir, kalandan çıkarılır; uygulamalara atfedilmez. Doğrulanmış kapsam: M3, macOS 27. |

**GPU kararı (T-027 / T-001b #18).** Tek geçerli karar, T-021'in kontrollü M3/macOS 27 ölçümüne göre GPU'nun süreç CPU enerjisinden ayrı toplam olmasıdır: `D = max(0, R − S − G)`. Bu donanım/OS kapsamı dışına ölçüm sonucu genellenmez; yeni cihazlarda aynı kontrollü protokol tekrarlanmalıdır. Ledger bu kararı uygular; donanım yetenek seçimi bu görev kapsamı dışındadır.
- **Doğrulama protokolü (T-021):** Aynı ikilinin Metal işi ve aynı CPU yolu üzerindeki boş çekirdek koşusu karşılaştırılır: `(Δri_energy_a − Δri_energy_b) / ΔGPU_a`. Burada ölçülen ≈0 sonucu ayrı toplam kararının temelidir; yalnız korelasyon karar ölçütü değildir.
- **Ölçüm sonucu (T-021, M3, macOS 27):** Tek ikili, 250 komut tamponu × 2²⁰ iş parçacığı, her tampon tamamlanana kadar beklenir (`await completed()`); (a) çekirdek başına 2000 `fma`+`sin` döngüsü, (b) aynı kod yolu, döngü 0. Üç tur: (a) `Δri_energy` 0,0650 / 0,0574 / 0,0289 J, `ΔGPU` 37,52 / 37,88 / 37,81 J (~5,2 sn, ~7,2 W); (b) `Δri_energy` 0,0371 / 0,0399 / 0,0471 J, `ΔGPU` 0,06 / 0,04 / 0,04 J. Örtüşme oranı **+0,0007 / +0,0005 / −0,0005 → ≈0**. Karar: `ri_energy_nj` GPU işini **içermiyor**; protokolün ≈0 dalı geçerli (`G` uygulama satırlarında yok, `R`'den çıkarılıp ayrı toplam satırı olur). Bu karar formül, tablo ve Ledger uygulamasında T-027 ile yürürlüktedir.

**Korunum ve tolerans (#13).**
- **Tam korunum:** `Δ_GPU ≥ 0` ise `C + G + S + D = E_sys` tam olarak sağlanır.
- **Tolerans:** `−0,05 · E_sys ≤ Δ_GPU < 0` ise atfedilen enerji ölçülenden fazladır. `S = D = 0` olur ve satırların toplamı ölçülen enerjiyi `|Δ_GPU|` kadar aşar. Bu durum gizlenmez: fişin toplam satırındaki ipucunda "tolerans içinde fazla atıf: +|Δ_GPU| J (%x)" yazar.
- **Tutarsızlık:** `Δ_GPU < −0,05 · E_sys` ise arayüz "ölçüm tutarsız" uyarısı gösterir ve `S` ile `D` gizlenir.
- **İpucu her zaman gösterilir:** "Ölçülen X J · atfedilen Y J · fark ±Z J (%)". `Receipt` API'si `residualSigned_uj = E_sys − C` alanını döndürür; GPU dahil tolerans farkı bu değerden `gpu_uj` çıkarılarak elde edilir. Ledger'da `system_1m.residual_uj` ve `system_1h.residual_uj` üretilen (generated) sütunlardır; dakika ve saat düzeyinde işaretli farkı doğrudan gösterir.
- **Geçerli CPU patlaması yoksa**: `S` hesaplanmaz. `max(0, R − G)` tek satırda "Diğer (ekran, radyo, sistem)" olarak gösterilir; GPU ayrı kalır ve açıklamada okunamayan süreç oranı yazılır. Okunamayan süreçlerin enerjisi hiçbir durumda "ekran, radyo" etiketli satıra sessizce katılmaz.

### 6. Dürüst sınırlar (arayüzdeki "bu sayı ne demek?" metninin kaynağı)

1. `ri_energy_nj` bir **model tahminidir** (çekirdeğin enerji modeli), doğrudan ölçüm değildir ve CPU'yu kapsar. M3/macOS 27'de GPU işini içermediği kontrollü ölçüldü (§ 5). Uygulama başına GPU satırı yoktur; GPU ayrı toplamdır. Diğer donanım/OS için bu sonuç doğrulanmış sayılmaz.
2. Ekran, Wi-Fi, Bluetooth, SSD, hoparlör, platformun boştaki gücü ve dönüştürme kayıpları **hiçbir uygulamaya atfedilemez**. Bunlar "Diğer" satırına gider. Bir uygulamanın ekranı açık tutması ya da ağı meşgul etmesi fişte görünmez.
3. İki örnek arasında doğup ölen süreçlerin enerjisi kaybolur ve atfedilemeyen kalana (`R`) düşer. Popover kapalıyken bu pencere 10 sn'dir. Uzun ömürlü bir süreç öldüğünde de son aralığı kaybolur.
4. Root ve başka kullanıcıların süreçleri okunamaz. Faz 0'da bu oran ~%40 pid'di (668'de 268). Bunların enerjisi "Sistem (okunamayan süreçler)" satırında yalnız tahmini olarak görünür. WindowServer, uygulamalar adına ekran birleştirme (compositing) işi yapar ama root süreç olduğu için bu maliyet de o satırdadır.
5. `SystemLoad` ~20 sn'de bir güncellenir. Dakikalık değerler basamak fonksiyonu integralidir ve tek bir dakikada yanıltıcı olabilir. Fiş bu yüzden yalnız aralık toplamlarını gösterir.
6. **"Harcadı" ile "kapatırsan kazanırsın" aynı şey değildir.** Platformun boştaki gücü uygulama kapansa da harcanır. Arayüz "yedi" fiilini kullanır, "kazandırır" vaadi vermez. E-core tasarruf tahminleri ayrıca "tahmini" etiketi taşır.
7. **Dakika kullanıcıya göre ölçeklenir.** Aynı joule, hafif kullanan birinde daha çok dakikaya denk gelir. Yüzde ise kullanımdan bağımsızdır. Arayüz her ikisini de gösterir.
8. **Ohm'un yüzdesi macOS'un yüzdesiyle aynı olmayabilir.** macOS'un pil yüzdesi yumuşatılmış ve doğrusal olmayan bir göstergedir. Ohm'un yüzdesi enerji tabanlıdır ve tam kapasiteye (FCC, sağlık düzeltmeli) göre hesaplanır.

### 7. Migration'lar

- Sürüm `PRAGMA user_version` ile tutulur. Migration'lar Swift içinde sıralı bir dizidir: `[Migration(version: Int, sql: String)]`. Her biri `BEGIN IMMEDIATE … COMMIT` içinde, yalnız yazar (`OhmApp`) tarafından uygulanır.
- **Yalnız ekleme politikası:** Yeni tablo veya NULL olabilen yeni sütun eklemek `reader_compat` değerini değiştirmez. Böylece eski widget veya CLI yeni veritabanını okumaya devam eder. Sütun silmek, yeniden adlandırmak veya anlamını değiştirmek `reader_compat` değerini yükseltir.
- **Okuyucu kuralı:** `LedgerReader` önce `reader_compat ≤ bildiğiSürüm` kontrolü yapar. Değer daha yüksekse "Ohm'u güncelleyin" döner ve çökmez. `user_version = 0` ise veritabanı boş kabul edilir.
- **T-027 migration 2:** Migration 1 değiştirilmez. WAL, ilk migration transaction’ından önce bağlantı pragmasıyla etkinleştirilir; boş DB’de transaction içindeki `journal_mode` değişikliği uygulanmaz. `system_1m.sys_vi_ms INTEGER NOT NULL DEFAULT 0` eklenir; eski `sys_src = 1` kayıtlarının kapsamı aktarılır. `energy_burst.readable_cpu_valid INTEGER NOT NULL DEFAULT 0` eklenir. Eski yazar `readable_cpu_uj = 0` yazdığı için eski patlamalar tahmine alınmaz. Yeni yazar CPU enerjisini burst penceresiyle kesişen süreç deltalarından biriktirir; uyku sürelerini kapsamdan çıkarır. CPU veya okunabilir pencere yoksa tahmin gösterilmez. Çalışma belleğinde en fazla 4096 aralık tutulur (1024'lük budama); yeniden açılışta veya pencere bu geçmişi aştığında veri yoktur, sıfır varsayılmaz. Yeni sütunlar eklemelidir, `reader_compat = 1` kalır.
- **Sürüm düşürme:** Yazar kendi bildiğinden yüksek bir `user_version` görürse veritabanını açmaz. Dosyayı `ledger.sqlite.v<N>.bak` olarak kenara taşır ve yeni bir veritabanı başlatır.
- **Kenara alma güvenliği:** SQLite kontrolü ana DB ve mevcut WAL/SHM'nin geçici kopyasında yapılır; salt okunur bağlantı bile SHM'yi değiştirebilir. Ana DB, WAL ve SHM aynı yedek taban adına (`.bak`, `.bak-wal`, `.bak-shm`) kopyalanır. Hepsi başarıyla kopyalanmadan orijinaller silinmez. Kopyalama başarısızsa hata döner, yeni DB açılmaz; oluşturulan kısmi yedek temizlenir. Tek yazar varsayılır; dosya sistemi üzerindeki üç silme tek atomik işlem değildir, silme aşamasındaki hata durumunda tam yedek korunur.
- **Bozulma:** Açılışta `PRAGMA quick_check` başarısız olursa aynı işlem uygulanır (kenara taşı, yeniden oluştur). Ledger türetilmiş ölçüm verisidir, kullanıcı belgesi değildir. Kaybı kabul edilebilir, uygulamanın açılmaması kabul edilemez.
- T-041 (tahmin) ek özellik tabloları gerektirirse bunlar sonraki migration olarak eklenir (sürüm 2 T-027'ye aittir).

## Alternatifler

1. **pid veya süreç adıyla anahtarlama.** Reddedildi. pid yeniden başlatmada ve uygulama yeniden açıldığında değişir, bu yüzden günlük toplam kurulamaz. Süreç adı ise Chrome'un helper'larını ayrı satırlara böler.
2. **Yalnız sorumlu pid ile atıf.** Reddedildi. Terminal'den çalıştırılan her şey Terminal'e yazılır ve kaçak `node` görünmez olur. Ayrıca SPI kaybolursa bütün atıf çöker. Önerilen algoritma paket yolunu birincil, SPI'yi tamamlayıcı kullanır.
3. **Her tick'i ham olarak saklamak (10 sn ve 1 sn).** Reddedildi. Hacim 6–60 kat artar, dakikalık çözünürlükten fazlasına hiçbir görünüm ihtiyaç duymuyor ve her tick'te yazmak diski uyandırır.
4. **Saatlik kovaları yerel saatle tutmak.** Reddedildi. Yaz saati geçişlerinde (DST) belirsiz ve tekrar eden saatler oluşur. UTC ve 48 saatlik kesin dakika penceresi daha basit.
5. **Pil dakikası = E_app / anlık sistem gücü.** Reddedildi. O anki yük değiştikçe aynı joule farklı dakika gösterir ve fiş kendi kendine oynar. 7 günlük ortalama sabit ve açıklanabilir.
6. **"Diğer" satırını hiç göstermemek.** Reddedildi. Planın dürüstlük notuna aykırı. Kullanıcı fişin toplamının pil düşüşünü açıklamadığını görür ve ölçüme güvenmez.

## Sonuçlar ve riskler

- **(+)** Kapsanan sürede fişin toplamı etkin sistem enerjisine (`sys_uj`) eşittir. Tek istisna tolerans içindeki fazla atıftır ve işaretli fark olarak gösterilir (§ 5). Bilinmeyen kısım saklanmaz, adıyla gösterilir. Okunamayan süreçler "ekran, radyo" etiketinin içine gizlenmez.
- **(+)** Tüm hesap SQL ve saf Swift'tir. T-022 donanım olmadan, sabit test verisiyle doğrulanabilir.
- **(−)** Responsibility SPI özel bir API'dir. macOS güncellemesiyle kaybolabilir. Kaybolursa paket yolu kuralı yine çalışır. Yalnız paket dışı XPC servisleri (WebKit WebContent) kendi satırlarına düşer ve Safari'nin fişi eksik görünür.
- **Risk:** `SystemLoad` ~20 sn'de bir güncellenir; kısa ani yükler ortalamaya karışır. Fiş yalnız aralık toplamlarını gösterdiği için bu kabul edilebilir. `SystemLoad` gelecekteki bir macOS'ta kaybolursa `batt_vi_uj` yedeği yalnız deşarjda çalışır ve şarjdayken "Diğer" hesaplanamaz.
- **Risk:** "Sistem (okunamayan süreçler)" tahmini seyrek IOReport patlamalarına dayanır. Spike'taki 330 sn'lik bir koşuda hiç patlama gelmedi. Patlama gelmezse satır birleşik "Diğer (ekran, radyo, sistem)" olarak kalır (§ 5).
- **Risk:** Bir dakikada 1 mJ eşiği, çok sayıda küçük sürecin enerjisini `tail_uj` alanına taşır. Bu enerji fişte "küçük süreçler" satırında gösterilir.

## Spike'a bağlı (Faz 0 sonuçlarıyla çözüldü)

- **T-011 PASS:** `ri_energy_nj` ve `ri_penergy_nj` doğrudan kullanılır; CPU zamanından tahmin yedeği yok. `EPERM` oranı ~%40 pid. Bu süreçler "Diğer"e değil, tahmini "Sistem (okunamayan süreçler)" satırına yazılır (§ 5). Kimlik için `ri_proc_start_abstime` kullanılır.
- **T-010 PARTIAL (kesin):** Etkin sistem enerjisi `SystemLoad`, deşarjda yedek olarak `V × I` (§ 5, `sys_uj`). GPU `GPU Energy` (`gpu_uj`) ile ölçülür ve T-021'in M3/macOS 27 sonucuyla ayrı toplama alınır. CPU, DRAM ve ANE bileşen enerjisi yalnız `energy_burst` tablosunda uzun pencere olarak tutulur. "Diğer" = `max(0, sys − atfedilen − GPU − Sistem tahmini)`.
- **Çözülen (T-021, ölçülen kapsam):** M3/macOS 27'de GPU süreç enerjisine dahil değildir ve ayrı toplamdır (§ 5). Diğer cihaz/OS için kontrollü doğrulama açık kalır.
- **Açık kalan doğrulama (T-021):** Atıf algoritmasının Chrome, Safari ve bir Electron uygulamasında beklenen gruplamayı verip vermediği. Faz 0 bunu ölçmedi. Vermezse `ppid` zinciri paket yolu kuralıyla birlikte kullanılır.
