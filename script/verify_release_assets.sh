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
EXPECTED_CODESIGN_AUTHORITY="${EXPECTED_CODESIGN_AUTHORITY:-}"
PKG_SIGNATURE_MODE="${PKG_SIGNATURE_MODE:-unsigned}"
RUN_LAUNCH_SMOKE_TEST="${RUN_LAUNCH_SMOKE_TEST:-0}"

usage() {
  echo "Usage: $0 [--version VERSION] [--build BUILD] [--artifact-dir DIR] [--appcast PATH] [--launch-smoke-test]" >&2
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
    --launch-smoke-test)
      RUN_LAUNCH_SMOKE_TEST=1
      shift
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

assert_ad_hoc_signature() {
  local code_path="$1"
  local signature_detail

  signature_detail="$(codesign -dvvv "$code_path" 2>&1)"
  assert_contains "$code_path signature" "Signature=adhoc" "$signature_detail"
  assert_contains "$code_path team identifier" "TeamIdentifier=not set" "$signature_detail"
}

assert_expected_codesign_authority() {
  local code_path="$1"
  local signature_detail

  signature_detail="$(codesign -dvvv "$code_path" 2>&1)"
  [[ "$signature_detail" != *"Signature=adhoc"* ]] \
    || fail "$code_path is ad-hoc signed, expected authority '$EXPECTED_CODESIGN_AUTHORITY'"
  assert_contains "$code_path authority" "Authority=$EXPECTED_CODESIGN_AUTHORITY" "$signature_detail"
}

verify_signature_inventory() {
  local app_path="$1"
  local code_path
  local autoupdate_path="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  local seen_file="$TMP_DIR/signature-inventory-seen"

  [[ "$EXPECT_ADHOC_SIGNATURE" == "1" || -n "$EXPECTED_CODESIGN_AUTHORITY" ]] || return 0
  : > "$seen_file"
  {
    echo "$app_path"
    find "$app_path/Contents" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" \) -type d -print
    [[ -f "$autoupdate_path" ]] && echo "$autoupdate_path"
  } | while IFS= read -r code_path; do
    [[ -n "$code_path" ]] || continue
    if grep -Fxq "$code_path" "$seen_file"; then
      continue
    fi
    echo "$code_path" >> "$seen_file"
    if [[ -n "$EXPECTED_CODESIGN_AUTHORITY" ]]; then
      assert_expected_codesign_authority "$code_path"
    else
      assert_ad_hoc_signature "$code_path"
    fi
  done
}

verify_self_signed_runtime_entitlements() {
  local app_path="$1"
  local signature_detail="$2"
  local entitlements

  [[ -n "$EXPECTED_CODESIGN_AUTHORITY" ]] || return 0
  [[ "$signature_detail" == *"TeamIdentifier=not set"* ]] || return 0
  [[ "$signature_detail" == *"Runtime Version="* ]] || return 0

  entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
  assert_contains "$app_path entitlements" "<key>com.apple.security.cs.disable-library-validation</key>" "$entitlements"
  assert_contains "$app_path entitlements" "<true/>" "$entitlements"
}

