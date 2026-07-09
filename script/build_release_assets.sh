#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

project_value() {
  local key="$1"
  awk -F': *' -v key="$key" '$1 ~ key { gsub(/"/, "", $2); print $2; exit }' "$ROOT_DIR/project.yml"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

codesign_identity_exists() {
  local identity="$1"
  [[ "$identity" == "-" ]] && return 0
  security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$identity\""
}

sparkle_attribute() {
  local file="$1"
  local attribute="$2"
  sed -n "s/.*$attribute=\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

release_notes_for_version() {
  awk -v version="$VERSION" '
    $0 == "## " version { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$ROOT_DIR/CHANGELOG.md"
}

prepend_appcast_item() {
  local appcast="$1"
  local item_file="$2"
  local stripped_appcast
  local updated_appcast

  if [[ ! -f "$appcast" ]]; then
    cat > "$appcast" <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Surge Relay</title>
    </channel>
</rss>
XML
  fi

  stripped_appcast="$(mktemp)"
  updated_appcast="$(mktemp)"
  awk -v version="$VERSION" '
    /<item>/ {
      in_item = 1
      item = $0 "\n"
      next
    }
    in_item {
      item = item $0 "\n"
      if ($0 ~ /<\/item>/) {
        if (item !~ "<title>" version "</title>") {
          printf "%s", item
        }
        in_item = 0
        item = ""
      }
      next
    }
    { print }
  ' "$appcast" > "$stripped_appcast"

  awk -v item_file="$item_file" '
    /<channel>/ {
      print
      in_channel = 1
      next
    }
    in_channel && /<title>.*<\/title>/ {
      print
      while ((getline line < item_file) > 0) {
        print line
      }
      close(item_file)
      in_channel = 0
      next
    }
    { print }
  ' "$stripped_appcast" > "$updated_appcast"
  mv "$updated_appcast" "$appcast"
  rm -f "$stripped_appcast"
}

update_appcast() {
  local signature_file="$ZIP_PATH.sparkle.txt"
  local signature
  local length
  local notes
  local item_file
  local pub_date
  local link
  local enclosure_url

  [[ "$UPDATE_APPCAST" == "1" ]] || return 0
  [[ -f "$signature_file" ]] || fail "cannot update appcast without $(basename "$signature_file")"

  signature="$(sparkle_attribute "$signature_file" 'sparkle:edSignature')"
  length="$(stat -f '%z' "$ZIP_PATH")"
  [[ -n "$signature" ]] || fail "missing Sparkle EdDSA signature for app zip"

  notes="$(release_notes_for_version)"
  [[ -n "$notes" ]] || notes="- Surge Relay $VERSION"
  pub_date="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
  link="https://github.com/$APPCAST_REPOSITORY/releases/tag/v$VERSION"
  enclosure_url="https://github.com/$APPCAST_REPOSITORY/releases/download/v$VERSION/Surge-Relay-$VERSION.app.zip"
  item_file="$(mktemp)"

  {
    echo "        <item>"
    echo "            <title>$VERSION</title>"
    echo "            <pubDate>$pub_date</pubDate>"
    printf '            <link>'
    printf '%s' "$link" | xml_escape
    echo "</link>"
    echo "            <sparkle:version>$BUILD</sparkle:version>"
    echo "            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
    echo "            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>"
    echo '            <description sparkle:format="markdown"><![CDATA[# Surge Relay '"$VERSION"
    echo
    printf '%s\n' "$notes" | sed 's/]]>/]]]]><![CDATA[>/g'
    echo "]]></description>"
    printf '            <enclosure url="'
    printf '%s' "$enclosure_url" | xml_escape
    printf '" length="%s" type="application/zip" sparkle:edSignature="' "$length"
    printf '%s' "$signature" | xml_escape
    echo '"/>'
    echo "        </item>"
  } > "$item_file"

  prepend_appcast_item "$APPCAST_PATH" "$item_file"
  rm -f "$item_file"
  echo "Updated appcast: $APPCAST_PATH"
}

PROJECT_VERSION="$(project_value MARKETING_VERSION)"
PROJECT_BUILD="$(project_value CURRENT_PROJECT_VERSION)"
VERSION="${VERSION:-$PROJECT_VERSION}"
BUILD="${BUILD:-$PROJECT_BUILD}"
DERIVED_DATA="$ROOT_DIR/build/DerivedDataRelease"
SOURCE_PACKAGES="$ROOT_DIR/build/SourcePackages"
DIST_DIR="$ROOT_DIR/dist/release-v$VERSION"
ARTIFACT_DIR="$DIST_DIR/artifacts"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-junchan0412.SurgeRelay}"
SPARKLE_ED_KEY="${SPARKLE_ED_KEY:-}"
SKIP_SPARKLE_SIGNING="${SKIP_SPARKLE_SIGNING:-0}"
REQUIRE_SPARKLE_SIGNATURES="${REQUIRE_SPARKLE_SIGNATURES:-1}"
RUN_LAUNCH_SMOKE_TEST="${RUN_LAUNCH_SMOKE_TEST:-0}"
SPARKLE_SIGN_UPDATE="$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Surge Relay Self-Signed Code Signing}"
REQUIRE_STABLE_CODESIGN="${REQUIRE_STABLE_CODESIGN:-0}"
RELEASE_ENTITLEMENTS="${RELEASE_ENTITLEMENTS:-$ROOT_DIR/SurgeRelay/SurgeRelay.entitlements}"
UPDATE_APPCAST="${UPDATE_APPCAST:-0}"
VERIFY_APPCAST="${VERIFY_APPCAST:-$UPDATE_APPCAST}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/appcast.xml}"
APPCAST_REPOSITORY="${APPCAST_REPOSITORY:-junchan0412/SurgeRelay-macOS}"

[[ -n "$PROJECT_VERSION" ]] || fail "project.yml is missing MARKETING_VERSION"
[[ -n "$PROJECT_BUILD" ]] || fail "project.yml is missing CURRENT_PROJECT_VERSION"
[[ "$VERSION" == "$PROJECT_VERSION" ]] \
  || fail "VERSION '$VERSION' does not match project MARKETING_VERSION '$PROJECT_VERSION'"
[[ "$BUILD" == "$PROJECT_BUILD" ]] \
  || fail "BUILD '$BUILD' does not match project CURRENT_PROJECT_VERSION '$PROJECT_BUILD'"
grep -Fq "MARKETING_VERSION = $PROJECT_VERSION;" "$ROOT_DIR/Surge Relay.xcodeproj/project.pbxproj" \
  || fail "Xcode project MARKETING_VERSION is not synced with project.yml ($PROJECT_VERSION)"
grep -Fq "CURRENT_PROJECT_VERSION = $PROJECT_BUILD;" "$ROOT_DIR/Surge Relay.xcodeproj/project.pbxproj" \
  || fail "Xcode project CURRENT_PROJECT_VERSION is not synced with project.yml ($PROJECT_BUILD)"

if [[ -d "/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer}"
elif [[ -d "/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer}"
fi

if ! xcodebuild \
  -project "$ROOT_DIR/Surge Relay.xcodeproj" \
  -list \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" >/dev/null 2>&1; then
  echo "Xcode is not ready for command-line builds." >&2
  echo "Run this once in Terminal, then re-run this script:" >&2
  echo "  DEVELOPER_DIR='${DEVELOPER_DIR:-}' sudo --preserve-env=DEVELOPER_DIR xcodebuild -license accept" >&2
  exit 69
fi

if [[ "$SKIP_SPARKLE_SIGNING" != "1" && -z "$SPARKLE_ED_KEY" ]]; then
  if ! security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1; then
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

SIGN_IDENTITY="$CODESIGN_IDENTITY"
if ! codesign_identity_exists "$SIGN_IDENTITY"; then
  if [[ "$REQUIRE_STABLE_CODESIGN" == "1" ]]; then
    echo "Code signing identity '$SIGN_IDENTITY' was not found." >&2
    echo "Create it with script/create_self_signed_codesign_identity.sh or import the release .p12 first." >&2
    exit 66
  fi
  echo "Code signing identity '$SIGN_IDENTITY' was not found; falling back to ad-hoc signing for preview assets." >&2
  SIGN_IDENTITY="-"
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

codesign_nested_args=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
codesign_app_args=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign_nested_args+=(--options runtime)
  codesign_app_args+=(--options runtime)
  if [[ -n "$RELEASE_ENTITLEMENTS" ]]; then
    [[ -f "$RELEASE_ENTITLEMENTS" ]] \
      || fail "release entitlements file does not exist: $RELEASE_ENTITLEMENTS"
    codesign_app_args+=(--entitlements "$RELEASE_ENTITLEMENTS")
  fi
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
    [[ -e "$item" ]] && codesign "${codesign_nested_args[@]}" "$item"
  done
fi
codesign "${codesign_app_args[@]}" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="$ARTIFACT_DIR/Surge-Relay-$VERSION.app.zip"
ditto -c -k --keepParent --norsrc --noextattr --zlibCompressionLevel 9 "$APP_PATH" "$ZIP_PATH"

PKG_ROOT="$DIST_DIR/pkg-root"
PKG_SCRIPTS="$DIST_DIR/pkg-scripts"
mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"
ditto --norsrc --noextattr "$APP_PATH" "$PKG_ROOT/Applications/Surge Relay.app"
cat > "$PKG_SCRIPTS/preinstall" <<'SCRIPT'
#!/bin/sh
/usr/bin/osascript -e 'tell application id "com.allenmiao.SurgeRelay" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  if ! /usr/bin/pgrep -x "Surge Relay" >/dev/null 2>&1; then
    exit 0
  fi
  /bin/sleep 1
done
/usr/bin/pkill -x "Surge Relay" >/dev/null 2>&1 || true
exit 0
SCRIPT
cat > "$PKG_SCRIPTS/postinstall" <<'SCRIPT'
#!/bin/sh
target_volume="${3:-/}"
if [ -z "$target_volume" ] || [ "$target_volume" = "/" ]; then
  app_path="/Applications/Surge Relay.app"
else
  app_path="${target_volume%/}/Applications/Surge Relay.app"
fi
/usr/bin/xattr -cr "$app_path" 2>/dev/null || true
exit 0
SCRIPT
chmod 755 "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

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

update_appcast

verify_args=(
  --version "$VERSION"
  --build "$BUILD"
  --artifact-dir "$ARTIFACT_DIR"
)
if [[ "$RUN_LAUNCH_SMOKE_TEST" == "1" ]]; then
  verify_args+=(--launch-smoke-test)
fi
if [[ "$VERIFY_APPCAST" == "1" ]]; then
  verify_args+=(--appcast "$APPCAST_PATH")
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  EXPECT_ADHOC_SIGNATURE=1 "$ROOT_DIR/script/verify_release_assets.sh" "${verify_args[@]}"
else
  EXPECT_ADHOC_SIGNATURE=0 EXPECTED_CODESIGN_AUTHORITY="$SIGN_IDENTITY" \
    "$ROOT_DIR/script/verify_release_assets.sh" "${verify_args[@]}"
fi

echo "Artifacts written to $ARTIFACT_DIR"
ls -lh "$ARTIFACT_DIR"
