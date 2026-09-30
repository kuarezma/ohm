#!/usr/bin/env bash
# scripts/ci/build-test.sh — Ohm CI derleme ve test betiği
# Kapsam: xcodegen ile proje üretimi, OhmCore birim testleri ve Debug derleme.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/ci"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Generating Xcode project with xcodegen ==="
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required but not installed." >&2
  exit 1
fi
(cd "$REPO_ROOT/app" && xcodegen generate)

echo "=== [2/3] Running Swift unit tests (OhmCore) ==="
TEST_LOG="$BUILD_DIR/swift-test.log"
(cd "$REPO_ROOT/app/OhmCore" && swift test) 2>&1 | tee "$TEST_LOG"

# Test özet satırlarını yakala
TEST_SUMMARY=$(grep -E "(Test run with [0-9]+ tests in [0-9]+ suite.* passed after|Suite .* passed after)" "$TEST_LOG" || true)

echo "=== [3/3] Building Ohm (Debug configuration) ==="
XCODEBUILD_ARGS=()
if [ ! -f "$REPO_ROOT/app/Local.xcconfig" ] && [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "Notice: Local.xcconfig not found and DEVELOPMENT_TEAM not set. Disabling signing for Debug build."
  XCODEBUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
fi

BUILD_LOG="$BUILD_DIR/xcodebuild-debug.log"
if [ ${#XCODEBUILD_ARGS[@]} -gt 0 ]; then
  xcodebuild -project "$REPO_ROOT/app/Ohm.xcodeproj" \
    -scheme Ohm \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    "${XCODEBUILD_ARGS[@]}" \
    build 2>&1 | tee "$BUILD_LOG"
else
  xcodebuild -project "$REPO_ROOT/app/Ohm.xcodeproj" \
    -scheme Ohm \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    build 2>&1 | tee "$BUILD_LOG"
fi

echo ""
echo "=== Test ve Derleme Özeti ==="
if [ -n "$TEST_SUMMARY" ]; then
  echo "$TEST_SUMMARY"
fi
echo "** BUILD SUCCEEDED **"
