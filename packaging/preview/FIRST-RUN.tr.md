# Ohm Önizleme Sürümünü Çalıştırma

Bu önizleme sürümü, proje henüz ücretli bir Apple Developer ID sertifikasına sahip olmadığı için imzasız olarak sunulmaktadır.

Bu nedenle macOS Gatekeeper ilk açılışta uygulamanın çalışmasını engeller. Ohm'u açmak için aşağıdaki adımları uygulayın.

---

## İlk Açılış Adımları (Gatekeeper İzni)

1. **`Ohm.app`** uygulamasını **`/Applications`** (Uygulamalar) klasörünüze taşıyın.
2. **`Ohm.app`**'e çift tıklayın. macOS, uygulamanın kötü amaçlı yazılımlara karşı denetlenemediğini belirten bir uyarı penceresi açacaktır. **Bitti** (veya **Vazgeç**) düğmesine tıklayın.
3. **Sistem Ayarları › Gizlilik ve Güvenlik** menüsünü açın.
4. **Güvenlik** başlığına doğru aşağı kaydırın. *"Ohm, tanımlı bir geliştiriciden gelmediği için kullanımı engellendi"* uyarısını göreceksiniz.
5. Uyarının yanındaki **Yine de Aç** düğmesine tıklayın; parolanızı veya Touch ID'nizi girip açılışı onaylayın.

### Alternatif: Terminal Komutu

İsterseniz Terminal üzerinden karantina özniteliğini doğrudan kaldırabilirsiniz:

```bash
xattr -dr com.apple.quarantine /Applications/Ohm.app
```

Bu komuttan sonra Ohm'u Spotlight veya Uygulamalar klasöründen normal şekilde açabilirsiniz.

---

## App Group ve Kaynaktan Derleme Hakkında Önemli Not

Ohm; menü çubuğu uygulaması, arka plan koruyucusu ve widget arasında enerji kayıtlarını bir App Group (`dev.ohm`) kapsayıcısı üzerinden paylaşır. Modern macOS sürümlerinde (macOS 15/Tahoe+) takım önekli App Group kapsayıcılarına erişim, doğrulanmış bir Apple Developer Team kimliği gerektirir; ad-hoc imzalı önizleme ikilileri LaunchServices üzerinden açıldığında paylaşılan deftere erişemeyebilir.

Eğer sisteminizde başlangıçta izin hatasıyla karşılaşırsanız, Ohm'u ücretsiz kişisel hesabınızla (Personal Team) doğrudan kaynaktan derleyebilirsiniz:

```bash
git clone https://github.com/kuarezma/ohm.git
cd ohm
bash scripts/ci/build-test.sh
```

GitHub CI üzerinden sunulan önizleme paketleri test amaçlıdır; tüm bileşenlerin (özellikle widget ve defter) sorunsuz çalışması için Personal Team ile kaynaktan derleme önerilir.
