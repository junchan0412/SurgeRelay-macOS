# Surge Relay Development Guide

This document records the project conventions needed to maintain this fork.

## Project Shape

- Xcode project: `Surge Relay.xcodeproj`
- App target: `Surge Relay`
- Test target: `Surge RelayTests`
- Main state owner: `SurgeRelay/AppModel.swift`; automatic publish scheduling lives in `SurgeRelay/AppModel+AutomaticPublishing.swift`, credentials live in `SurgeRelay/AppModel+Credentials.swift`, diagnostics live in `SurgeRelay/AppModel+Diagnostics.swift`, module derived state lives in `SurgeRelay/AppModel+ModuleState.swift`, module mutation/import/editing lives in `SurgeRelay/AppModel+Modules.swift`, preview/address read access lives in `SurgeRelay/AppModel+PreviewAccess.swift`, manual publish orchestration lives in `SurgeRelay/AppModel+Publishing.swift`, settings forwarding lives in `SurgeRelay/AppModel+Settings.swift`, update and Script-Hub refresh orchestration lives in `SurgeRelay/AppModel+Updates.swift`, and Web-management token/server wiring lives in `SurgeRelay/AppModel+WebManagement.swift`
- Persistent settings: `SurgeRelay/Models/AppSettings.swift`
- Module model: `SurgeRelay/Models/RelayModule.swift`
- Conversion path: `SurgeRelay/Services/ScriptHubClient.swift`
- Local/GitHub publishing: `SurgeRelay/AppModel+Publishing.swift`, `SurgeRelay/AppModel+AutomaticPublishing.swift`, `SurgeRelay/Services/PublishCoordinator.swift`, `SurgeRelay/Services/PublishFileAssembler.swift`, `SurgeRelay/Services/ModuleFileStore.swift`, `SurgeRelay/Services/GitHubClient.swift`
- Diagnostics export: `SurgeRelay/Services/DiagnosticReportBuilder.swift`
- Module metadata parsing: `SurgeRelay/Utilities/ModuleMetadataParser.swift`

## View Boundaries

Keep `ModulesView.swift` focused on the split-view shell, search/index coordination, detail selection, toolbar actions, editor presentation, and sheet routing.

- `ModuleSidebarSectionPlanner` owns the sidebar grouping rules for attention, local, GitHub, and uncategorized modules. `ModuleSidebarView.swift` owns the sidebar list rendering, module rows, batch-selection checkboxes, context menu entry points, empty/sidebar states, and the bottom status card.
- `ModuleDetailSummaryHeader.swift` owns the module detail title, icon, metadata pills, and summary metrics. `ModuleDetailView.swift` owns the detail page composition, management relation rows, sync status, module arguments, and publishing/local file sections.
- `CombinedModuleViews.swift` owns the combined-module sidebar row, combined-module detail page, and publish-preview summary UI.
- `DetailInfoViews.swift` owns reusable detail rows and section chrome used by module and combined-module detail pages.
- Module and combined-module preview panes, override comparison, and the AppKit code text bridge belong in `ModulePreviewViews.swift`; small reusable visual primitives stay in `Components.swift`.
- `SettingsView.swift` owns the settings window shell, tab selection, diagnostics export, and QR sheet routing. General settings belong in `SettingsGeneralView.swift`; local/GitHub publishing settings and local root diagnostics belong in `SettingsPublishingView.swift`; credentials-specific token UI belongs in `SettingsCredentialsView.swift`; Web service access UI belongs in `SettingsWebManagementView.swift`; reusable settings chrome and rows belong in `SettingsComponents.swift`.

## Model Boundaries

Keep `ServiceModels.swift` for small cross-service value types that do not have a clearer owner. Publishing coordination belongs in `PublishCoordinator.swift`; update coordination belongs in `UpdateCoordinator.swift`; Web management URL/access presentation belongs in `WebManagementController.swift`; configuration-directory migration belongs in `ConfigurationManager.swift`; work/task state and update-admission rules belong in `WorkActivity.swift`; persistent settings belong in `AppSettings.swift`; module identity and source/storage relationships belong in `RelayModule.swift`; add/edit draft state belongs in `ModuleDraft.swift`; output-folder and output-path inspection helpers belong in `ModuleOutputPath.swift`; main-window module search text, content-cache keys, content-index rebuild planning, and preview-content loading decisions belong in `ModuleSearchIndex.swift`.

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

Automatic GitHub publish readiness belongs in `AutomaticPublishPlanner`. Keep the settings/token/standalone-module/cache-output admission checks there so update completion, delayed scheduling, and scheduled execution do not drift into different skip rules. `AppModel+AutomaticPublishing.swift` owns only queue/cancel/run orchestration; keep manual preview/publish and published-file assembly in `AppModel+Publishing.swift`.

