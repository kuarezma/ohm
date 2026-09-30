#!/usr/bin/env bash
# scripts/ci/release.sh — Ohm Release paketleme ve notarization betiği
# Kapsam: Release derlemesi, Developer ID imzalama, notarization, stapling ve zip paketleme.
# Modlar:
#   signed:    5 secret tanımlı → Developer ID imzalama, notarization, stapling, Ohm-<v>.zip
#   preview:   secret yok → ad-hoc / yerel Developer Team imza, FIRST-RUN.md ile Ohm-<v>-preview.zip
#   --dry-run: Açılmış entitlement ile ad-hoc Release, zip, SHA-256, sürüm ve entitlement doğrulaması;
#              notarytool/Developer ID imza adımlarını simüle eder.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/ci"
mkdir -p "$BUILD_DIR"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      ;;
  esac
done

# Sürüm belirleme (tag v* varsa tag'den, yoksa Info.plist'ten)
if [ -n "${GITHUB_REF_NAME:-}" ] && [[ "${GITHUB_REF_NAME}" == v* ]]; then
  VERSION="${GITHUB_REF_NAME#v}"
elif [ -f "$REPO_ROOT/app/OhmApp/Info.plist" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$REPO_ROOT/app/OhmApp/Info.plist" 2>/dev/null || echo "0.0.1")
else
  VERSION="0.0.1"
fi

# Team ID belirleme (Rev 1: $(TeamIdentifierPrefix) açılımı için)
TEAM_ID="${NOTARY_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
if [ -z "$TEAM_ID" ] && [ -f "$REPO_ROOT/app/Local.xcconfig" ]; then
  TEAM_ID=$(grep -E '^\s*DEVELOPMENT_TEAM\s*=' "$REPO_ROOT/app/Local.xcconfig" | sed -E 's/.*=\s*//;s/[ "].*//' || true)
fi
if [ -z "$TEAM_ID" ]; then
  TEAM_ID="3J22LGMHJ9"
fi

# Mod belirleme (signed vs preview vs dry-run)
IS_SIGNED=false
if [ -n "${DEVELOPER_ID_CERT_P12_BASE64:-}" ] && [ -n "${DEVELOPER_ID_CERT_PASSWORD:-}" ] && \
   [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_APP_PASSWORD:-}" ]; then
  IS_SIGNED=true
fi

if [ "$DRY_RUN" = true ]; then
  PACKAGE_MODE="dry-run"
  ZIP_NAME="Ohm-${VERSION}.zip"
  SHA256_NAME="Ohm-${VERSION}.sha256"
elif [ "$IS_SIGNED" = true ]; then
  PACKAGE_MODE="signed"
  ZIP_NAME="Ohm-${VERSION}.zip"
  SHA256_NAME="Ohm-${VERSION}.sha256"
else
  PACKAGE_MODE="preview"
  ZIP_NAME="Ohm-${VERSION}-preview.zip"
  SHA256_NAME="Ohm-${VERSION}-preview.sha256"
fi

DERIVED_DATA="$BUILD_DIR/DerivedDataRelease"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Ohm.app"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
SHA256_PATH="$BUILD_DIR/$SHA256_NAME"
ZIP_SHA256_PATH="$BUILD_DIR/${ZIP_NAME}.sha256"

echo "=== Ohm Release Paketleme (Mod: ${PACKAGE_MODE}, Sürüm: ${VERSION}, Team: ${TEAM_ID}) ==="

# [1/5] XcodeGen ile projeyi güncelle
echo "==> [1/5] Generating Xcode project with xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required but not installed." >&2
  exit 1
fi
(cd "$REPO_ROOT/app" && xcodegen generate)

# Rev 1 Point 1: Entitlement açılımı ($(TeamIdentifierPrefix) -> <TEAM>.)
EXPANDED_APP_ENTITLEMENTS="$BUILD_DIR/Ohm.expanded.entitlements"
EXPANDED_WIDGET_ENTITLEMENTS="$BUILD_DIR/OhmWidget.expanded.entitlements"
sed "s/\$(TeamIdentifierPrefix)/${TEAM_ID}./g" "$REPO_ROOT/app/OhmApp/Ohm.entitlements" > "$EXPANDED_APP_ENTITLEMENTS"
sed "s/\$(TeamIdentifierPrefix)/${TEAM_ID}./g" "$REPO_ROOT/app/OhmWidget/OhmWidget.entitlements" > "$EXPANDED_WIDGET_ENTITLEMENTS"

# Rev 1 Point 3: Anahtarlık arama listesini kaydet ve cleanup'ta geri yükle
ORIGINAL_KEYCHAINS=""
if ORIGINAL_KEYCHAINS=$(security list-keychains -d user 2>/dev/null | tr -d '"' | xargs); then
  :
fi

KEYCHAIN_PATH=""
cleanup() {
  if [ -n "$ORIGINAL_KEYCHAINS" ]; then
    echo "==> Restoring keychain search list..."
    security list-keychains -d user -s $ORIGINAL_KEYCHAINS 2>/dev/null || true
  fi
  if [ -n "$KEYCHAIN_PATH" ] && [ -f "$KEYCHAIN_PATH" ]; then
    echo "==> Deleting temporary keychain..."
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  fi
  rm -f "${EXPANDED_APP_ENTITLEMENTS:-}" "${EXPANDED_WIDGET_ENTITLEMENTS:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Rev 1 Point 2: Derleme imzası — Release derlemesini CODE_SIGNING_ALLOWED=NO ile yap
echo "==> [2/5] Building Release configuration (CODE_SIGNING_ALLOWED=NO)..."
xcodebuild -project "$REPO_ROOT/app/Ohm.xcodeproj" \
  -scheme Ohm \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [ "$PACKAGE_MODE" = "dry-run" ]; then
  # Rev 1 Point 5: Dry-run'da da açılmış entitlement ile içten dışa ad-hoc imzala
  echo "==> [3/5] Dry-run: Açılmış entitlement ile ad-hoc imzalama yapılıyor..."
  if [ -d "$APP_PATH/Contents/PlugIns/OhmWidget.appex" ]; then
    codesign --force --sign - \
      --entitlements "$EXPANDED_WIDGET_ENTITLEMENTS" \
      "$APP_PATH/Contents/PlugIns/OhmWidget.appex"
  fi
  if [ -f "$APP_PATH/Contents/Helpers/ohm" ]; then
    codesign --force --sign - "$APP_PATH/Contents/Helpers/ohm"
  fi
  if [ -f "$APP_PATH/Contents/MacOS/ohm-thawd" ]; then
    codesign --force --sign - "$APP_PATH/Contents/MacOS/ohm-thawd"
  fi
  codesign --force --sign - \
    --entitlements "$EXPANDED_APP_ENTITLEMENTS" \
    "$APP_PATH"

  # Rev 1 Point 5: Entitlement doğrulaması (codesign -d --entitlements - --xml)
  echo "==> [3/5b] Dry-run: Entitlement içeriği doğrulanıyor (<TEAM>.dev.ohm)..."
  if ! codesign -d --entitlements - --xml "$APP_PATH" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in Ohm.app" >&2
    exit 1
  fi
  if ! codesign -d --entitlements - --xml "$APP_PATH/Contents/PlugIns/OhmWidget.appex" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in OhmWidget.appex" >&2
    exit 1
  fi
  echo "    ✔ Entitlements verified: ${TEAM_ID}.dev.ohm present in signed app and widget."

  echo "==> [3/5c] Dry-run: Developer ID imza adımları simüle ediliyor (yazdırılıyor):"
  echo "    [dry-run] codesign --force --options runtime --timestamp --entitlements \"$EXPANDED_WIDGET_ENTITLEMENTS\" --sign \"Developer ID Application: ...\" \"$APP_PATH/Contents/PlugIns/OhmWidget.appex\""
  if [ -f "$APP_PATH/Contents/Helpers/ohm" ]; then
    echo "    [dry-run] codesign --force --options runtime --timestamp --sign \"Developer ID Application: ...\" \"$APP_PATH/Contents/Helpers/ohm\""
  fi
  if [ -f "$APP_PATH/Contents/MacOS/ohm-thawd" ]; then
    echo "    [dry-run] codesign --force --options runtime --timestamp --sign \"Developer ID Application: ...\" \"$APP_PATH/Contents/MacOS/ohm-thawd\""
  fi
  echo "    [dry-run] codesign --force --options runtime --timestamp --entitlements \"$EXPANDED_APP_ENTITLEMENTS\" --sign \"Developer ID Application: ...\" \"$APP_PATH\""

  echo "==> [4/5] Dry-run: Notarization ve stapler adımları simüle ediliyor (yazdırılıyor):"
  echo "    [dry-run] xcrun notarytool store-credentials ohm-ci --apple-id \"\$NOTARY_APPLE_ID\" --team-id \"\$NOTARY_TEAM_ID\" --password \"<REDACTED>\" --keychain \"\$KEYCHAIN_PATH\""
  echo "    [dry-run] xcrun notarytool submit \"$ZIP_PATH\" --keychain-profile ohm-ci --keychain \"\$KEYCHAIN_PATH\" --wait"
  echo "    [dry-run] xcrun stapler staple \"$APP_PATH\""

elif [ "$PACKAGE_MODE" = "preview" ]; then
  # Preview release modu: Developer ID secrets yok, önizleme sürümü paketlenir
  echo "==> [3/5] Preview modu: Developer ID ve notarization kimlik bilgileri tanımlı değil."
  echo "    Önizleme sürümü paketleniyor..."

  LOCAL_DEV_IDENTITY=""
  if command -v security >/dev/null 2>&1; then
    LOCAL_DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Apple Development" | head -n1 | awk '{print $2}' || true)
  fi
  PREVIEW_SIGN_IDENTITY="${PREVIEW_SIGN_IDENTITY:-${LOCAL_DEV_IDENTITY:--}}"

  if [ "$PREVIEW_SIGN_IDENTITY" != "-" ]; then
    echo "    İmzalama: Yerel Apple Development kimliği (${PREVIEW_SIGN_IDENTITY}) kullanılıyor."
  else
    echo "    İmzalama: Ad-hoc imza (codesign --sign -) kullanılıyor."
  fi

  # İçten dışa imzalama (--options runtime ve açılmış entitlement'lar ile)
  if [ -d "$APP_PATH/Contents/PlugIns/OhmWidget.appex" ]; then
    codesign --force --options runtime \
      --entitlements "$EXPANDED_WIDGET_ENTITLEMENTS" \
      --sign "$PREVIEW_SIGN_IDENTITY" "$APP_PATH/Contents/PlugIns/OhmWidget.appex"
  fi
  if [ -f "$APP_PATH/Contents/Helpers/ohm" ]; then
    codesign --force --options runtime \
      --sign "$PREVIEW_SIGN_IDENTITY" "$APP_PATH/Contents/Helpers/ohm"
  fi
  if [ -f "$APP_PATH/Contents/MacOS/ohm-thawd" ]; then
    codesign --force --options runtime \
      --sign "$PREVIEW_SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/ohm-thawd"
  fi
  codesign --force --options runtime \
    --entitlements "$EXPANDED_APP_ENTITLEMENTS" \
    --sign "$PREVIEW_SIGN_IDENTITY" "$APP_PATH"

  echo "==> Verifying signature and entitlements..."
  codesign --verify --verbose=2 "$APP_PATH"

  if ! codesign -d --entitlements - --xml "$APP_PATH" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in Ohm.app" >&2
    exit 1
  fi
  if ! codesign -d --entitlements - --xml "$APP_PATH/Contents/PlugIns/OhmWidget.appex" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in OhmWidget.appex" >&2
    exit 1
  fi
  echo "    ✔ Entitlements verified: ${TEAM_ID}.dev.ohm present in preview bundle."

  echo "==> [4/5] Preview modu: Notarization atlandı (ücretsiz hesap / Personal Team)."

else
  # Canlı signed release modu: Developer ID ve Notarization
  echo "==> [2/5b] Canlı Signed Release modu: Sertifika ve kimlik bilgileri yükleniyor..."

  # Geçici anahtarlık oluştur ve sertifikayı içe aktar
  KEYCHAIN_PATH="$(mktemp -t ohm-build.XXXXXX).keychain-db"
  KEYCHAIN_PWD="$(head -c 32 /dev/urandom | base64)"
  security create-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN_PATH"

  P12_TEMP="$(mktemp -t ohm-cert.XXXXXX).p12"
  echo "$DEVELOPER_ID_CERT_P12_BASE64" | base64 --decode > "$P12_TEMP"
  security import "$P12_TEMP" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  rm -f "$P12_TEMP"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PWD" "$KEYCHAIN_PATH" >/dev/null 2>&1

  security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_KEYCHAINS

  SIGNING_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -o 'Developer ID Application: [^"]*' | head -n1 || true)
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "Error: Developer ID Application identity not found in imported keychain." >&2
    exit 1
  fi

  # Rev 1 Point 2: İçten dışa Developer ID ile imzalama (--deep olmadan)
  echo "==> [3/5] Signing inner components and app with Developer ID (inside-out, no --deep)..."
  # 1. PlugIn (OhmWidget)
  if [ -d "$APP_PATH/Contents/PlugIns/OhmWidget.appex" ]; then
    codesign --force --options runtime --timestamp \
      --entitlements "$EXPANDED_WIDGET_ENTITLEMENTS" \
      --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/PlugIns/OhmWidget.appex"
  fi
  # 2. Helper binaries
  if [ -f "$APP_PATH/Contents/Helpers/ohm" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/Helpers/ohm"
  fi
  if [ -f "$APP_PATH/Contents/MacOS/ohm-thawd" ]; then
    codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/MacOS/ohm-thawd"
  fi
  # 3. Main Application Bundle
  codesign --force --options runtime --timestamp \
    --entitlements "$EXPANDED_APP_ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" "$APP_PATH"

  # Rev 1 Point 1: Entitlement doğrulama
  echo "==> Verifying entitlements (<TEAM>.dev.ohm)..."
  if ! codesign -d --entitlements - --xml "$APP_PATH" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in Ohm.app" >&2
    exit 1
  fi
  if ! codesign -d --entitlements - --xml "$APP_PATH/Contents/PlugIns/OhmWidget.appex" 2>&1 | grep -q "${TEAM_ID}\.dev\.ohm"; then
    echo "Error: Entitlement verification failed: ${TEAM_ID}.dev.ohm not found in OhmWidget.appex" >&2
    exit 1
  fi

  echo "==> Verifying signature..."
  codesign --verify --strict --verbose=2 "$APP_PATH"

  # Rev 1 Point 3: notarytool store-credentials ve submit --keychain-profile
  echo "==> [4/5] Storing notary credentials and submitting to notarytool..."
  xcrun notarytool store-credentials ohm-ci \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_APP_PASSWORD" \
    --keychain "$KEYCHAIN_PATH"

  PRE_NOTARIZE_ZIP="$BUILD_DIR/Ohm-pre-notarize.zip"
  ditto -c -k --keepParent "$APP_PATH" "$PRE_NOTARIZE_ZIP"

  xcrun notarytool submit "$PRE_NOTARIZE_ZIP" \
    --keychain-profile ohm-ci \
    --keychain "$KEYCHAIN_PATH" \
    --wait
  rm -f "$PRE_NOTARIZE_ZIP"

  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"
fi

# [5/5] Zip arşivi ve SHA-256 oluşturma
echo "==> [5/5] Creating release zip archive and SHA-256 checksum..."
rm -f "$ZIP_PATH" "$SHA256_PATH" "$ZIP_SHA256_PATH"

if [ "$PACKAGE_MODE" = "preview" ]; then
  FIRST_RUN_SRC="$REPO_ROOT/packaging/preview/FIRST-RUN.md"
  if [ ! -f "$FIRST_RUN_SRC" ]; then
    echo "Error: $FIRST_RUN_SRC not found." >&2
    exit 1
  fi
  PREVIEW_STAGE="$BUILD_DIR/preview_stage"
  rm -rf "$PREVIEW_STAGE"
  mkdir -p "$PREVIEW_STAGE"
  cp -R "$APP_PATH" "$PREVIEW_STAGE/Ohm.app"
  cp "$FIRST_RUN_SRC" "$PREVIEW_STAGE/FIRST-RUN.md"
  if [ -f "$REPO_ROOT/packaging/preview/FIRST-RUN.tr.md" ]; then
    cp "$REPO_ROOT/packaging/preview/FIRST-RUN.tr.md" "$PREVIEW_STAGE/FIRST-RUN.tr.md"
  fi
  (cd "$PREVIEW_STAGE" && ditto -c -k . "$ZIP_PATH")
  rm -rf "$PREVIEW_STAGE"
else
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
fi

(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$SHA256_PATH")")
cp "$SHA256_PATH" "$ZIP_SHA256_PATH"

echo ""
echo "=== Release Paketi Bilgisi ==="
echo "Mod:     $PACKAGE_MODE"
echo "Sürüm:   $VERSION"
echo "Arşiv:   $ZIP_PATH"
echo "SHA-256: $(cat "$SHA256_PATH")"
echo ""
echo "=== Arşiv İçeriği Doğrulaması ==="
ZIP_CONTENTS=$(unzip -l "$ZIP_PATH")
echo "$ZIP_CONTENTS" | grep -E "Ohm\.app/Contents/(Helpers/ohm|PlugIns/OhmWidget\.appex)" || {
  echo "Error: Required components missing in release archive." >&2
  exit 1
}
if [ "$PACKAGE_MODE" = "preview" ]; then
  echo "$ZIP_CONTENTS" | grep "FIRST-RUN.md" >/dev/null || {
    echo "Error: FIRST-RUN.md missing in preview release archive." >&2
    exit 1
  }
  echo "    ✔ FIRST-RUN.md verified inside preview archive."
fi

echo "Release paketleme başarıyla tamamlandı (exit 0)."
