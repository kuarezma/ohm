# Site brief — Ohm (T-050)

**Konu:** Ohm, Apple Silicon Mac'ler için açık kaynak bir menü çubuğu uygulaması. Hangi uygulamanın pili ne kadar yediğini dakika cinsinden gösterir ve o uygulamayı tek tıkla verimlilik çekirdeklerine alır ya da dondurur.
**Kitle:** MacBook sahibi geliştiriciler ve ileri kullanıcılar; r/macapps ve Hacker News okuru.
**Sayfanın tek işi:** Ziyaretçi "pil fişi" fikrini 5 saniyede anlasın ve GitHub'a (star/watch) ya da `brew` komutuna gitsin.
**Durum:** Uygulama henüz yayında değil. Birincil CTA "Watch releases on GitHub"; `brew install --cask ohm` komutu "coming with v1.0" etiketiyle gösterilir. Hiçbir sayfa uydurma indirme sayısı, kullanıcı yorumu ya da benchmark içermez.

## Fikir: fiş ve direnç
- İsim bir direnç birimi. Direnç üzerindeki renk bantları sitenin renk sistemini oluşturur: her uygulama satırının solunda küçük bir renk bandı durur.
- Uygulamanın ana metaforu **fiş**. Hero'da termal yazıcı fişi, menü çubuğu popover'ının altından satır satır basılarak çıkar.
- Bilinçli olarak kaçınılanlar: koyu zemin + asit yeşili vurgu (ilk planda düşünülmüştü, fakat şu an bütün AI araç sitelerinin varsayılanı olduğu için değiştirildi), krem + serif, gazete düzeni.

## Token sistemi
**Renk**
| Ad | Hex | Kullanım |
|---|---|---|
| `film` | `#CFDDE6` | Sayfa zemini: metal film direncin soluk mavisi |
| `paper` | `#FBFBF8` | Fiş kâğıdı, kartlar |
| `ink` | `#101826` | Metin, ince çizgiler |
| `graphite` | `#5A6675` | İkincil metin |
| `band-red` | `#C4382C` | Birincil vurgu: CTA, "pil yedi" değerleri |
| `band-violet` | `#5B43A0` | E-core durumu, "tasarruf" değerleri |
| `band-orange` / `band-brown` / `band-gold` | `#E07A2E` / `#6E452A` / `#B08D2F` | Yalnız fiş satırlarının renk bantları |

Koyu tema: zemin `#0F1620` (koyu film), kâğıt `#1A2230`, mürekkep `#E7EDF2`; bant renkleri aynı kalır, parlaklığı %10 artırılır. `prefers-color-scheme` ile otomatik geçer, ayrıca elle geçiş düğmesi bulunur.

**Tipografi** (Google Fonts)
- Display: **Big Shoulders Display** 800. Yalnız büyük sayılar ("38 min") ve hero başlığında kullanılır; ölçü aleti ekranı hissi verir.
- Gövde: **Hanken Grotesk** 400/600.
- Yardımcı ve veri: **Martian Mono** 400. Fiş satırları, komutlar ve tablo sayıları bu fontla yazılır.
- Ölçek: 14 / 16 / 20 / 28 / 44 / 88 px. Hero başlığı masaüstünde 88 px, mobilde 44 px.

**İmza öğesi:** Popover'dan basılarak çıkan canlı fiş.
- Sayfa yüklenince kâğıt bir yarıktan aşağı kayar ve satırlar 120 ms arayla basılır.
- Satırdaki `E` düğmesine basılınca satır yeniden basılır: eski dakika üstü çizili görünür, yanına mor bir "−14 min" eklenir. Alttaki toplam güncellenir.
- `prefers-reduced-motion` açıksa fiş statik ve tamamen basılmış olarak gösterilir.