Keep the selected publish path conservative: it should merge new paths into the known GitHub publish list but must not prune paths that belong to unselected modules.

Local publish self-overwrite checks also belong in `PublishCoordinator` with paths resolved by `LocalSourcePathResolver`. If a local source file and the standalone output resolve to the same relative path, skip that export instead of writing over the user's original module.

Published file assembly belongs in `PublishFileAssembler`: it owns adding the combined module data, materializing standalone modules with argument overrides, applying Surge metadata, appending generated assets, and consulting the local self-overwrite check. Keep `AppModel` at the orchestration level for previews, commits, and persisted publish manifests.

Local published-file manifest planning belongs in `LocalPublishedFilesPlanner`. Keep the "same root only" managed-path reuse, stale local-file detection, cleanup preview construction, post-export persistence/cleanup decisions, and confirmed-cleanup managed path/settings/status planning there. When the configured local module root changes, do not carry stale paths or overwrite privileges from the previous root into the new root.

GitHub publish result planning belongs in `GitHubPublishPlanner`. Keep repository privacy metadata update decisions, target descriptions, preview payload construction, publish preparation validation, stale-path candidates, path-plan persistence policy, selected-publish path merging, no-files error recognition, no-change/no-files status text, success messages, and update-history entry construction there. `AppModel` should own token checks, repository privacy probes, actual GitHub client calls, and persistence of the returned path plan.

Shared module counts should flow through `ModuleCollectionSummary`. Main window status, menu bar text, Web management state, and diagnostics should not independently reimplement enabled, standalone, failed, latest-update, or updateable counts unless they need the actual module objects.

Update failure message formatting lives in `Services/UpdateFailureFormatter.swift`. If an original source returns 404/401/403/429, times out, fails DNS, or fails TLS validation, store that reason on the module and in update history; aggregate alerts that block combined-module replacement should include the same reason rather than only the module name.

Update failure source-check and outcome decisions belong in `UpdateFailurePlanner`. Keep "should probe the original source after a generic conversion failure", latest-module source selection for error text, cached-after-failure history, missing-cache combined-module blockage, and missing-cache detail formatting there. `AppModel` should perform only the actual `SourceRevisionService` check, cache reads, and output rebuild, then apply the returned messages/history plans.

Update completion status and automatic-publish scheduling decisions belong in `UpdateCompletionStatusPlanner`. Keep the choice between queueing GitHub automatic publish, clearing an impossible automatic-publish schedule, showing local cleanup confirmation, and reporting a plain refreshed output there. `AppModel` should only execute the returned schedule action and assign the returned status message.

Diagnostic report assembly belongs in `DiagnosticReportBuilder`. AppModel should pass the current settings, module list, runtime state, and diagnostics snapshots into the builder; URL redaction and report DTO mapping should stay there so exported diagnostics never include source query strings, fragments, or embedded credentials.

Preview content reads belong in `ModulePreviewContentProvider`. Keep cache lookup, local Surge source fallback, argument materialization, and metadata application there. Preview edit state planning belongs in `ModulePreviewEditPlanner`: no-change detection, override base-hash refresh, conflict clearing, and save/restore/accept status text should stay there so AppModel only performs file writes, persistence, and output rebuilds.

Module output naming belongs in `ModuleNamingPlanner`. Keep output-file uniqueness checks, combined-module filename collision avoidance, detected source-format inference, local storage relative-path derivation, and loaded-module naming normalization there. AppModel should pass the current modules and settings into the planner instead of reimplementing path rules inline.

Web management HTTP primitives belong in `WebManagementHTTP.swift`; API authentication, same-origin validation, and session cookie rules belong in `WebRequestSecurity.swift`; request authentication throttling belongs in `WebAuthenticationThrottle.swift`; connection lifecycle and event streaming stay in `WebManagementServer.swift`. Cover request parsing, API error payloads, response hardening, and event-stream headers in `WebManagementHTTPTests.swift`; cover session cookies, same-origin checks, remote access, bearer tokens, and throttling in `WebRequestSecurityTests.swift`; keep `WebManagementTests.swift` focused on runtime state, display URLs, default settings, CSP, and icon content-type behavior.

Cached module metadata refresh and update-result module state planning belong in `ModuleMetadataRefreshPlanner`. Keep restored Script-Hub subscription metadata, unchanged-source cache reuse state, source revision writeback, conversion-engine revision decisions, override base-hash/conflict decisions, preferred icon selection, icon-cache refresh decisions, detected source-format updates, content-change detection, and success/unchanged history text there. AppModel should read cached files or conversion outputs and then apply the returned module/icon plan.

