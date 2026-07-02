#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-junchan0412.SurgeRelay}"
SPARKLE_GENERATE_KEYS="$ROOT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ ! -x "$SPARKLE_GENERATE_KEYS" ]]; then
  fail "Sparkle generate_keys is missing. Run script/build_release_assets.sh once or build the project to fetch package artifacts."
fi

case "${1:-create}" in
  create)
    "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT"
    ;;
  public-key)
    "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p
    ;;
  export-private)
    [[ $# -eq 2 ]] || fail "usage: $0 export-private /secure/path/sparkle-ed25519.txt"
    "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$2"
    ;;
  import-private)
    [[ $# -eq 2 ]] || fail "usage: $0 import-private /secure/path/sparkle-ed25519.txt"
    "$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -f "$2"
    ;;
  *)
    cat >&2 <<'USAGE'
usage:
  script/create_sparkle_update_key.sh create
  script/create_sparkle_update_key.sh public-key
  script/create_sparkle_update_key.sh export-private /secure/path/sparkle-ed25519.txt
  script/create_sparkle_update_key.sh import-private /secure/path/sparkle-ed25519.txt
USAGE
    exit 2
    ;;
esac