## Düzen
```
[ nav: ohm ·····················  Features  Privacy  GitHub ★ ]

  Where did your                ┌─ menubar ─── ◉ 7.4 W ─┐
  battery go?                   │ popover (P/E bars)     │
                                └──────┬─────────────────┘
  Ohm prints a receipt for          ┌──┴──────────────┐
  every app on your Mac…            │ RECEIPT  today   │
                                    │▌Chrome  1h 12m [E]│
  [Watch releases on GitHub]        │▌Slack      38m [E]│
  $ brew install --cask ohm  (v1.0) │▌Other (display…) │
                                    └──────────────────┘
─────────────────────────────────────────────────────────
  Lanes: 4 P-core lane / 4 E-core lane diagram; app chips slide from P to E on click
─────────────────────────────────────────────────────────
  Six capabilities (2×3 cards, each with a band stripe): Receipt · E-core lane ·
  Freeze & thaw · Runaway catcher · Rules in plain words · Widget & CLI
─────────────────────────────────────────────────────────
  Why only Apple Silicon — 3 short facts, each tied to one feature
─────────────────────────────────────────────────────────
  Privacy — big mono "0 bytes sent" + three lines
─────────────────────────────────────────────────────────
  Comparison table: Activity Monitor · Stats · App Tamer · Ohm
─────────────────────────────────────────────────────────
  FAQ (details/summary) · Footer: MIT · GitHub · Sponsors · TR/EN
```
Mobilde fiş başlığın altına iner, şerit diyagramı dikey hale gelir. Sayfada yatay kaydırma olmaz; kenar boşluğu 16 px.

## Metin (EN, kaynak metin; TR çevirisi T-052'de)
- **Hero başlığı:** Where did your battery go?
- **Hero alt metni:** Ohm prints a receipt for every app on your Mac: how many minutes of battery it cost you today. One click moves a hungry app to the efficiency cores or freezes it until you come back.
- **CTA:** Watch releases on GitHub · ikincil: `brew install --cask ohm` + "Available with v1.0"
- **Lanes:** "Your M-series chip has two kinds of cores. Ohm lets you choose which ones an app gets." Alt satır: "Move an app to the efficiency cores. It keeps running, just slower and cooler."
- **Kartlar:**
  1. *Battery receipt*: Minutes and percent per app, per day. Measured, not guessed.
  2. *Efficiency lane*: One click keeps an app on the E-cores. It switches back when you bring the app to the front.
  3. *Freeze and thaw*: Hidden apps stop using power entirely. Ohm thaws them the moment you switch to them.
  4. *Runaway catcher*: "node has used 94% CPU for 12 minutes in the background." Act from the notification.
  5. *Rules in plain words*: Type "When battery is under 30%, keep Chrome on efficiency cores." Ohm turns it into a rule, on-device.
  6. *Widget and CLI*: `ohm receipt --today` in your terminal, today's receipt on your desktop.
- **Why only Apple Silicon:** "Separate performance and efficiency cores: the E-core lane." · "Per-process energy counters in the chip: the receipt." · "An on-device language model: rules in plain words, with no cloud."
- **Privacy:** "0 bytes sent." Ohm has no account, no analytics and no network access. The only exception is update checks, which you can turn off. The source is on GitHub.
- **Dürüstlük notu (SSS):** "Why is there an 'Other' row?" The display and the radios cannot be attributed to a single app, so Ohm shows them separately instead of spreading them across your apps.
- **SSS diğer sorular:** Does it need admin rights? (No, not for v1.) · Intel Macs? (No, Ohm reads counters that only Apple Silicon has.) · Will freezing lose my work? (Ohm never freezes apps playing audio or in a call, and thaws everything if it quits or crashes.) · Price? (Free and MIT-licensed.)

## Kalite tabanı
Build adımı yok; `site/index.html`, `site/styles.css`, `site/app.js`. Bütün bağlantılar göreli yazılır. Görünür klavye odağı, `prefers-reduced-motion`, en az AA kontrast; JS kapalıyken fiş basılmış halde görünür. Harici kaynak yalnız Google Fonts; `font-display: swap`. Toplam boyut (fontlar hariç) 60 KB'ın altında.