Module refresh eligibility belongs in `ModuleRefreshPlanner`. Keep "contributes to combined module", combined contributor filtering, "is updateable", updateable module filtering, and launch-time refresh decisions there so AppModel, previews, publish planning, summary counts, and startup refresh behavior stay aligned. Cover those rules in `ModuleRefreshPlannerTests.swift` instead of growing `ModelAndCoordinatorTests.swift`.

Add/edit draft planning belongs in `ModuleDraftPlanner`. Keep draft validation, duplicate effective-source checks, add-module construction, edit change detection, source revision state clearing, custom-icon planning, and local storage relative-path decisions there. `AppModel` should apply the returned add/update plan, then handle persistence, icon cache side effects, and update scheduling.

Module argument override planning belongs in `ModuleArgumentPlanner`. Keep override trimming, "default value clears storage", no-op detection, reset planning, and user-visible parameter status text there. AppModel should only apply the returned overrides, persist modules, and trigger output rebuilds.

Module output-folder catalogs belong in `ModuleOutputFolderCatalog`. Keep the merged folder menu, create-folder setting changes, local destination path planning, and GitHub directory refresh cache decisions there. `AppModel` should do the actual local directory creation and GitHub directory fetch, then apply the returned state.

Local module import planning belongs in `LocalModuleImportPlanner`. Keep scanned-candidate validation, output filename de-duplication, combined-module path avoidance, imported `RelayModule` construction, successful-import metadata/state writeback, and scan/import status text there. `AppModel` should only execute conversion, cache writes, persistence, and apply user-visible status/error values returned by planner helpers.

User-visible publish addresses belong in `PublishedAddressResolver`. Keep GitHub publication gating, standalone module URL eligibility, combined-module GitHub URL generation, and local combined-module file URL generation there. `AppSettings` should remain configuration data, while AppModel, views, Web management, and diagnostics consume resolved addresses through AppModel forwarding properties.

Credential loading and token migration belong in `CredentialTokenCoordinator`. Keep GitHub Token legacy-settings migration, keychain-unavailable fallback, Web management access-token generation, and memory-only degradation there. `AppModel` should apply the returned token, storage status, status message, and persistence side effects rather than duplicating keychain decision branches inline.

## Existing Module Safety

Do not overwrite or delete user-owned modules unless the file is known to be managed by Surge Relay.

Local publishing uses managed markers in `ModuleFileStore`. If a destination file has no marker and is not part of the previous managed publish list, writing should fail instead of replacing it. Cleanup of obsolete local files must continue to go through `PublishPreview` and explicit confirmation.

The previous managed publish list is valid only for the same local module root. If the root directory changes, old paths are historical records for the old root and must not grant overwrite or cleanup permission in the new root.

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

Web management Script-Hub advanced option defaults and group schema live in `WebResources/web-options.js`. Keep option keys, default values, and editor groups there; `app.js` should consume the exported schema instead of defining static option metadata inline.

Web management formatting helpers live in `WebResources/web-format.js`. Keep HTML escaping, attribute escaping, date/time formatting, and module preview syntax highlighting there so `app.js` stays focused on API calls, state changes, event handling, and DOM composition.

Web management list, activity, and pure editor rules live in `WebResources/web-logic.js`. Keep module list signatures, sidebar snapshot signatures, detail metadata row presence checks, search text, state titles, sidebar subtitles, failure summaries, failure-filter state, filtered sidebar modules, empty-state text, activity status/button/progress presentation, folder titles, native Surge source detection, icon URL validation, editor payload construction, draft output path previews, and output path collision notices there so live updates, sidebar rendering, detail status rows, editor saving, editor previews, and the update activity card share the same tested rules.

Web management markup helpers live in `WebResources/web-markup.js`. Keep reusable HTML fragments such as sidebar module rows, empty states, detail rows, copyable URL/value sections, preview shells, total-module and single-module detail sections, detail toolbars, argument sections and controls, advanced option containers and rows, output-folder option lists, latest-publish sections, and publish-file lists there; `app.js` should compose those fragments with live state instead of owning their escaping details.

Web management API/session helpers live in `WebResources/web-api.js`. Keep URL token extraction, session bootstrap, request headers, JSON body handling, same-origin credentials, error payload parsing, and 401 token retry there; `app.js` should call the client instead of directly owning fetch/session details.

