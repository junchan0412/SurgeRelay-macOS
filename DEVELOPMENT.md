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

## View Boundaries

Keep `ModulesView.swift` focused on the split-view shell, sidebar filtering, selection, editor presentation, and per-module detail composition.

- `CombinedModuleViews.swift` owns the combined-module sidebar row, combined-module detail page, and publish-preview summary UI.
- `DetailInfoViews.swift` owns reusable detail rows and section chrome used by module and combined-module detail pages.
- Shared preview/editor components that are not specific to the module list stay in `Components.swift`.

## Publishing Model

`AppSettings.storageMode` is retained as a legacy compatibility field. New code should use:

- `publishToLocal`
- `publishToGitHub`

Both can be enabled at the same time. Local export and GitHub publishing share `RelayModule.publishedRelativePath`, so folder handling must stay destination-neutral. When adding code that generates publish files, pass a `PublishDestination` so local self-export protection does not accidentally remove files from the GitHub publish set.

Keep these two axes separate:

- `RelayModule.storageLocation`: where Surge Relay stores the converted module (`local` or `gitHub`).
- `RelayModule.sourceOrigin`: where the pre-conversion source comes from (local Surge file, remote QX/Loon/Surge, or invalid).

Do not infer storage from `sourceURL` after Script-Hub subscription metadata has been applied: a local file can restore a remote original URL while still being managed as a local module. For local modules, preserve `localStorageRelativePath` whenever it is known.

Manual GitHub publishing has two paths:

- publish all current outputs, with stale managed file deletion preview and confirmation
- publish selected standalone modules only, with no stale deletion and with the selected modules' generated assets included

All publishable module selection should flow through `PublishPlan` / `PublishCoordinator`. Do not recalculate publishable IDs ad hoc in UI, Web API, or `AppModel`: the same plan owns standalone modules, combined-module contributors, generated asset IDs, scope labels, and the "nothing to publish" decision.

Keep the selected publish path conservative: it should merge new paths into the known GitHub publish list but must not prune paths that belong to unselected modules.

Local publish self-overwrite checks also belong in `PublishCoordinator` with paths resolved by `LocalSourcePathResolver`. If a local source file and the standalone output resolve to the same relative path, skip that export instead of writing over the user's original module.

Published file assembly belongs in `PublishFileAssembler`: it owns adding the combined module data, materializing standalone modules with argument overrides, applying Surge metadata, appending generated assets, and consulting the local self-overwrite check. Keep `AppModel` at the orchestration level for previews, commits, and persisted publish manifests.

Shared module counts should flow through `ModuleCollectionSummary`. Main window status, menu bar text, Web management state, and diagnostics should not independently reimplement enabled, standalone, failed, latest-update, or updateable counts unless they need the actual module objects.

Update failures should surface actionable causes through `UpdateFailureFormatter`. If an original source returns 404/401/403/429, times out, fails DNS, or fails TLS validation, store that reason on the module and in update history; aggregate alerts that block combined-module replacement should include the same reason rather than only the module name.

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

`ModelAndCoordinatorTests.swift` owns pure model/coordinator coverage, including source metadata restoration, update failure formatting, summary counts, and publish-plan decisions. `LocalFileStoreTests.swift` owns local configuration migration, local module scanning, local publish safety, legacy cleanup, root diagnostics, and generated asset file coverage. `WebManagementTests.swift` owns Web management request parsing, API payload, session cookie, same-origin, throttling, response hardening, and icon content-type coverage. `GitHubReleaseTests.swift` owns GitHub settings, remote directory discovery, release asset parsing, checksum validation, and install guidance coverage. `GitHubPublishTests.swift` owns GitHub publish diffing, preview, duplicate path rejection, commit snapshots, and reference-move retry coverage; GitHub network fakes belong in `GitHubTestSupport.swift`. Keep shrinking the larger `SurgeRelayTests.swift` by moving similarly cohesive tests into focused files instead of adding more unrelated cases there.

Use the local Xcode beta explicitly:

```bash
DEVELOPER_DIR="/Volumes/TR 5000/Applications/Xcode.app/Contents/Developer" \
xcodebuild test \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS"
```

The active maintenance machine may print CoreSimulator version warnings even for macOS builds. Treat them as environmental warnings unless the command exits non-zero.

## Performance Notes

The module list should not eagerly read every converted preview at launch. `ModulesView` keeps metadata-only search available immediately and builds the heavier converted-content search index only after the user enters a search query. Preserve that lazy behavior when changing search or preview code.

Web management list updates use `moduleListSignature(module)` in `WebResources/app.js` to decide whether a sidebar re-render is needed. When adding fields that affect list rows, search subtitles, icons, relationship labels, or failure state, update that signature in one place.

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
- `PROJECT_AUDIT_2026-07-04.md` or a newer audit file when completing a broad optimization pass
