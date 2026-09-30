#!/usr/bin/env bash
# scripts/ci/release.sh — Ohm Release paketleme ve notarization betiği
# Kapsam: Release derlemesi, Developer ID imzalama, notarization, stapling ve zip paketleme.
# --dry-run: Açılmış entitlement ile ad-hoc Release, zip, SHA-256, sürüm ve entitlement doğrulaması;
#            notarytool/Developer ID imza adımlarını yazdırır.

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

echo "=== Ohm Release Paketleme (Sürüm: ${VERSION}, Team: ${TEAM_ID}) ==="

# [1/5] XcodeGen ile projeyi güncelle
echo "==> [1/5] Generating Xcode project with xcodegen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required but not installed." >&2
  exit 1
fi
(cd "$REPO_ROOT/app" && xcodegen generate)

DERIVED_DATA="$BUILD_DIR/DerivedDataRelease"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Ohm.app"
ZIP_PATH="$BUILD_DIR/Ohm-${VERSION}.zip"
SHA256_PATH="$BUILD_DIR/Ohm-${VERSION}.sha256"
ZIP_SHA256_PATH="$BUILD_DIR/Ohm-${VERSION}.zip.sha256"

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

if [ "$DRY_RUN" = true ]; then
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

else
  # Canlı release modu: Secrets kontrolü
  echo "==> [2/5] Canlı Release modu: Kimlik bilgileri kontrol ediliyor..."
  if [ -z "${DEVELOPER_ID_CERT_P12_BASE64:-}" ] || [ -z "${DEVELOPER_ID_CERT_PASSWORD:-}" ] || \
     [ -z "${NOTARY_APPLE_ID:-}" ] || [ -z "${NOTARY_TEAM_ID:-}" ] || [ -z "${NOTARY_APP_PASSWORD:-}" ]; then
    echo "Notice: Developer ID certificate or notarization credentials are not set."
    echo "Skipping Developer ID signing and notarization (secrets yoksa açık mesajla atla)."
    echo "Run with --dry-run for local/uncredentialed release packaging."
    exit 0
  fi

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
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$SHA256_PATH")")
cp "$SHA256_PATH" "$ZIP_SHA256_PATH"

echo ""
echo "=== Release Paketi Bilgisi ==="
echo "Sürüm:   $VERSION"
echo "Arşiv:   $ZIP_PATH"
echo "SHA-256: $(cat "$SHA256_PATH")"
echo ""
echo "=== Arşiv İçeriği Doğrulaması ==="
unzip -l "$ZIP_PATH" | grep -E "Ohm\.app/Contents/(Helpers/ohm|PlugIns/OhmWidget\.appex)" || {
  echo "Error: Required components missing in release archive." >&2
  exit 1
}

echo "Release paketleme başarıyla tamamlandı (exit 0)."
