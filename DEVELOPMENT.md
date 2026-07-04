# Surge Relay Development Guide

This document records the project conventions needed to maintain this fork.

## Project Shape

- Xcode project: `Surge Relay.xcodeproj`
- App target: `Surge Relay`
- Test target: `Surge RelayTests`
- Main state owner: `SurgeRelay/AppModel.swift`
- Persistent settings: `SurgeRelay/Models/AppSettings.swift`
- Module model: `SurgeRelay/Models/RelayModule.swift`
- Conversion path: `SurgeRelay/Services/ScriptHubClient.swift`
- Local/GitHub publishing: `SurgeRelay/AppModel.swift`, `SurgeRelay/Services/ModuleFileStore.swift`, `SurgeRelay/Services/GitHubClient.swift`
- Module metadata parsing: `SurgeRelay/Utilities/ModuleMetadataParser.swift`

## Publishing Model

`AppSettings.storageMode` is retained as a legacy compatibility field. New code should use:

- `publishToLocal`
- `publishToGitHub`

Both can be enabled at the same time. Local export and GitHub publishing share `RelayModule.publishedRelativePath`, so folder handling must stay destination-neutral. When adding code that generates publish files, pass a `PublishDestination` so local self-export protection does not accidentally remove files from the GitHub publish set.

Manual GitHub publishing has two paths:

- publish all current outputs, with stale managed file deletion preview and confirmation
- publish selected standalone modules only, with no stale deletion and with the selected modules' generated assets included

Keep the selected publish path conservative: it should merge new paths into the known GitHub publish list but must not prune paths that belong to unselected modules.

## Existing Module Safety

Do not overwrite or delete user-owned modules unless the file is known to be managed by Surge Relay.

Local publishing uses managed markers in `ModuleFileStore`. If a destination file has no marker and is not part of the previous managed publish list, writing should fail instead of replacing it. Cleanup of obsolete local files must continue to go through `PublishPreview` and explicit confirmation.

For local `file://` modules, if the source file path is the same as the target relative path, local export skips that standalone file. This prevents creating or overwriting duplicates in the user's Surge root.

## Script-Hub Metadata

Converted modules may contain a semantic source line:

```text
#SUBSCRIBED http://script.hub/file/_start_/ORIGINAL_URL/_end_/OUTPUT_NAME?type=loon-plugin&target=surge-module
```

Treat this as data, not disposable commentary. `ModuleMetadataParser.scriptHubSubscription(in:)` restores:

- original source URL
- source format (`qx-rewrite`, `loon-plugin`, `surge-module`)
- output name
- Script-Hub query options
- category when present

The local scanner must prefer this original URL over the local generated file path. `ModuleArgumentProcessor.materialize` must preserve ordinary comments so `#SUBSCRIBED` and user explanations survive standalone publish output.

## Build And Test

Use the local Xcode beta explicitly:

```bash
DEVELOPER_DIR="/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer" \
xcodebuild test \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS"
```

The active maintenance machine may print CoreSimulator version warnings even for macOS builds. Treat them as environmental warnings unless the command exits non-zero.

## Release

Release builds require:

- Sparkle EdDSA private key in the keychain
- stable self-signed signing identity: `Surge Relay Self-Signed Code Signing`
- unchanged bundle identifier: `com.allenmiao.SurgeRelay`

Build release assets with:

```bash
REQUIRE_SPARKLE_SIGNATURES=1 \
REQUIRE_STABLE_CODESIGN=1 \
VERIFY_APPCAST=1 \
UPDATE_APPCAST=1 \
DEVELOPER_DIR="/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer" \
./script/build_release_assets.sh
```

After creating a GitHub Release, verify remote assets:

```bash
REQUIRE_SPARKLE_SIGNATURES=1 \
EXPECT_ADHOC_SIGNATURE=0 \
EXPECTED_CODESIGN_AUTHORITY="Surge Relay Self-Signed Code Signing" \
./script/verify_github_release_assets.sh \
  --repo junchan0412/SurgeRelay-macOS \
  --tag vX.Y.Z
```

## Documentation Checklist

When changing behavior, update:

- `README.md` for user-facing behavior
- `CHANGELOG.md` for release notes
- `DEVELOPMENT.md` when architecture, release, or safety invariants change
