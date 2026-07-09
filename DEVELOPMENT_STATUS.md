# Surge Relay Development Status

Updated: 2026-07-10

This document tracks the optimization work completed after the deep audit and the remaining work that should guide future development. The current release target is `1.3.15 (64)`.

## Completed Work

### Product Behavior

- Local and GitHub module storage are modeled separately from the original source URL, so scanned local modules, remote sources, and converted outputs no longer share one ambiguous path concept.
- Module sidebar sections can be collapsed or expanded, and remote modules that are not independently published are labeled as remote/cache-backed instead of GitHub-stored.
- Source-name autofill now uses a shared bounded remote fetcher across the macOS editor and Web API, with private-address blocking, response-size limits, and timeout enforcement.
- The release workflow pins external actions to full commit SHAs, and release preflight rejects mutable action references before signing assets.
- The Cloudflare Worker example now pins Wrangler with a committed npm lockfile and documents `npm ci` based deployment.
- Release preflight now verifies that the documented distribution hardening posture matches the current ATS and App Sandbox configuration.
- Existing local `.sgmodule` files with Script-Hub `#SUBSCRIBED` metadata can be restored with their original source URL, source format, parameters, category, and local relative path.
- Update failures now preserve user-facing causes such as 404, 403, 429, DNS failures, timeouts, and TLS errors, and the UI can copy the detailed error.
- GitHub automatic publishing skips empty publish sets instead of attempting a meaningless publish when no standalone module is selected.
- Combined module participation defaults and UI visibility now respect the combined-module setting.
- Changing the local configuration storage directory migrates the app-managed configuration files into the new directory instead of leaving stale state behind.

### Architecture And Maintainability

- `AppModel` has been split into focused extensions for credentials, diagnostics, settings, Web management, module state, local modules, module output folders, preview access/editing, publishing, GitHub publishing, updates, update completion, automatic publishing, published output, and foreground work lifecycle.
- Shared models were split from catch-all files into focused model files such as `ModuleSourceModels.swift`, `PublishModels.swift`, `UpdateHistoryModels.swift`, `ConversionModels.swift`, diagnostic model files, and GitHub release/API models.
- Publishing, update completion, local import, local published files, metadata refresh, update failure, module search, module ordering, and module draft rules now live in service/planner types with targeted tests.
- Desktop module, settings, preview, sidebar, detail, and editor views have been progressively split into smaller SwiftUI files.
- Web management logic has been split across `web-logic.js`, `web-format.js`, `web-markup.js`, `web-api.js`, `web-state.js`, `web-editor.js`, `web-feedback.js`, `web-preview.js`, `web-sidebar.js`, and `web-activity.js`.

### Safety Boundaries

- Local publish continues to rely on managed-file markers and explicit cleanup previews; generated outputs must not silently overwrite user-owned original modules.
- Local source self-export protection is centralized in `PublishCoordinator`.
- GitHub publish planning validates duplicate paths, selected publish sets, stale deletes, and no-op publishes before writing.
- Release packaging strips quarantine/resource-fork metadata from generated zip/pkg contents.

### Testing And Release Tooling

- Unit tests have been split into focused files for publishing, GitHub releases, Web management, Web HTTP security, settings, diagnostics, Script-Hub, local publishing, local import, ordering, search, metadata refresh, update failures, and task activity.
- Web resources now have Node syntax checks, split behavior tests, a small aggregate entrypoint, and a lightweight DOM regression harness.
- `script/check_release_configuration.sh` verifies version/build metadata, Sparkle configuration, appcast latest item, Web resources, release scripts, and GitHub Actions release workflow references.
- `script/build_release_assets.sh` builds `.app.zip`, `.pkg`, sha256 sidecars, Sparkle EdDSA signature files, and can update `appcast.xml`.
- Release builds use the fixed self-signed code signing identity `Surge Relay Self-Signed Code Signing` and Sparkle EdDSA update signatures.

## Pending Work

### High Priority

- Add automated UI screenshot or interaction coverage for the macOS settings window, module editor, module detail page, and Web management page.
- Continue shrinking `WebResources/app.js` by extracting detail-action routing or module-editor orchestration if those sections keep growing.
- Continue shrinking the largest Swift files that still exceed roughly 300 lines, especially `EmbeddedScriptHubEngine.swift`, `ModuleFileStore.swift`, `PersistenceStore.swift`, `ModuleDetailView.swift`, and larger focused test files.
- Keep comparing upstream `EEliberto/SurgeRelay-macOS:main` changes and selectively port fixes that improve stability without undoing this fork's storage/publishing model.

### Release And Distribution

- Keep using fixed self-signed signing plus Sparkle in-app updates until an Apple Developer ID and notarization path is available.
- If Developer ID becomes available, add notarization validation and document the Gatekeeper behavior difference from self-signed releases.
- Periodically verify that GitHub Release assets include `.app.zip`, `.pkg`, `.sha256`, and `.sparkle.txt` files, and that the latest `appcast.xml` item points at the current `.app.zip`.

### Future Design Work

- Evaluate App Sandbox and security-scoped bookmarks for user-selected local module roots.
- Add a more visual Web management smoke test or Playwright snapshot once the UI stabilizes.
- Consider row-level Web list patching for very large module lists if full sidebar rerenders become observable.
- Keep all local cleanup behavior behind publish previews and explicit confirmation.

## Release Checklist

Use the Xcode beta toolchain explicitly:

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer"
```

Before publishing:

```bash
git diff --check
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" ./script/check_release_configuration.sh
```

For a signed release asset build:

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
REQUIRE_SPARKLE_SIGNATURES=1 \
REQUIRE_STABLE_CODESIGN=1 \
VERIFY_APPCAST=1 \
UPDATE_APPCAST=1 \
./script/build_release_assets.sh
```

Then create the GitHub Release on `junchan0412/SurgeRelay-macOS` using the generated files under `dist/release-v<version>/artifacts`.