Web management state/navigation helpers live in `WebResources/web-state.js`. Keep initial module selection, mobile history URLs, fallback selection, and EventSource reconnect/polling behavior there; `app.js` should coordinate rendering through those helpers instead of duplicating route or live-state subscription logic.

Web management editor UI helpers live in `WebResources/web-editor.js`. Keep module editor DOM state, advanced option disclosure animation, Script-Hub option collection/backfill, output folder menu hydration, output path preview binding, native Surge source visibility, icon URL preview rendering, and remote source name auto-fill scheduling there; `app.js` should wire events and API calls instead of owning those editor details.

Web management feedback helpers live in `WebResources/web-feedback.js`. Keep dialog open/close animation, confirmation resolution, toast state, clipboard fallback, copy-success button state, and scroll reset there; `app.js` should call the controller instead of owning generic feedback UI state.

Web management preview helpers live in `WebResources/web-preview.js`. Keep module/combined preview loading, editable preview dirty state, save/restore preview actions, and preview action error reporting there; `app.js` should only select the right preview route and react to detail toolbar events.

Swift Web management DTOs, request mutations, and API errors live in `Services/WebManagementModels.swift`. State payload construction lives in `Services/WebManagementStateBuilder.swift`. Keep `WebManagementAPI.swift` focused on HTTP route dispatch and calls into `AppModel`.

Swift Web management static asset responses, content security policy, cached icon responses, and image content-type detection live in `Services/WebManagementAssets.swift`. Do not add bundle resource lookup or image sniffing back to `WebManagementAPI.swift`.

Diagnostic payloads and snapshots live in `Models/DiagnosticModels.swift`. Keep installation, keychain, local-root, module diagnostic snapshot, and diagnostic report model changes there instead of adding them back to `ServiceModels.swift`.

GitHub Release metadata, install guidance, checksum validation state, and version comparison live in `Models/GitHubReleaseModels.swift`. The GitHub latest-release API call and sha256 sidecar downloads live in `Services/GitHubReleaseClient.swift`; `Views/CheckForUpdatesView.swift` should remain UI-only apart from SwiftUI presentation adapters.

GitHub publish networking lives in `Services/GitHubClient.swift`. Keep API request/response DTOs in `Services/GitHubAPIModels.swift`, and keep repository path normalization, output-folder discovery, duplicate-path validation, and commit-message construction in `Services/GitHubRepositoryPath.swift` so GitHub directory-root behavior stays testable without a network client.

Module editor presentation primitives live in `Views/ModuleEditorComponents.swift`. Keep the preview card, section chrome, editor rows, output path row, output-folder picker, storage-location picker, and draft icon preview there; `Views/ModuleEditorView.swift` should own draft state, derived editor hints, source auto-fill, folder creation, and save/cancel flow.

## Build And Test

`ModelAndCoordinatorTests.swift` owns pure model/coordinator coverage, including source metadata restoration, source identity, published address resolution, and summary counts. `UpdateFailureTests.swift` owns update failure formatting and original-source probe planning. `DiagnosticReportTests.swift` owns diagnostic report snapshots and secret redaction. `ModulePreviewContentProviderTests.swift` owns preview content recovery and cache-miss behavior. `ModulePreviewEditPlannerTests.swift` owns preview edit save/restore/conflict state planning. `CredentialTokenCoordinatorTests.swift` owns GitHub/Web token migration, storage fallback, and generated token behavior. `WorkActivityTests.swift` owns task activity state and update-admission rules.

`ModulePlanningTests.swift` owns module naming, module argument override planning, sidebar section planning, output path inspection, and local self-export protection. `ModuleDraftPlannerTests.swift` owns module draft validation plus add/update planning. `ModuleOutputFolderTests.swift` owns output-folder path helpers, folder option catalogs, folder creation plans, and remote-folder refresh cache decisions. `ModuleOrderingTests.swift` owns module move/reorder helpers and invalid ID-set handling. `LocalModuleImportPlannerTests.swift` owns local import candidate planning, deduplication, failure details, and user-visible scan/import statuses. `ModuleSearchIndexTests.swift` owns main-window search text, content-cache keys, and preview-content loading decisions. `ModuleMetadataParserTests.swift` owns Surge metadata parsing and metadata application rules. `ModuleMergerTests.swift` owns combined-module merge behavior. `ModuleMetadataRefreshPlannerTests.swift` owns cached metadata refresh planning, including restored subscription metadata, icon preference, and override base-hash rules.

