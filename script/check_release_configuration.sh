#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/project.yml"
XCODE_PROJECT="$ROOT_DIR/Surge Relay.xcodeproj/project.pbxproj"
INFO_PLIST="$ROOT_DIR/SurgeRelay/Info.plist"
ENTITLEMENTS="$ROOT_DIR/SurgeRelay/SurgeRelay.entitlements"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/appcast.xml}"
WORKFLOW_PATH="$ROOT_DIR/.github/workflows/package-release-app.yml"
TAG="${TAG:-}"
VERSION="${VERSION:-}"
BUILD="${BUILD:-}"

usage() {
  echo "Usage: $0 [--tag TAG] [--version VERSION] [--build BUILD] [--appcast PATH]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || usage
      TAG="$2"
      shift 2
      ;;
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

require_executable() {
  [[ -x "$1" ]] || fail "script is not executable: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  grep -Fq "$needle" "$file" || fail "$label missing '$needle'"
}

project_value() {
  local key="$1"
  awk -F': *' -v key="$key" '$1 ~ key { gsub(/"/, "", $2); print $2; exit }' "$PROJECT_FILE"
}

plist_raw_value() {
  plutil -extract "$1" raw -o - "$2" | tr -d '\n'
}

appcast_value() {
  local xpath="$1"
  xmllint --xpath "$xpath" "$APPCAST_PATH" 2>/dev/null | tr -d '\n'
}

require_file "$PROJECT_FILE"
require_file "$XCODE_PROJECT"
require_file "$INFO_PLIST"
require_file "$ENTITLEMENTS"
require_file "$WORKFLOW_PATH"

PROJECT_VERSION="$(project_value MARKETING_VERSION)"
PROJECT_BUILD="$(project_value CURRENT_PROJECT_VERSION)"
[[ -n "$PROJECT_VERSION" ]] || fail "project.yml is missing MARKETING_VERSION"
[[ -n "$PROJECT_BUILD" ]] || fail "project.yml is missing CURRENT_PROJECT_VERSION"

if [[ -n "$TAG" ]]; then
  TAG_VERSION="${TAG#v}"
  [[ -n "$VERSION" || "$TAG_VERSION" == "$PROJECT_VERSION" ]] \
    || fail "tag '$TAG' does not match project MARKETING_VERSION '$PROJECT_VERSION'"
fi

VERSION="${VERSION:-$PROJECT_VERSION}"
BUILD="${BUILD:-$PROJECT_BUILD}"
[[ "$VERSION" == "$PROJECT_VERSION" ]] \
  || fail "VERSION '$VERSION' does not match project MARKETING_VERSION '$PROJECT_VERSION'"
[[ "$BUILD" == "$PROJECT_BUILD" ]] \
  || fail "BUILD '$BUILD' does not match project CURRENT_PROJECT_VERSION '$PROJECT_BUILD'"

require_contains "$XCODE_PROJECT" "MARKETING_VERSION = $PROJECT_VERSION;" "Xcode project version"
require_contains "$XCODE_PROJECT" "CURRENT_PROJECT_VERSION = $PROJECT_BUILD;" "Xcode project build"
require_contains "$INFO_PLIST" '<key>SUFeedURL</key>' "Info.plist"
require_contains "$INFO_PLIST" '<key>SUPublicEDKey</key>' "Info.plist"
[[ "$(plist_raw_value CFBundleShortVersionString "$INFO_PLIST")" == '$(MARKETING_VERSION)' ]] \
  || fail "Info.plist CFBundleShortVersionString should use \$(MARKETING_VERSION)"
[[ "$(plist_raw_value CFBundleVersion "$INFO_PLIST")" == '$(CURRENT_PROJECT_VERSION)' ]] \
  || fail "Info.plist CFBundleVersion should use \$(CURRENT_PROJECT_VERSION)"
[[ -n "$(plist_raw_value SUFeedURL "$INFO_PLIST")" ]] || fail "Info.plist SUFeedURL is empty"
[[ -n "$(plist_raw_value SUPublicEDKey "$INFO_PLIST")" ]] || fail "Info.plist SUPublicEDKey is empty"
require_contains "$ENTITLEMENTS" '<key>com.apple.security.cs.disable-library-validation</key>' "release entitlements"
ok "verified version, Sparkle, and entitlement configuration"

require_contains "$ROOT_DIR/CHANGELOG.md" "## $VERSION" "CHANGELOG.md"
ok "verified changelog section for $VERSION"

require_command node
for resource in \
  "$ROOT_DIR/SurgeRelay/WebResources/web-logic.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-options.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-format.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-markup.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-api.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-state.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-editor.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/web-feedback.js" \
  "$ROOT_DIR/SurgeRelay/WebResources/app.js"
do
  require_file "$resource"
  node --check "$resource" >/dev/null
done

for web_test in \
  "$ROOT_DIR/script/test_web_resources.mjs" \
  "$ROOT_DIR/script/test_web_dom_resources.mjs"
do
  require_file "$web_test"
  node "$web_test"
done
ok "verified web resource syntax and behavior tests"

if [[ -f "$APPCAST_PATH" ]]; then
  xmllint --noout "$APPCAST_PATH"
  APPCAST_TITLE="$(appcast_value "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='title'])")"
  APPCAST_BUILD="$(appcast_value "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='version'])")"
  APPCAST_SHORT="$(appcast_value "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='shortVersionString'])")"
  APPCAST_URL="$(appcast_value "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='enclosure']/@url)")"
  APPCAST_SIGNATURE="$(appcast_value "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'][1]/*[local-name()='enclosure']/@*[local-name()='edSignature'])")"
  [[ "$APPCAST_TITLE" == "$VERSION" ]] || fail "appcast latest title '$APPCAST_TITLE' does not match $VERSION"
  [[ "$APPCAST_BUILD" == "$BUILD" ]] || fail "appcast latest sparkle:version '$APPCAST_BUILD' does not match $BUILD"
  [[ "$APPCAST_SHORT" == "$VERSION" ]] || fail "appcast latest shortVersionString '$APPCAST_SHORT' does not match $VERSION"
  [[ "$APPCAST_URL" == *"/v$VERSION/Surge-Relay-$VERSION.app.zip" ]] \
    || fail "appcast latest enclosure URL does not point at v$VERSION app zip"
  [[ -n "$APPCAST_SIGNATURE" ]] || fail "appcast latest enclosure is missing Sparkle EdDSA signature"
  ok "verified appcast latest item"
