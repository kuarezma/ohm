# Faz 0 spike sonuçları (T-010 … T-013)

Makine: Apple M3 (4 P + 4 E çekirdek; `hw.perflevel0` = Performance, `hw.perflevel1` = Efficiency),
macOS 27.0 (26A428), Swift 6.4, sudo yok. Tarih: 2026-09-29.
Her spike kendi klasöründe; `run.sh` derler (`spikes/bin/`, gitignored) ve çalıştırır.
Yük süreçleri (`yes`) ve TextEdit örneği yalnız script'lerin kendisi tarafından başlatılır ve sonunda öldürülür.

| Spike | Karar | Belirleyici satır |
|---|---|---|
| T-011 süreç enerjisi | PASS | `2974 yes  4.353 W  cpu 100.0%  P_share 1.00` (listenin başı) |
| T-010 IOReport watt | PARTIAL (kapı FAIL) | CPU/DRAM/ANE sayaçları saniyelik 0; yalnız `GPU Energy` (nJ) canlı |
| T-012 E-core | PASS | `B setpriority BG  P_shr 0.00  proc_W 1.442  P_act 7.8%  E_act 100.0%` |
| T-013 dondur/çöz | PASS | `trial 1: SIGCONT latency from 'open -a' = 18 ms`; watchdog 36 ms'de çözdü |

---

## T-011 — `proc_pid_rusage(RUSAGE_INFO_V6)` ile süreç enerjisi

Komut: `spikes/procenergy/run.sh` (bir `yes` başlatır, 5 sn ölçer, ilk 10'u basar, `yes`'i öldürür).

```
interval=5.01s pids=668 readable=400 denied(EPERM)=268 exited_or_err=0 sum_readable=4.570W
    pid name                          watt     joule    cpu% P_share
   2974 yes                          4.353    21.797   100.0    1.00
    985 Python                       0.097     0.488     5.4    0.94
  97787 Terminal                     0.040     0.202     1.5    1.00
  97846 2.1.284                      0.035     0.173     1.9    0.99
   1699 agy                          0.018     0.091     0.8    0.98
```

Karar: **PASS.** `yes` listenin başında, 1 çekirdek = %100 CPU ve 4,35 W (tam frekansta bir M3 P çekirdeği).

Üretim tasarımı için sonuçlar:
- Alan adları SDK'dan doğrulandı: `ri_energy_nj`, `ri_penergy_nj` (`sys/resource.h` satır 410-411), `RUSAGE_INFO_CURRENT == RUSAGE_INFO_V6`. Birim nJ, monoton sayaç.
- `ri_penergy_nj / ri_energy_nj` = P-kümede harcanan enerji payı; T-012'de E-core doğrulaması için güvenilir sinyal.
- 668 süreçten 268'i (root ve diğer kullanıcılar) `EPERM` döndürüyor. Sudo'suz uygulama bunları "sistem (okunamayan)" olarak gruplamalı. Sistem toplamı için süreç toplamı kullanılamaz.
- CPU zamanı (`ri_user_time + ri_system_time`) mach tick cinsinden; `mach_timebase_info` ile ns'ye çevrilmeli (M3'te 125/3).
- Pid yeniden kullanımına karşı `ri_proc_start_abstime` ile eşleştirme yapıldı; üretimde de gerekli.

## T-010 — IOReport ile sudo'suz watt

Komutlar: `spikes/ioreport/run.sh` (10 sn boşta + 10 sn tek `yes` yükü, ardından tüm kanal taraması),
`spikes/ioreport/run.sh burst 330` (sayaçların yayın aralığını ölçer), `ioreport list`, `abs_probe.c`.

```
# idle 10 s
  t cpu_p_W cpu_e_W   gpu_W   ane_W  dram_W | P_act% E_act% | sysload_W batt_VxA
  2   0.000   0.000   0.003   0.000   0.000 |   15.8   38.4 |     3.815  -14.863
# load: yes, 10 s
  5   0.000   0.000   0.005   0.000   0.000 |   28.6   32.5 |     7.430   -5.823
# per-second energy channels across ALL IOReport groups (3 s, under load)
t=2 [Energy Model|] GPU Energy = 19327749 nJ
t=2 channels=8975 nonzero_energy=1
# abs_probe (mutlak sayaçlar, 25 sn): CPU Energy ve DRAM hiç değişmedi, GPU Energy her saniye arttı
CPU Energy=63060909 DRAM=20450021 GPU Energy=917040879408 t=0
CPU Energy=63060909 DRAM=20450021 GPU Energy=917516941832 t=24
```

