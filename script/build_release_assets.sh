#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.2.4}"
DERIVED_DATA="$ROOT_DIR/build/DerivedDataRelease"
SOURCE_PACKAGES="$ROOT_DIR/build/SourcePackages"
DIST_DIR="$ROOT_DIR/dist/release-v$VERSION"
ARTIFACT_DIR="$DIST_DIR/artifacts"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-junchan0412.SurgeRelay}"
SPARKLE_ED_KEY="${SPARKLE_ED_KEY:-}"
SKIP_SPARKLE_SIGNING="${SKIP_SPARKLE_SIGNING:-0}"
REQUIRE_SPARKLE_SIGNATURES="${REQUIRE_SPARKLE_SIGNATURES:-1}"
SPARKLE_SIGN_UPDATE="$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ -d "/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer}"
fi

if ! xcodebuild -project "$ROOT_DIR/Surge Relay.xcodeproj" -list >/dev/null 2>&1; then
  echo "Xcode is not ready for command-line builds." >&2
  echo "Run this once in Terminal, then re-run this script:" >&2
  echo "  DEVELOPER_DIR='${DEVELOPER_DIR:-}' sudo --preserve-env=DEVELOPER_DIR xcodebuild -license accept" >&2
  exit 69
fi

if [[ "$SKIP_SPARKLE_SIGNING" != "1" && -z "$SPARKLE_ED_KEY" ]]; then
  if ! security find-generic-password -s ed25519 -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
    if [[ "$REQUIRE_SPARKLE_SIGNATURES" == "1" ]]; then
      echo "Sparkle signing key '$SPARKLE_ACCOUNT' was not found in Keychain." >&2
      echo "Set SPARKLE_ED_KEY, set SPARKLE_ACCOUNT to an available Keychain account, or run unsigned preview builds with:" >&2
      echo "  SKIP_SPARKLE_SIGNING=1 REQUIRE_SPARKLE_SIGNATURES=0 $0" >&2
      exit 65
    fi
    echo "Sparkle signing key '$SPARKLE_ACCOUNT' was not found; skipping Sparkle signatures for preview assets." >&2
    SKIP_SPARKLE_SIGNING=1
  fi
fi

rm -rf "$DERIVED_DATA" "$DIST_DIR"
mkdir -p "$SOURCE_PACKAGES" "$ARTIFACT_DIR"

xcodebuild \
  -project "$ROOT_DIR/Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$(find "$DERIVED_DATA/Build/Products/Release" -maxdepth 1 -name "Surge Relay.app" -type d -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "Unable to locate built Surge Relay.app" >&2
  exit 1
fi

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE/Versions/B" ]]; then
  for item in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B"
  do
    [[ -e "$item" ]] && codesign --force --sign - --timestamp=none "$item"
  done
fi
codesign --force --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$ARTIFACT_DIR/Surge-Relay-$VERSION.app.zip"
ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 "$APP_PATH" "$ZIP_PATH"

PKG_ROOT="$DIST_DIR/pkg-root"
PKG_SCRIPTS="$DIST_DIR/pkg-scripts"
mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"
ditto "$APP_PATH" "$PKG_ROOT/Applications/Surge Relay.app"
cat > "$PKG_SCRIPTS/postinstall" <<'SCRIPT'
#!/bin/sh
/usr/bin/xattr -cr "/Applications/Surge Relay.app" 2>/dev/null || true
exit 0
SCRIPT
chmod 755 "$PKG_SCRIPTS/postinstall"

PKG_PATH="$ARTIFACT_DIR/Surge-Relay-$VERSION.pkg"
pkgbuild \
  --root "$PKG_ROOT" \
  --install-location "/" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "com.allenmiao.SurgeRelay.pkg" \
  --version "$VERSION" \
  "$PKG_PATH"

(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "Surge-Relay-$VERSION.app.zip" > "Surge-Relay-$VERSION.app.zip.sha256"
  shasum -a 256 "Surge-Relay-$VERSION.pkg" > "Surge-Relay-$VERSION.pkg.sha256"
)

if [[ "$SKIP_SPARKLE_SIGNING" != "1" && -x "$SPARKLE_SIGN_UPDATE" ]]; then
  if [[ -n "$SPARKLE_ED_KEY" ]]; then
    printf '%s' "$SPARKLE_ED_KEY" | "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$ZIP_PATH" > "$ZIP_PATH.sparkle.txt"
    printf '%s' "$SPARKLE_ED_KEY" | "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$PKG_PATH" > "$PKG_PATH.sparkle.txt"
  else
    "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP_PATH" > "$ZIP_PATH.sparkle.txt"
    "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$PKG_PATH" > "$PKG_PATH.sparkle.txt"
  fi
fi

"$ROOT_DIR/script/verify_release_assets.sh" \
  --version "$VERSION" \
  --artifact-dir "$ARTIFACT_DIR"

echo "Artifacts written to $ARTIFACT_DIR"
ls -lh "$ARTIFACT_DIR"
