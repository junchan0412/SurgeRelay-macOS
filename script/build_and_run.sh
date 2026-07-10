#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Surge Relay"
BUNDLE_ID="com.allenmiao.SurgeRelay"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Surge Relay.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/codex-run"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer}"

export DEVELOPER_DIR

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

open_app() {
  local arguments=(-n -F)
  if [[ "${SURGE_RELAY_RUN_UI_QA:-0}" == "1" ]]; then
    arguments+=(--env SURGE_RELAY_UI_QA=1)
  fi
  /usr/bin/open "${arguments[@]}" "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    if [[ "${SURGE_RELAY_RUN_UI_QA:-0}" == "1" ]]; then
      SURGE_RELAY_UI_QA=1 lldb -- "$APP_BINARY" --surge-relay-ui-qa
    else
      lldb -- "$APP_BINARY"
    fi
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