Karar: **PARTIAL; kabul kapısı geçmedi.** API çalışıyor, sudo istemiyor, kanallar var. Ancak macOS 27'de CPU, DRAM ve ANE enerji sayaçları saniyelik güncellenmiyor. Seyrek aralıklarla toplu "patlama" olarak yayımlanıyorlar. Görülen patlamalar: abonelikten 1 sn sonra, 4 sn sonra, 56 sn sonra ve 132 sn sonra. Tek `yes` yüküyle 330 sn'lik `burst` koşusunda ise hiç patlama olmadı. Bu yüzden `cpu_p_W` ve `cpu_e_W` 1 Hz'de 0 kalıyor, "yükle CPU değeri artar" şartı sağlanmıyor. Karşılaştırma tarafı çalışıyor: `PowerTelemetryData.SystemLoad` 3,8 W'tan 7,4 W'a çıktı. Saniyelik tek enerji kanalı `GPU Energy` (nJ); tüm gruplardaki 8975 kanal tarandı.

Denenen yollar (blokaj başına en çok 2):
1. "Energy Model" grubuna abone olup 1 sn'lik `IOReportCreateSamplesDelta`: CPU/DRAM/ANE deltası 0; seyrek patlamalar dışında boş.
2. `IOReportCopyAllChannels` ile bütün gruplarda saniyelik değişen, birimi J olan kanal arandı: yalnız `GPU Energy`.
Tanı: `abs_probe` mutlak değerlerin donuk olduğunu doğruladı. Sorun delta hesabında değil, yayında. Patlamayı neyin tetiklediği (periyot mu, başka bir istemcinin örneklemesi mi) belirlenmedi.

