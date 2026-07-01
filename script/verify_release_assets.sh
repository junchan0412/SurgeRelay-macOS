#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

project_value() {
  local key="$1"
  awk -F': *' -v key="$key" '$1 ~ key { gsub(/"/, "", $2); print $2; exit }' "$ROOT_DIR/project.yml"
}

VERSION="${VERSION:-$(project_value MARKETING_VERSION)}"
BUILD="${BUILD:-$(project_value CURRENT_PROJECT_VERSION)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"
APPCAST_PATH=""
REQUIRE_SPARKLE_SIGNATURES="${REQUIRE_SPARKLE_SIGNATURES:-1}"
EXPECT_ADHOC_SIGNATURE="${EXPECT_ADHOC_SIGNATURE:-1}"
PKG_SIGNATURE_MODE="${PKG_SIGNATURE_MODE:-unsigned}"

usage() {
  echo "Usage: $0 [--version VERSION] [--build BUILD] [--artifact-dir DIR] [--appcast PATH]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || usage
      VERSION="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || usage
      BUILD="$2"
      shift 2
      ;;
    --artifact-dir)
      [[ $# -ge 2 ]] || usage
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --appcast)
      [[ $# -ge 2 ]] || usage
      APPCAST_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$ARTIFACT_DIR" ]]; then
  ARTIFACT_DIR="$ROOT_DIR/dist/release-v$VERSION/artifacts"
fi

APP_NAME="Surge Relay"
APP_ZIP="$ARTIFACT_DIR/Surge-Relay-$VERSION.app.zip"
APP_ZIP_SHA="$APP_ZIP.sha256"
APP_ZIP_SPARKLE="$APP_ZIP.sparkle.txt"
PKG_PATH="$ARTIFACT_DIR/Surge-Relay-$VERSION.pkg"
PKG_SHA="$PKG_PATH.sha256"
PKG_SPARKLE="$PKG_PATH.sparkle.txt"

fail() {
  echo "error: $*" >&2
  exit 1
}

ok() {
  echo "ok: $*"
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

plist_value() {
  plutil -extract "$1" raw -o - "$2" | tr -d '\n'
}

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  [[ "$actual" == "$expected" ]] || fail "$label expected '$expected', got '$actual'"
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label does not contain '$needle'"
}

sparkle_attribute() {
  local file="$1"
  local attribute="$2"
  sed -n "s/.*$attribute=\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

verify_sparkle_signature() {
  local artifact="$1"
  local signature_file="$2"
  local actual_length
  local signed_length
  local signature

  require_file "$signature_file"
  actual_length="$(stat -f '%z' "$artifact")"
  signed_length="$(sparkle_attribute "$signature_file" length)"
  signature="$(sparkle_attribute "$signature_file" 'sparkle:edSignature')"

  assert_equal "$(basename "$signature_file") length" "$actual_length" "$signed_length"
  [[ -n "$signature" ]] || fail "$(basename "$signature_file") missing sparkle:edSignature"
}

verify_app_bundle() {
  local app_path="$1"
  local version
  local build
  local archs
  local verify_output
  local signature_detail

  [[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
  version="$(plist_value CFBundleShortVersionString "$app_path/Contents/Info.plist")"
  build="$(plist_value CFBundleVersion "$app_path/Contents/Info.plist")"
  assert_equal "$app_path CFBundleShortVersionString" "$VERSION" "$version"
  assert_equal "$app_path CFBundleVersion" "$BUILD" "$build"

  if ! verify_output="$(codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1)"; then
    echo "$verify_output" >&2
    fail "$app_path code signature verification failed"
  fi
  signature_detail="$(codesign -dvvv "$app_path" 2>&1)"
  if [[ "$EXPECT_ADHOC_SIGNATURE" == "1" ]]; then
    assert_contains "$app_path signature" "Signature=adhoc" "$signature_detail"
  fi

  archs="$(lipo -archs "$app_path/Contents/MacOS/$APP_NAME")"
  assert_contains "$app_path architectures" "arm64" " $archs "
  assert_contains "$app_path architectures" "x86_64" " $archs "
}

verify_app_zip() {
  local tmp_dir="$1/app-zip"
  local app_path

  mkdir -p "$tmp_dir"
  ditto -x -k "$APP_ZIP" "$tmp_dir"
  app_path="$tmp_dir/$APP_NAME.app"
  verify_app_bundle "$app_path"
  ok "verified app zip bundle"
}

verify_pkg() {
  local tmp_dir="$1/pkg"
  local payload_app
  local postinstall
  local signature_output

  pkgutil --expand-full "$PKG_PATH" "$tmp_dir"
  payload_app="$(find "$tmp_dir" -path "*/Applications/$APP_NAME.app" -type d -print -quit)"
  [[ -n "$payload_app" ]] || fail "pkg payload missing $APP_NAME.app"
  verify_app_bundle "$payload_app"

  postinstall="$(find "$tmp_dir" -path "*/Scripts/postinstall" -type f -print -quit)"
  [[ -n "$postinstall" ]] || fail "pkg missing postinstall script"
  grep -Fq '/usr/bin/xattr -cr "/Applications/Surge Relay.app"' "$postinstall" \
    || fail "pkg postinstall does not clear quarantine"

  signature_output="$(pkgutil --check-signature "$PKG_PATH" 2>&1 || true)"
  if [[ "$PKG_SIGNATURE_MODE" == "unsigned" ]]; then
    assert_contains "pkg signature" "Status: no signature" "$signature_output"
  fi
  ok "verified pkg payload and postinstall"
}

verify_appcast() {
  local title
  local sparkle_version
  local short_version
  local enclosure_url
  local enclosure_length
  local enclosure_signature
  local expected_signature
  local expected_length

  [[ -n "$APPCAST_PATH" ]] || return 0
  require_file "$APPCAST_PATH"
  xmllint --noout "$APPCAST_PATH"

  title="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='title'])" "$APPCAST_PATH")"
  sparkle_version="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='version'])" "$APPCAST_PATH")"
  short_version="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='shortVersionString'])" "$APPCAST_PATH")"
  enclosure_url="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='enclosure']/@url)" "$APPCAST_PATH")"
  enclosure_length="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='enclosure']/@length)" "$APPCAST_PATH")"
  enclosure_signature="$(xmllint --xpath "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$APPCAST_PATH")"

  expected_length="$(stat -f '%z' "$PKG_PATH")"
  expected_signature="$(sparkle_attribute "$PKG_SPARKLE" 'sparkle:edSignature')"
  assert_equal "appcast latest title" "$VERSION" "$title"
  assert_equal "appcast sparkle:version" "$BUILD" "$sparkle_version"
  assert_equal "appcast shortVersionString" "$VERSION" "$short_version"
  assert_contains "appcast enclosure url" "/v$VERSION/Surge-Relay-$VERSION.pkg" "$enclosure_url"
  assert_equal "appcast enclosure length" "$expected_length" "$enclosure_length"
  assert_equal "appcast enclosure edSignature" "$expected_signature" "$enclosure_signature"
  ok "verified appcast latest item"
}

[[ -n "$VERSION" ]] || fail "empty version"
[[ -n "$BUILD" ]] || fail "empty build number"
require_file "$APP_ZIP"
require_file "$APP_ZIP_SHA"
require_file "$PKG_PATH"
require_file "$PKG_SHA"

(
  cd "$ARTIFACT_DIR"
  shasum -a 256 -c "$(basename "$APP_ZIP_SHA")"
  shasum -a 256 -c "$(basename "$PKG_SHA")"
) >/dev/null
ok "verified sha256 files"

if [[ "$REQUIRE_SPARKLE_SIGNATURES" == "1" ]]; then
  verify_sparkle_signature "$APP_ZIP" "$APP_ZIP_SPARKLE"
  verify_sparkle_signature "$PKG_PATH" "$PKG_SPARKLE"
  ok "verified Sparkle signatures"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

verify_app_zip "$TMP_DIR"
verify_pkg "$TMP_DIR"
verify_appcast

ok "release assets verified for $VERSION ($BUILD)"