`PublishPlannerTests.swift` owns publish-plan selection and GitHub publish result planning. `PublishFileAssemblerTests.swift` owns publish-file assembly. `LocalPublishedFilesPlannerTests.swift` owns local published-file manifest and confirmed-cleanup state planning. `AutomaticPublishPlannerTests.swift` owns automatic publish admission, queueing, skip messages, and cached standalone-output checks; automatic publishing needs any cached standalone output, not every standalone output. `UpdateCompletionStatusPlannerTests.swift` owns update-completion status text and scheduling decisions. `ConfigurationMigrationTests.swift` owns local configuration migration and migrated-file cleanup. `LocalPublishedExportTests.swift` owns local publish write/cleanup safety and generated asset file coverage. `LegacyOutputCleanupPlannerTests.swift` owns old output cleanup path planning. `LocalModuleScannerTests.swift` owns local module scanning, folder discovery, root diagnostics, and skipped-file reporting.

`AppSettingsTests.swift` owns settings decoding, migration defaults, and combined-module setting defaults. `SecurityDiagnosticsTests.swift` owns keychain round trips, credential diagnostics, keychain probe snapshots, and installation diagnostics. `SourceRevisionServiceTests.swift` owns source revision network checks and effective original-source URL selection. `ScriptHubTests.swift` owns Script-Hub conversion URLs, upstream pinning and script hashes, embedded-engine bridge safety, native Surge conversion, argument materialization, advanced option summaries, and sanitizer behavior. `WebManagementTests.swift` owns Web management request parsing, API payload, session cookie, same-origin, throttling, response hardening, and icon content-type coverage. `WebManagementStateBuilderTests.swift` owns Web management state payload field mapping, combined-module visibility, and activity progress rules. `GitHubReleaseTests.swift` owns GitHub settings, remote directory discovery, release asset parsing, checksum validation, and install guidance coverage. `GitHubPublishTests.swift` owns GitHub publish diffing, preview, duplicate path rejection, commit snapshots, and reference-move retry coverage; GitHub network fakes belong in `GitHubTestSupport.swift`. Keep shrinking the larger test files by moving similarly cohesive tests into focused files instead of adding more unrelated cases there.

Use the local Xcode beta explicitly:

```bash
node --check SurgeRelay/WebResources/web-logic.js
node --check SurgeRelay/WebResources/web-options.js
node --check SurgeRelay/WebResources/web-format.js
node --check SurgeRelay/WebResources/web-markup.js
node --check SurgeRelay/WebResources/web-api.js
node --check SurgeRelay/WebResources/web-state.js
node --check SurgeRelay/WebResources/web-editor.js
node --check SurgeRelay/WebResources/web-feedback.js
node --check SurgeRelay/WebResources/web-preview.js
node --check SurgeRelay/WebResources/app.js
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
./script/check_release_configuration.sh
```

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
xcodebuild test \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS"
```

The active maintenance machine may print CoreSimulator version warnings even for macOS builds. Treat them as environmental warnings unless the command exits non-zero.

## Performance Notes

The module list should not eagerly read every converted preview at launch. `ModulesView` keeps metadata-only search available immediately and builds the heavier converted-content search index only after the user enters a search query. Preserve that lazy behavior when changing search or preview code.

Web management list updates use `sidebarListSignature(snapshot)` from `WebResources/web-logic.js` to decide whether a sidebar re-render is needed. When adding fields that affect list rows, search subtitles, icons, relationship labels, or failure state, update that signature path in one place and run `node script/test_web_resources.mjs`. Detail metadata rows use `metadataRowPresenceChanged(previous, next)` from the same file to decide when patching is not enough and a full detail render is required.

`script/test_web_dom_resources.mjs` provides a dependency-free DOM harness for the Web management shell. Keep it focused on behavior that depends on the real `index.html` structure and `app.js` startup path: required nodes, initial state rendering, detail sections, update admission controls, and editor output-path preview behavior.

## Release

Release builds require:

- Sparkle EdDSA private key in the keychain
- stable self-signed signing identity: `Surge Relay Self-Signed Code Signing`
- unchanged bundle identifier: `com.allenmiao.SurgeRelay`

Before importing signing certificates or calling GitHub, run the local release preflight:

```bash
VERSION=1.3.8 ./script/check_release_configuration.sh
```

The preflight checks version/build consistency, Sparkle feed and public key metadata, Web resource syntax and behavior/DOM tests, the latest appcast entry, the release entitlement, shell syntax for release scripts, and the GitHub Actions release entrypoint.

Build release assets with:

```bash
REQUIRE_SPARKLE_SIGNATURES=1 \
REQUIRE_STABLE_CODESIGN=1 \
VERIFY_APPCAST=1 \
UPDATE_APPCAST=1 \
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
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