M3 / macOS 27 olguları (üretim için):
- Kanal adları ("Energy Model", alt grup yok, birim `mJ`): `ECPU`/`PCPU` küme toplamları, `ECPU0..3`/`PCPU0..3` çekirdekler, `ECPM`/`PCPM`, `*_SRAM`, `ECPUDTLxx`/`PCPUDTLxx`, `CPU Energy` (toplam), `GPU` (mJ, seyrek), `GPU SRAM`, `ANE`, `DRAM`, `DCS`, `AMCC`, `DISP`, `DISPEXT`, `ISP`, `AVE`, `MSR`, `VDEC`, `SOC_AON`, `SOC_REST`; `GPU Energy` **nJ**; PCIe kanalları uJ. Etikete göre dönüştürme şart.
- `libIOReport.dylib` dosya olarak yok (dyld paylaşımlı önbellekte). SDK'daki `libIOReport.tbd` ile `-lIOReport` bağlanıyor; `IOReportMergeChannels` son parametresine `nil` adı verilemez (makro çakışması).
- "CPU Stats / CPU Core Performance States" durum yerleşimi (residency) **saniyelik canlı**. `PCPU*`/`ECPU*` kanalları ve `IDLE`/`OFF`/`DOWN` dışındaki durumlar "aktif" sayılıyor. Küme doluluğu P_act%/E_act% olarak ölçülebiliyor (T-012'de kullanıldı).
- Sistem gücü referansı: `AppleSmartBattery` → `PowerTelemetryData.SystemLoad` (mW), pilde ve adaptörde geçerli. `Voltage × Amperage` yalnız deşarjda sistem gücüne eşit; adaptörde şarj gücünü gösterir (test sırasında adaptör takıldı ve bu görüldü). Batarya değerleri ~20 sn'de bir güncelleniyor.

Yedek tasarım: Bileşen başına 1 Hz watt, IOReport'tan macOS 27'de alınamıyor. Önerilen katmanlar:
(a) Uygulama/süreç gücü için T-011'deki `ri_energy_nj`.
(b) Küme doluluğu için "CPU Stats" residency.
(c) Sistem gücü için `SystemLoad`.
(d) GPU için canlı `GPU Energy`.
(e) CPU/DRAM için IOReport patlamaları geldikçe uzun pencere ortalaması; patlama yoksa gösterilmez.
PLAN'daki "IOReport değişmiş olabilir" riski gerçekleşti. T-001 ADR'si bu kararı içermeli.

## T-012 — `PRIO_DARWIN_BG` ile E-core'a sınırlama

Komut: `spikes/ecore/run.sh` (4 `yes`'i kendisi başlatır; her faz 5 sn; sonunda hepsini öldürür).

```
spawned 4 x yes: 34476 34491 34506 34521
phase                   P_shr  proc_W procP_W     cpu% | P_act% E_act% | prio
A baseline               1.00  13.341  13.320    399.3 |  100.0   36.5 |    0
B setpriority BG         0.00   1.442   0.001    266.3 |    7.8  100.0 |    0
C BG removed (0)         1.00  13.148  13.106    399.6 |  100.0   42.6 |    0
D taskpolicy -b          0.00   0.889   0.002    318.1 |   11.0   99.9 |    0
E taskpolicy -B          1.00  13.103  13.057    399.5 |  100.0   18.7 |    0
killed all children
```

Karar: **PASS.** BG sonrası P payı 1,00'dan 0,00'a düştü. P kümesi %100'den %7,8'e boşaldı, E kümesi %100 doldu. Politika kaldırılınca (değer 0) P'ye geri dönüldü. `taskpolicy -b/-B` aynı sonucu verdi.

Üretim tasarımı için sonuçlar:
- 4 yükün gücü 13,3 W'tan 1,4 W'a indi (~9 kat). Buna karşılık CPU zamanı %399'dan %266'ya düştü ve E çekirdekleri daha yavaş. İş bitirme süresi uzar; arayüz bunu "daha az güç, daha yavaş" diye anlatmalı.
- `getpriority(PRIO_DARWIN_PROCESS, pid)` BG uygulanmışken de 0 döndürdü. Politika durumu bu çağrıyla okunamıyor. Doğrulama `ri_penergy_nj` payıyla ya da ECoreLane'in kendi kaydıyla yapılmalı (journal'a yazılmalı).
- Başka kullanıcının süreci için `setpriority` büyük ihtimalle EPERM verir. Bu spike'ta yalnız kendi süreçlerimiz denendi.

## T-013 — SIGSTOP ile dondurma, aktivasyonda çözme, çökme kurtarma

Komut: `spikes/freeze/run.sh`. Kullanıcıya ait bir TextEdit açıksa script iptal eder. Kendi örneğini `open -na TextEdit` ile açar ve sonunda kapatır.
Ajan: `FreezeAgent.swift`. Önce journal'a yazar (fsync + atomik rename), sonra SIGSTOP gönderir. `didActivateApplicationNotification` ile SIGCONT'u tetikler. Ajanın ayrı bir süreç olan watchdog'u (`kqueue EVFILT_PROC NOTE_EXIT`) ve `recover` modu vardır. Journal'da pid + `ri_proc_start_abstime` tutulur; bu, pid yeniden kullanımına karşı korumadır.

```
our TextEdit pid=35771
ps stat after freeze: T
trial 1: SIGCONT latency from 'open -a' = 18 ms; stat=S
trial 2: SIGCONT latency from 'open -a' = 18 ms; stat=S
trial 3: SIGCONT latency from 'open -a' = 17 ms; stat=S
stat before kill -9: T  journal: 35771 1140144980638
watchdog thawed after 36 ms; stat=S
after both killed: stat=T journal: 35771 1140144980638
recover: recovered pid=35771 SIGCONT rc=0
after recover: stat=S
cleanup: TextEdit 35771 alive? no
```

Karar: **PASS.** (1) Dondurunca durum `T` oldu. (2) `open -a` ile SIGCONT arasındaki gecikme 17-18 ms (hedef <300 ms). (3) Ajan `kill -9` ile öldürülünce watchdog 36 ms içinde çözdü. Ajan ve watchdog birlikte öldürülünce süreç `T`de kaldı; sonraki açılıştaki `recover` onu çözdü.

Üretim tasarımı için sonuçlar:
- Donuk (SIGSTOP) süreç de `didActivateApplicationNotification` üretiyor; aktivasyon uygulamanın iş birliğini gerektirmiyor. Log'da bildirim ile SIGCONT arası ~0,3 ms.
- Ön koşul: Dondurmadan önce uygulama gizlenmeli (`NSRunningApplication.hide()`, SIGSTOP'tan önce, çünkü gizleme uygulamanın çalışmasını gerektirir). Öndeki uygulama tekrar aktive edilince bildirim gelmez. Governor yalnız arka plandaki uygulamayı dondurmalı.
- İki katmanlı kurtarma gerekli ve yeterli görünüyor: ayrı watchdog süreci ve açılışta journal kurtarma. Üretimde watchdog bir LaunchAgent olabilir; bu, T-001 ADR 0004 için bir karar noktası.
- Dock tıklaması otomasyonla test edilemedi; aktivasyon `open -a` ile tetiklendi. **Dock davranışı elle doğrulanacak.** Cmd-Tab da elle doğrulanmalı.
- Ölçülen gecikme `open` komutunun başlangıcından SIGCONT'a kadar olan süre. Pencerenin ekrana gelmesi (uygulamanın kuyruktaki olayları işlemesi) bu süreye dahil değil.
