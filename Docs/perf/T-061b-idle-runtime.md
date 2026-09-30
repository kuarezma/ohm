# T-061b Ohm Performans Ölçümü (Boşta / Idle — OhmRuntime Bağlı)

## Ortam Bilgileri
- **İşlemci (`sysctl -n machdep.cpu.brand_string`):** Apple M3
- **İşletim Sistemi (`sw_vers`):**
  - ProductName: macOS
  - ProductVersion: 27.0
  - BuildVersion: 26A428
- **Tarih:** 2026-09-30
- **PID (Ohm):** 98276
- **PID (ohm-thawd):** 98318
- **Runtime Durumu (`log show`):**
  - Çıktı: `2026-09-30 06:20:14.814 Df Ohm[98276:c484a] [dev.ohm:runtime] runtime started protection=spawnedWatcher`

---

## Hedef Tablosu ve Karşılaştırma (PLAN.md §Hafiflik hedefleri)

| Metrik / Bileşen | Hedef | T-061 (UI Kabuğu) | T-061b Ölçülen Değer (Ortalama / Min / Max) | Yöntem | Sonuç |
|---|---|---|---|---|---|
| **Paket Boyutu** | < 15 MB | 7,8 MB (7952 KB) | **8,7 MB (8904 KB)** | `du -sh` / `du -sk /tmp/t061b-dd/Build/Products/Release/Ohm.app` | PASS |
| **Boşta Bellek — Ohm** | — | 17 MB | Ort: 19 MB (Min: 19 MB, Max: 19 MB) | `footprint <pid>` (`phys_footprint`) | — |
| **Boşta Bellek — ohm-thawd** | — | — | Ort: 1,89 MB / 1936 KB (Min: 1936 KB, Max: 1936 KB) | `footprint <pid>` (`phys_footprint`) | — |
| **Boşta Bellek — Toplam** | < 40 MB | 17 MB | **Ort: 20,89 MB (Min: 20,89 MB, Max: 20,89 MB)** | `footprint` toplamı & `top -l 2` doğrulaması | PASS |
| **Boşta CPU — Ohm** | — | %0,0067 | Ort: %0,0267 (Min: %0,0, Max: %0,4) | 5 dk / 10 sn `ps -o %cpu= -p <pid>` (30 örnek) | — |
| **Boşta CPU — ohm-thawd** | — | — | Ort: %0,0000 (Min: %0,0, Max: %0,0) | 5 dk / 10 sn `ps -o %cpu= -p <pid>` (30 örnek) | — |
| **Boşta CPU — Toplam** | < %0,5 | %0,0067 | **Ort: %0,0267 (Min: %0,0, Max: %0,4)** | `ps` toplamı & `top -l 2` doğrulaması | PASS |

---

## `top` Doğrulama Çıktıları

### Ohm (PID 98276)
```
PID    %CPU MEM
98276  0.0  19M

PID    %CPU MEM
98276  0.0  19M
```

### ohm-thawd (PID 98318)
```
PID    %CPU MEM  
98318  0.0  1936K

PID    %CPU MEM  
98318  0.0  1936K
```

---

## Kapatma Doğrulaması
- `kill 98276` (SIGTERM) komutu yürütüldü.
- 5 saniye sonra `pgrep -fl "Ohm.app|ohm-thawd"` ile kontrol edildi: geride hiçbir süreç kalmadı (Exit code: 1 / boş).

---

## Ham Ölçüm Örnekleri (30 Örnek, 10 saniye aralıklarla 5 dakika)

```
[01] 06:22:31 | Ohm [98276] ps(rss, %cpu): 84512   0,1 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[02] 06:22:41 | Ohm [98276] ps(rss, %cpu): 84528   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[03] 06:22:51 | Ohm [98276] ps(rss, %cpu): 84528   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[04] 06:23:01 | Ohm [98276] ps(rss, %cpu): 84528   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[05] 06:23:11 | Ohm [98276] ps(rss, %cpu): 84528   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[06] 06:23:21 | Ohm [98276] ps(rss, %cpu): 84528   0,4 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[07] 06:23:31 | Ohm [98276] ps(rss, %cpu): 84432   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[08] 06:23:41 | Ohm [98276] ps(rss, %cpu): 84448   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[09] 06:23:52 | Ohm [98276] ps(rss, %cpu): 84480   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[10] 06:24:02 | Ohm [98276] ps(rss, %cpu): 84480   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[11] 06:24:12 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[12] 06:24:22 | Ohm [98276] ps(rss, %cpu): 84400   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[13] 06:24:32 | Ohm [98276] ps(rss, %cpu): 84464   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[14] 06:24:42 | Ohm [98276] ps(rss, %cpu): 84464   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[15] 06:24:52 | Ohm [98276] ps(rss, %cpu): 84464   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[16] 06:25:02 | Ohm [98276] ps(rss, %cpu): 84464   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[17] 06:25:12 | Ohm [98276] ps(rss, %cpu): 84464   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[18] 06:25:23 | Ohm [98276] ps(rss, %cpu): 84448   0,2 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[19] 06:25:33 | Ohm [98276] ps(rss, %cpu): 84432   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[20] 06:25:43 | Ohm [98276] ps(rss, %cpu): 84400   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[21] 06:25:53 | Ohm [98276] ps(rss, %cpu): 84400   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[22] 06:26:03 | Ohm [98276] ps(rss, %cpu): 84400   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[23] 06:26:13 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[24] 06:26:23 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[25] 06:26:33 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[26] 06:26:43 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[27] 06:26:53 | Ohm [98276] ps(rss, %cpu): 84496   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[28] 06:27:03 | Ohm [98276] ps(rss, %cpu): 84512   0,1 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[29] 06:27:14 | Ohm [98276] ps(rss, %cpu): 84512   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
[30] 06:27:24 | Ohm [98276] ps(rss, %cpu): 84512   0,0 | footprint: Ohm [98276]: 64-bit    Footprint: 19 MB (16384 bytes per page) | phys_footprint: 19 MB || ohm-thawd [98318] ps(rss, %cpu): 6240   0,0 | footprint: ohm-thawd [98318]: 64-bit    Footprint: 1936 KB (16384 bytes per page) | phys_footprint: 1936 KB
```

---

## Şef notu (kapı, 2026-09-30)
Kabul: PASS. Şef bağımsız tekrarı (Release, `open -n`, 100 sn sonra): Ohm `phys_footprint` 19 MB, ohm-thawd 1920 KB, CPU %0,0. Aynı süreçte RSS ≈ 84 MB görünür; fark paylaşılan sistem framework sayfalarıdır. PLAN'daki bellek hedefi `phys_footprint` (Activity Monitor "Bellek") ile ölçülür, RSS ile değil. T-034 kapısındaki 88–94 MB değerleri Debug derlemenin RSS'idir.
