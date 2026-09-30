# T-061 Ohm Performans Ölçümü (Boşta / Idle)

## Ortam Bilgileri
- **İşlemci (`sysctl -n machdep.cpu.brand_string`):** Apple M3
- **İşletim Sistemi (`sw_vers`):**
  - ProductName: macOS
  - ProductVersion: 27.0
  - BuildVersion: 26A428
- **Tarih:** 2026-09-30
- **PID:** 24934
- **Onboarding Durumu:** Uygulama `open` ile başlatıldığında ayrı bir onboarding penceresi açılmadı; menü çubuğunda (`MenuBarExtra`) arka planda çalıştı.

---

## Hedef Tablosu (PLAN.md §Hafiflik hedefleri)

| Metrik | Hedef | Ölçülen Değer | Yöntem | Sonuç |
|---|---|---|---|---|
| **Paket Boyutu** | < 15 MB | 7,8 MB (7952 KB) | `du -sh` / `du -sk /tmp/t061-dd/Build/Products/Release/Ohm.app` | PASS |
| **Boşta Bellek** | < 40 MB | 17 MB (`phys_footprint`) / 17 MB (`top` MEM) | `footprint <pid>` (`phys_footprint`) & `top -l 2 -stats pid,cpu,mem -pid <pid>` | PASS |
| **Boşta CPU Ortalaması** | < %0,5 | %0,0067 (Aritmetik ortalama: 28 örnek %0,0, 2 örnek %0,1; `top` doğrulaması %0,0) | 5 dakika boyunca her 10 sn `ps -o %cpu= -p <pid>` (30 örnek) & `top -l 2` doğrulaması | PASS |

---

## xctrace Kaydı
- **Komut:** `xcrun xctrace record --template 'Activity Monitor' --attach 24934 --time-limit 60s --output /tmp/t061.trace`
- **Durum:** Başarılı (Exit Code: 0)
- **Çıktı Yolu:** `/tmp/t061.trace`

---

## `top` Doğrulama Çıktısı

```
PID    %CPU MEM
24934  0.0  17M

PID    %CPU MEM
24934  0.0  17M
```

---

## Ham Ölçüm Örnekleri (30 Örnek, 10 saniye aralıklarla 5 dakika)

```
[1] 03:15:16 | ps(rss, %cpu): 79120   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[2] 03:15:26 | ps(rss, %cpu): 79120   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[3] 03:15:36 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[4] 03:15:46 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[5] 03:15:56 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[6] 03:16:06 | ps(rss, %cpu): 69408   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[7] 03:16:16 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[8] 03:16:26 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[9] 03:16:37 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[10] 03:16:47 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[11] 03:16:57 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[12] 03:17:07 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[13] 03:17:17 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[14] 03:17:27 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[15] 03:17:37 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[16] 03:17:47 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[17] 03:17:57 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[18] 03:18:07 | ps(rss, %cpu): 69360   0,1 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[19] 03:18:18 | ps(rss, %cpu): 69312   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[20] 03:18:28 | ps(rss, %cpu): 69360   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[21] 03:18:38 | ps(rss, %cpu): 69200   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[22] 03:18:48 | ps(rss, %cpu): 69248   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[23] 03:18:58 | ps(rss, %cpu): 69232   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[24] 03:19:08 | ps(rss, %cpu): 69232   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[25] 03:19:18 | ps(rss, %cpu): 69184   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[26] 03:19:28 | ps(rss, %cpu): 69232   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[27] 03:19:38 | ps(rss, %cpu): 67024   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[28] 03:19:49 | ps(rss, %cpu): 66928   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[29] 03:19:59 | ps(rss, %cpu): 66304   0,1 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
[30] 03:20:09 | ps(rss, %cpu): 50512   0,0 | footprint: Ohm [24934]: 64-bit    Footprint: 17 MB (16384 bytes per page) | phys_footprint: 17 MB
```

---

## Şef notu (kapı, 2026-09-30)
Bu ölçüm yalnız **UI kabuğunu** kapsar: main'de (a2bf58f) `OhmApp` henüz `SamplingEngine`, `EnergyLedger` veya `Governor` başlatmıyor (ADR 0001'deki `OhmRuntime` yok). Sonuç UI katmanının referans maliyetidir; PLAN hafiflik hedefinin kabulü değildir. Gerçek kabul, runtime bağlandıktan sonra T-061b ile aynı yöntemle yeniden ölçülür.
