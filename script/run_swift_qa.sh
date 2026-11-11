#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/build/qa-swift"
RESULT_DIR="${1:-$(mktemp -d "$ROOT_DIR/build/qa-swift/run.XXXXXX")}"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"
QA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/SurgeRelaySwiftQA.XXXXXX")"
trap 'rm -rf "$QA_ROOT"' EXIT

export SURGE_RELAY_UI_QA=1
export SURGE_RELAY_UI_QA_ROOT="$QA_ROOT"
export TEST_RUNNER_SURGE_RELAY_UI_QA_ROOT="$QA_ROOT"

qa_exit=0
xcodebuild test \
  -project "$ROOT_DIR/Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT_DIR/build/qa-swift/DerivedData" \
  -resultBundlePath "$RESULT_DIR/Tests.xcresult" \
  -parallel-testing-enabled NO \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_VERSION=6.0 \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  ENABLE_TESTABILITY=YES \
  ENABLE_DEBUG_DYLIB=NO \
  2>&1 | tee "$RESULT_DIR/xcodebuild.log" || qa_exit=$?

python3 -B "$ROOT_DIR/script/summarize_swift_qa.py" "$RESULT_DIR"
exit "$qa_exit"
