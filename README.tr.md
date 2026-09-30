# Ohm

Türkçe | [English](./README.md)

**Pilin nereye gidiyor, gör ve tek tıkla durdur.**

Ohm, Apple Silicon Mac'ler için geliştirilmiş, canlı güç tüketimini izleyen, enerji harcamasını anlaşılır pil dakikalarına dönüştüren ve yoğun arka plan uygulamalarını tek tıkla Verimlilik çekirdeklerine (E-core) sınırlamanızı veya güvenle dondurmanızı sağlayan hafif bir menü çubuğu uygulamasıdır.

---

## Özellikler

- **Canlı Güç Akışı (IOReport):** Toplam sistem yükü (`SystemLoad`), anlık GPU gücü, süreç enerjilerinin toplamından CPU gücü, P/E küme doluluğu ve termal baskıyı görüntüler.
  > *Not ([Docs/PLAN.md](./Docs/PLAN.md) uyarınca): macOS 27'de IOReport'un CPU/DRAM/ANE enerji sayaçları saniyelik güncellenmediği için bileşen bazında canlı CPU/DRAM/ANE watt'ı ayrı gösterilmez; anlık GPU gücü ve toplam sistem yükü kesintisiz raporlanır.*
- **Enerji Defteri ve Günlük Fiş:** Uygulamaların harcadığı enerjiyi joule cinsinden ölçer; tüketimi sezgisel "pil dakikası" ve pil yüzdesi olarak sunar (ör. *"Slack bugün 38 dk pil yedi"*).
- **E-Core Şeridi:** Arka plandaki uygulamaları Darwin arka plan önceliğine (`PRIO_DARWIN_BG`) alarak yalnız verimlilik çekirdeklerinde çalıştırır; performans çekirdeklerini boşta tutar.
- **Journal'lı Dondurma ve Güvenlik:** Görünmeyen arka plan uygulamalarını çekirdek düzeyinde `SIGSTOP` ile durdurur; uygulama öne geldiğinde `SIGCONT` ile çözer (M3'te ölçülen ≈20 ms). Önceden yazılan kayıt kütüğü (`~/Library/Application Support/Ohm/Freeze/`) ve bağımsız `ohm-thawd` izleyicisi sayesinde Ohm çökse veya sonlandırılsa (`kill -9`) bile tüm süreçler milisaniyeler içinde çözülür. Otomatik kural dondurması doğrulanmış topolojilerle sınırlıdır ve varsayılan yapılandırmada fiilen kapalıdır ([Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md)).
- **Kaçak Süreç Dedektörü:** Arka planda gizli kaldığı halde uzun süre yüksek CPU tüketen süreçleri yakalar; bildirim üzerinden *E-core'a al*, *Dondur* veya *Kapat* seçenekleri sunar.
- **Kural Motoru ve Doğal Dilde Kural:** Güç kaynağı, pil düzeyi, termal durum, ön plandaki uygulama ve saat gibi koşullara bağlı otomasyon kuralları. Apple Intelligence destekli cihaz üstü Foundation Models ile doğal dilde kural çevirisi (`@Generable`).
- **Pil Tahmini:** O anki uygulama karışımına ve tüketim eğilimine göre kalan süreyi yerel, çevrimiçi lineer regresyon modeliyle tahmin eder (bulut veya harici sunucu gerekmez).
- **Widget:** Günün pil fişini Bildirim Merkezi ve masaüstünde gösteren WidgetKit bileşeni.
- **CLI ve Kestirmeler (App Intents):** *Yakında* (aktif geliştirme aşamasında).

---

## Ölçülen Sistem Yükü ve Kaynak Tüketimi

**Apple M3** ve **macOS 27** üzerinde gerçekleştirilen boşta çalışma ölçümleri ([Docs/perf/T-061b-idle-runtime.md](./Docs/perf/T-061b-idle-runtime.md)):

- **Boşta Bellek:** ~21 MB toplam fiziksel ayak izi (`phys_footprint`: Ohm ~19 MB + `ohm-thawd` ~1,9 MB).
- **Boşta CPU:** ~%0,03 ortalama (%0,0267).
- **Paket Boyutu:** 8,7 MB.

---

## Gereksinimler

- **Donanım:** Yalnızca Apple Silicon (M1/M2/M3/M4 veya üstü).
- **İşletim Sistemi:** macOS 26+ (macOS Tahoe veya üstü).

---

## Kurulum

### Kaynaktan Derleme (Mevcut)

Ohm'u yerel ortamınızda Xcode 27 ve XcodeGen ile derleyebilirsiniz:

1. **Depoyu klonlayın:**
   ```bash
   git clone https://github.com/kuarezma/ohm.git
   cd ohm
   ```

2. **XcodeGen kurulu değilse kurun:**
   ```bash
   brew install xcodegen
   ```

3. **CI betiği ile derleyin ve test edin:**
   ```bash
   bash scripts/ci/build-test.sh
   ```

4. **Veya doğrudan xcodebuild ile derleyin:**
   ```bash
   cd app
   xcodegen generate
   xcodebuild -project Ohm.xcodeproj -scheme Ohm -configuration Debug build
   ```

### İmzalı Paketler ve Homebrew Cask

- **İmzalı Sürüm Paketleri:** İlk imzalı sürümle birlikte GitHub Releases üzerinden dağıtılacaktır.
- **Homebrew Cask:** Cask şablonu [packaging/homebrew/ohm.rb](./packaging/homebrew/ohm.rb) dosyasında hazırlanmıştır. İlk imzalı sürümün ardından `brew install --cask ohm` komutuyla kurulabilecektir.

---

## Gizlilik ve Güvenlik Modeli

- **%100 Yerel ve Çevrimdışı:** Ohm hiçbir ağ çağrısı yapmaz, izleme kodu içermez ve telemetri toplamaz. Tüm ölçümler ve kurallar cihaz üstündeki korumalı App Group kapsayıcısında (`*.dev.ohm`) ve yerel depolama alanında tutulur.
- **Korunan Süreçler:** Sistem dizinlerindeki (`/System/`, `/usr/`, `/Library/Apple/`) süreçler, Apple uygulama paketleri ve Ohm'un kendisi statik kapsam kapısıyla korunur.
- **Çökme Güvencesi:** Bağımsız `ohm-thawd` izleyicisi Ohm'u sürekli izler; uygulamanın beklenmedik şekilde sonlanması durumunda dondurulmuş tüm süreçleri derhal çözer.
- Detaylar için [Docs/adr/0004-freeze-safety.md](./Docs/adr/0004-freeze-safety.md) ve [SECURITY.md](./SECURITY.md) belgelerini inceleyebilirsiniz.

---

## Katkıda Bulunma

Geliştirme ortamı kurulumu, test komutları ve katkı standartları için lütfen [CONTRIBUTING.md](./CONTRIBUTING.md) rehberini inceleyin.

---

## Lisans

[Apache Lisansı 2.0](./LICENSE) ile lisanslanmıştır.