fi

for script in \
  "$ROOT_DIR/script/build_release_assets.sh" \
  "$ROOT_DIR/script/verify_release_assets.sh" \
  "$ROOT_DIR/script/verify_github_release_assets.sh" \
  "$ROOT_DIR/script/create_self_signed_codesign_identity.sh" \
  "$ROOT_DIR/script/create_sparkle_update_key.sh"
do
  require_file "$script"
  require_executable "$script"
  zsh -n "$script"
done
ok "verified release shell scripts"

require_contains "$WORKFLOW_PATH" 'CODESIGN_CERTIFICATE_P12_BASE64' "release workflow"
require_contains "$WORKFLOW_PATH" 'SPARKLE_ED_KEY' "release workflow"
require_contains "$WORKFLOW_PATH" './script/check_release_configuration.sh' "release workflow"
require_contains "$WORKFLOW_PATH" './script/build_release_assets.sh' "release workflow"
require_contains "$WORKFLOW_PATH" './script/verify_github_release_assets.sh' "release workflow"
require_contains "$WORKFLOW_PATH" 'REQUIRE_STABLE_CODESIGN=1' "release workflow"
require_contains "$WORKFLOW_PATH" 'REQUIRE_SPARKLE_SIGNATURES=1' "release workflow"
ok "verified release workflow references"

ok "release configuration preflight passed for $VERSION ($BUILD)"