binary_rpaths() {
  local binary="$1"

  otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

dependency_resolves() {
  local dependency="$1"
  local binary="$2"
  local executable_dir
  local loader_dir
  local suffix
  local rpath
  local resolved_rpath
  local candidate

  executable_dir="$(dirname "$binary")"
  loader_dir="$executable_dir"
  case "$dependency" in
    @rpath/*)
      suffix="${dependency#@rpath/}"
      while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        resolved_rpath="${rpath//@executable_path/$executable_dir}"
        resolved_rpath="${resolved_rpath//@loader_path/$loader_dir}"
        candidate="$resolved_rpath/$suffix"
        [[ -e "$candidate" ]] && return 0
      done < <(binary_rpaths "$binary")
      return 1
      ;;
    @executable_path/*)
      suffix="${dependency#@executable_path/}"
      [[ -e "$executable_dir/$suffix" ]]
      ;;
    @loader_path/*)
      suffix="${dependency#@loader_path/}"
      [[ -e "$loader_dir/$suffix" ]]
      ;;
    /*)
      [[ "$dependency" == /System/* || "$dependency" == /usr/lib/* || -e "$dependency" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

verify_dynamic_library_linkage() {
  local app_path="$1"
  local binary="$app_path/Contents/MacOS/$APP_NAME"
  local dependencies
  local rpaths
  local dependency

  [[ -x "$binary" ]] || fail "missing executable: $binary"
  dependencies="$(otool -L "$binary" | awk '/^[[:space:]]/ { print $1 }')"
  if [[ "$dependencies" == *"@rpath/"* ]]; then
    rpaths="$(binary_rpaths "$binary" | tr '\n' ' ')"
    assert_contains "$binary rpaths" "@executable_path/../Frameworks" "$rpaths"
  fi
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    dependency_resolves "$dependency" "$binary" \
      || fail "$binary dependency does not resolve inside bundle or system paths: $dependency"
  done <<< "$dependencies"
  ok "verified dynamic library linkage"
}

verify_zip_metadata_clean() {
  local entries

  entries="$(zipinfo -1 "$APP_ZIP" | grep -E '(^|/)__MACOSX(/|$)|(^|/)\._' || true)"
  [[ -z "$entries" ]] || fail "app zip contains AppleDouble metadata: $(echo "$entries" | tr '\n' ' ')"
  ok "verified app zip metadata"
}

verify_no_quarantine_xattrs() {
  local app_path="$1"
  local label="$2"
  local matches

  matches="$(xattr -lr "$app_path" 2>/dev/null | grep -F 'com.apple.quarantine' || true)"
  [[ -z "$matches" ]] || fail "$label contains quarantine xattrs: $(echo "$matches" | head -5 | tr '\n' ' ')"
}

print_launch_smoke_diagnostics() {
  local label="$1"
  local app_path="$2"
  local existing_pids="$3"
  local current_pids="$4"
  local new_pids="$5"
  local diagnostic_dir="$HOME/Library/Logs/DiagnosticReports"
  local pid

  {
    echo "launch smoke diagnostics ($label):"
    echo "  app: $app_path"
    echo "  existing pids: $(tr '\n' ' ' < "$existing_pids" 2>/dev/null || true)"
    echo "  current pids: $(tr '\n' ' ' < "$current_pids" 2>/dev/null || true)"
    echo "  new pids: $(tr '\n' ' ' < "$new_pids" 2>/dev/null || true)"
    echo "  quarantine:"
    /usr/bin/xattr -p com.apple.quarantine "$app_path" 2>&1 | sed 's/^/    /' || echo "    not present"
    echo "  codesign:"
    /usr/bin/codesign -dvvv "$app_path" 2>&1 | sed -n '1,12p' | sed 's/^/    /' || true
    echo "  gatekeeper:"
    /usr/sbin/spctl -a -vv "$app_path" 2>&1 | sed 's/^/    /' || true
    echo "  matching processes:"
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      /bin/ps -p "$pid" -o pid=,stat=,command= 2>/dev/null | sed 's/^/    /' || true
    done < "$current_pids"
    if [[ -d "$diagnostic_dir" ]]; then
      echo "  recent crash reports:"
      find "$diagnostic_dir" -type f \( -name "$APP_NAME*.crash" -o -name "$APP_NAME*.ips" \) -mtime -1 -print 2>/dev/null \
        | tail -5 \
        | sed 's/^/    /'
    fi
  } >&2
}

launch_smoke_test() {
  local label="$1"
  local app_path="$2"
  local safe_label="${label// /-}"
  local existing_pids="$TMP_DIR/launch-smoke-existing-pids-$safe_label"
  local current_pids="$TMP_DIR/launch-smoke-current-pids-$safe_label"
  local new_pids="$TMP_DIR/launch-smoke-new-pids-$safe_label"
  local new_pid=""

  pgrep -x "$APP_NAME" > "$existing_pids" 2>/dev/null || true
  open -n "$app_path"
  for _ in {1..10}; do
    pgrep -x "$APP_NAME" > "$current_pids" 2>/dev/null || true
    grep -Fvx -f "$existing_pids" "$current_pids" > "$new_pids" 2>/dev/null || true
    if [[ -s "$new_pids" ]]; then
      new_pid="$(head -n 1 "$new_pids")"
      break
    fi
    sleep 1
  done
  if [[ -z "$new_pid" ]]; then
    print_launch_smoke_diagnostics "$label" "$app_path" "$existing_pids" "$current_pids" "$new_pids"
    fail "$label launch smoke test did not start a new $APP_NAME instance"
  fi
  sleep 3
  if ! kill -0 "$new_pid" 2>/dev/null; then
    print_launch_smoke_diagnostics "$label" "$app_path" "$existing_pids" "$current_pids" "$new_pids"
    fail "$label launch smoke test started $APP_NAME pid $new_pid, but it exited early"
  fi
  kill "$new_pid" 2>/dev/null || true
  ok "verified $label launch smoke test"
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
  verify_no_quarantine_xattrs "$app_path" "$app_path"
  signature_detail="$(codesign -dvvv "$app_path" 2>&1)"
  if [[ "$EXPECT_ADHOC_SIGNATURE" == "1" ]]; then
    assert_contains "$app_path signature" "Signature=adhoc" "$signature_detail"
  fi
  verify_signature_inventory "$app_path"
  verify_self_signed_runtime_entitlements "$app_path" "$signature_detail"

  archs="$(lipo -archs "$app_path/Contents/MacOS/$APP_NAME")"
  assert_contains "$app_path architectures" "arm64" " $archs "
  assert_contains "$app_path architectures" "x86_64" " $archs "
  verify_dynamic_library_linkage "$app_path"
}

verify_app_zip() {
  local tmp_dir="$1/app-zip"
  local app_path

  mkdir -p "$tmp_dir"
  ditto -x -k "$APP_ZIP" "$tmp_dir"
  app_path="$tmp_dir/$APP_NAME.app"
  verify_app_bundle "$app_path"
  if [[ "$RUN_LAUNCH_SMOKE_TEST" == "1" ]]; then
    launch_smoke_test "app zip" "$app_path"
  fi
  ok "verified app zip bundle"
}

verify_postinstall_clears_staged_quarantine() {
  local payload_app="$1"
  local postinstall="$2"
  local target_root="$3"
  local target_app="$target_root/Applications/$APP_NAME.app"
  local target_binary="$target_app/Contents/MacOS/$APP_NAME"

  mkdir -p "$target_root/Applications"
  ditto "$payload_app" "$target_app"
  xattr -w com.apple.quarantine "0081;00000000;Surge Relay;00000000" "$target_app"
  xattr -w com.apple.quarantine "0081;00000000;Surge Relay;00000000" "$target_binary"
  "$postinstall" "$PKG_PATH" "/" "$target_root"
  if xattr -p com.apple.quarantine "$target_app" >/dev/null 2>&1; then
    fail "pkg postinstall did not clear quarantine from staged app bundle"
  fi
  if xattr -p com.apple.quarantine "$target_binary" >/dev/null 2>&1; then
    fail "pkg postinstall did not clear quarantine from staged app executable"
  fi
}

verify_pkg() {
  local tmp_dir="$1/pkg"
  local payload_app
  local preinstall
  local postinstall
  local signature_output

  pkgutil --expand-full "$PKG_PATH" "$tmp_dir"
  payload_app="$(find "$tmp_dir" -path "*/Applications/$APP_NAME.app" -type d -print -quit)"
  [[ -n "$payload_app" ]] || fail "pkg payload missing $APP_NAME.app"
  verify_app_bundle "$payload_app"
  if [[ "$RUN_LAUNCH_SMOKE_TEST" == "1" ]]; then
    launch_smoke_test "pkg payload" "$payload_app"
  fi

  preinstall="$(find "$tmp_dir" -path "*/Scripts/preinstall" -type f -print -quit)"
  [[ -n "$preinstall" ]] || fail "pkg missing preinstall script"
  [[ -x "$preinstall" ]] || fail "pkg preinstall is not executable"
  grep -Fq 'tell application id "com.allenmiao.SurgeRelay" to quit' "$preinstall" \
    || fail "pkg preinstall does not request app quit"
  grep -Fq '/usr/bin/pkill -x "Surge Relay"' "$preinstall" \
    || fail "pkg preinstall does not stop running app before replacement"

  postinstall="$(find "$tmp_dir" -path "*/Scripts/postinstall" -type f -print -quit)"
  [[ -n "$postinstall" ]] || fail "pkg missing postinstall script"
  [[ -x "$postinstall" ]] || fail "pkg postinstall is not executable"
  grep -Fq '/usr/bin/xattr -cr "$app_path"' "$postinstall" \
    || fail "pkg postinstall does not clear quarantine"
  verify_postinstall_clears_staged_quarantine "$payload_app" "$postinstall" "$tmp_dir/postinstall-target"

  signature_output="$(pkgutil --check-signature "$PKG_PATH" 2>&1 || true)"
  if [[ "$PKG_SIGNATURE_MODE" == "unsigned" ]]; then
    assert_contains "pkg signature" "Status: no signature" "$signature_output"
  fi
  ok "verified pkg payload and install scripts"
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

  expected_length="$(stat -f '%z' "$APP_ZIP")"
  expected_signature="$(sparkle_attribute "$APP_ZIP_SPARKLE" 'sparkle:edSignature')"
  assert_equal "appcast latest title" "$VERSION" "$title"
  assert_equal "appcast sparkle:version" "$BUILD" "$sparkle_version"
  assert_equal "appcast shortVersionString" "$VERSION" "$short_version"
  assert_contains "appcast enclosure url" "/v$VERSION/Surge-Relay-$VERSION.app.zip" "$enclosure_url"
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

verify_zip_metadata_clean
verify_app_zip "$TMP_DIR"
verify_pkg "$TMP_DIR"
verify_appcast

ok "release assets verified for $VERSION ($BUILD)"
