#!/bin/zsh
set -euo pipefail
cd '/Users/qidewei/Documents/Surge Relay'
fixture_root=/tmp/surge-relay-production-script-fixture
xcrun swiftc -swift-version 6 -parse-as-library -O \
  SurgeRelay/Models/StageMetric.swift SurgeRelay/Models/RelayError.swift \
  SurgeRelay/Services/ScriptHubNetworkPolicy.swift SurgeRelay/Services/ScriptHubWorkerFiles.swift \
  SurgeRelay/Services/SourceRetryAfter.swift SurgeRelayScriptWorker/ScriptHubJavaScriptRuntime.swift \
  SurgeRelayScriptWorker/ScriptHubWorkerMain.swift -o "$fixture_root/worker"
xcrun swiftc -swift-version 6 -parse-as-library -O \
  SurgeRelay/Models/StageMetric.swift SurgeRelay/Models/RelayError.swift \
  SurgeRelay/Services/EmbeddedScriptHubEngine.swift SurgeRelay/Services/ScriptHubNetworkPolicy.swift \
  SurgeRelay/Services/ScriptHubWorkerFiles.swift SurgeRelay/Services/SourceRetryAfter.swift \
  SurgeRelay/Services/SurgeModuleSanitizer.swift "$fixture_root/benchmark_production_scripts.swift" \
  -o "$fixture_root/benchmark"
"$fixture_root/benchmark" "$fixture_root/worker" "$fixture_root/off.json" "${1:-24}" "${2:-5}" off
"$fixture_root/benchmark" "$fixture_root/worker" "$fixture_root/on.json" "${1:-24}" "${2:-5}" on
