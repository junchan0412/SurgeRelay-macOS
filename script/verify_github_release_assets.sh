#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

project_value() {
  local key="$1"
  awk -F': *' -v key="$key" '$1 ~ key { gsub(/"/, "", $2); print $2; exit }' "$ROOT_DIR/project.yml"
}

VERSION="${VERSION:-$(project_value MARKETING_VERSION)}"
BUILD="${BUILD:-$(project_value CURRENT_PROJECT_VERSION)}"
TAG="${TAG:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-junchan0412/SurgeRelay-macOS}}"
RUN_LAUNCH_SMOKE_TEST="${RUN_LAUNCH_SMOKE_TEST:-0}"
REQUIRE_SPARKLE_SIGNATURES="${REQUIRE_SPARKLE_SIGNATURES:-0}"

usage() {
  echo "Usage: $0 [--tag TAG] [--version VERSION] [--build BUILD] [--repo OWNER/REPO] [--launch-smoke-test]" >&2
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
    --repo)
      [[ $# -ge 2 ]] || usage
      REPO="$2"
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

if [[ -z "$TAG" ]]; then
  TAG="v$VERSION"
fi

APP_ZIP="Surge-Relay-$VERSION.app.zip"
APP_ZIP_SHA="$APP_ZIP.sha256"
PKG="Surge-Relay-$VERSION.pkg"
PKG_SHA="$PKG.sha256"

fail() {
  echo "error: $*" >&2
  exit 1
}

ok() {
  echo "ok: $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

asset_digest() {
  local name="$1"
  gh release view "$TAG" \
    --repo "$REPO" \
    --json assets \
    --jq ".assets[] | select(.name == \"$name\") | .digest"
}

asset_size() {
  local name="$1"
  gh release view "$TAG" \
    --repo "$REPO" \
    --json assets \
    --jq ".assets[] | select(.name == \"$name\") | .size"
}

normalized_sha256() {
  local value="$1"
  value="${value#sha256:}"
  value="${value#SHA256:}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

file_sha256() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

sidecar_sha256() {
  awk 'NF > 0 { print tolower($1); exit }' "$1"
}

verify_asset_digest() {
  local file="$1"
  local expected_digest
  local actual_digest

  expected_digest="$(asset_digest "$(basename "$file")")"
  [[ -n "$expected_digest" && "$expected_digest" != "null" ]] \
    || fail "GitHub digest missing for $(basename "$file")"
  expected_digest="$(normalized_sha256 "$expected_digest")"
  actual_digest="$(file_sha256 "$file")"
  [[ "$actual_digest" == "$expected_digest" ]] \
    || fail "$(basename "$file") digest mismatch: GitHub $expected_digest, downloaded $actual_digest"
}

verify_sidecar_matches_asset() {
  local asset_file="$1"
  local sidecar_file="$2"
  local asset_hash
  local sidecar_hash

  asset_hash="$(file_sha256 "$asset_file")"
  sidecar_hash="$(sidecar_sha256 "$sidecar_file")"
  [[ -n "$sidecar_hash" ]] || fail "$(basename "$sidecar_file") does not contain a sha256 hash"
  [[ "$asset_hash" == "$sidecar_hash" ]] \
    || fail "$(basename "$sidecar_file") does not match $(basename "$asset_file")"
}

verify_required_asset_exists() {
  local name="$1"
  local size

  size="$(asset_size "$name")"
  [[ -n "$size" && "$size" != "null" ]] || fail "release $TAG is missing asset $name"
}

require_tool gh
require_tool shasum

[[ -n "$VERSION" ]] || fail "empty version"
[[ -n "$BUILD" ]] || fail "empty build number"
[[ -n "$REPO" ]] || fail "empty repository"

for asset in "$APP_ZIP" "$APP_ZIP_SHA" "$PKG" "$PKG_SHA"; do
  verify_required_asset_exists "$asset"
done
if [[ "$REQUIRE_SPARKLE_SIGNATURES" == "1" ]]; then
  verify_required_asset_exists "$APP_ZIP.sparkle.txt"
  verify_required_asset_exists "$PKG.sparkle.txt"
fi
ok "verified GitHub release asset list"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

gh release download "$TAG" \
  --repo "$REPO" \
  --dir "$TMP_DIR" \
  --pattern "Surge-Relay-$VERSION*"

(
  cd "$TMP_DIR"
  shasum -a 256 -c "$APP_ZIP_SHA"
  shasum -a 256 -c "$PKG_SHA"
) >/dev/null
ok "verified downloaded sha256 sidecars"

verify_asset_digest "$TMP_DIR/$APP_ZIP"
verify_asset_digest "$TMP_DIR/$APP_ZIP_SHA"
verify_asset_digest "$TMP_DIR/$PKG"
verify_asset_digest "$TMP_DIR/$PKG_SHA"
ok "verified GitHub API digests"

verify_sidecar_matches_asset "$TMP_DIR/$APP_ZIP" "$TMP_DIR/$APP_ZIP_SHA"
verify_sidecar_matches_asset "$TMP_DIR/$PKG" "$TMP_DIR/$PKG_SHA"
ok "verified sidecar hashes match installable assets"

verify_args=(
  --version "$VERSION"
  --build "$BUILD"
  --artifact-dir "$TMP_DIR"
)
if [[ "$RUN_LAUNCH_SMOKE_TEST" == "1" ]]; then
  verify_args+=(--launch-smoke-test)
fi

REQUIRE_SPARKLE_SIGNATURES="$REQUIRE_SPARKLE_SIGNATURES" \
  "$ROOT_DIR/script/verify_release_assets.sh" "${verify_args[@]}"

ok "GitHub release assets verified for $TAG"
