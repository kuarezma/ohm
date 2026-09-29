# Roller — Ohm

> **Model seçimi (29 Eyl 2026):** Bu dosyadaki model/efor atamaları tarihsel. Güncel seçim genel `route` kuralına tabidir (`~/.claude/skills/route/SKILL.md`, sayılar: `~/Desktop/model_görevleri/ROUTING.md`): kapılı kod GPT-6.1 Sol medium (Codex), zor kod Sol high → Opus 5.5 high, mimari Opus 5.5 high, tarama/doküman/UI Gemini 3.8 Flash high. Çelişkide genel kural geçerli; roller ve süreç (kapı, denetçi ayrılığı) bu dosyada kalır.

Ölçüm temeli: `~/Desktop/model_görevleri/ROUTING.md` (28 Eyl 2026). Sayı buraya kopyalanmaz.
Plan ve tam görev tablosu: `Docs/PLAN.md` § "Nasıl üretilecek".

| Rol | Model (efor) | Zeka | Çağıran |
|---|---|---|---|
| Şef: kırılım, kart, kapı, review, merge | Opus 5.5 (medium) | CC 🔵2 | kullanıcı oturumu |
| Mimari, özel API, sinyal güvenliği kodu | Opus 5.5 (high) | CC 🟡3 | şef, `Agent` `opus-high` |
| UI, iyi tanımlı kod, test, doküman, site | Gemini 3.8 Flash (high) | AG 🔴3 | şef, `agy:*` skill'leri |
| Farklı aileden ikinci görüş, kritik review (salt okunur) | GPT-6 Astra (medium/high) | Codex 🟡2/🟠3 | şef, `codex:rescue` |
| Terminal döngüsü Opus high'ta tıkanırsa | Sonnet 5.5 (max) | CC 🟣5 | şef, `Agent` `sonnet-max` |
| Yedek: kod / doküman | GLM 5.3 (max) / Muse Spark 1.3 (xhigh) | – | şef, `opencode` / `cursor-agent` |

Merdiven: Gemini (2 deneme) → Opus medium → Opus high → Sonnet max (terminal) veya Astra teşhisi.

## Değişmez kurallar
1. Pano `main`'de yaşar; devretmeden önce pano `main`'de olmalı.
2. Yazar kendi sağlayıcısını denetleyemez; denetçi salt okunurdur. Gemini kodunu Opus, Opus'un riskli kodunu Astra denetler.
3. Model, harness ve efor devir kaydına şef tarafından yazılır; modele yazdırılmaz.
4. Zeka seviyesi göreve başlamadan bildirilir.
5. Doğrulanabilir kapı olmadan DONE yok; "çalışıyor" iddiası komut çıktısı ister. Denetim bulgusu ADR'ye karşı doğrulanır.
6. API imzası, sürüm, lisans gibi olgular kartta verilir veya kaynaktan okutulur; hiçbir modelden hatırlaması istenmez.
7. Uzun ajanik döngü Claude Code'da koşturulmaz; istisnanın gerekçesi devir kaydına yazılır.
8. Kota rahatlatma = harness değiştirmek, model değil.
