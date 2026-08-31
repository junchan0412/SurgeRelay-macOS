# Release Hardening

This document records the current public distribution posture for Surge Relay and the order for future hardening work. It is intentionally tied to `script/check_release_configuration.sh` so release builds fail when the documented security posture drifts away from project settings.

## Current Status

- Code signing: fixed self-signed certificate, `Surge Relay Self-Signed Code Signing`.
- Update signing: Sparkle 2 EdDSA signatures are required for release assets.
- Notarization: not enabled because there is no Apple Developer ID signing path in this distribution.
- Gatekeeper: first manual browser download can still be quarantined; in-app Sparkle updates are the preferred update path after first install.
- App Transport Security: `NSAllowsArbitraryLoads=true`.
- App Sandbox: disabled.

There is currently no scheduled date for Apple Developer ID signing, notarization, ATS tightening, or App Sandbox migration. Compatibility with existing module sources, user-selected directories, and installed configurations remains the release priority.

## Why These Settings Exist

Surge Relay accepts user-provided HTTP and HTTPS module sources. Some real module sources are plain HTTP, so ATS cannot be fully tightened without either breaking existing workflows or adding a compatibility path for explicitly trusted user sources.

Surge Relay also writes converted modules to user-selected local Surge or iCloud directories. Moving to App Sandbox needs security-scoped bookmarks for module roots, configuration directories, and migration coverage for existing non-sandboxed installs.

The current posture changes only after all of the following are available:

1. An explicit user-source exception model that preserves required plain HTTP module sources without restoring a global network exception.
2. Security-scoped bookmarks for every user-selected module root and configuration directory.
3. A migration path for existing non-sandboxed installs, including stale or unavailable bookmarks.
4. Regression coverage for source conversion, local/iCloud publishing, configuration migration, Sparkle updates, and first-run installation.

## Hardening Order

1. Keep fixed self-signed signing plus Sparkle EdDSA updates for releases without an Apple Developer ID.
2. Keep release preflight checks for signing identity, Sparkle signatures, appcast metadata, ATS/Sandbox documentation, and GitHub release assets.
3. Design and test a narrower user-source network policy or explicit exception model before changing global ATS behavior.
4. Introduce and test security-scoped bookmarks for local module roots and configuration storage before enabling App Sandbox.
5. Add compatibility migration and regression tests for existing non-sandboxed installs before changing entitlements.
6. If an Apple Developer ID becomes available and a migration is explicitly scheduled, add Developer ID signing, notarization, stapling, and notarization verification to the release scripts.

## Release Checklist

- `README.md` and `SECURITY.md` must describe the current first-run quarantine behavior.
- `README.md`, `SECURITY.md`, and this document must mention `NSAllowsArbitraryLoads=true` while ATS remains globally relaxed.
- `README.md`, `SECURITY.md`, and this document must mention the disabled App Sandbox while `ENABLE_APP_SANDBOX=NO`.
- `script/check_release_configuration.sh` must fail if these documented statements stop matching project settings.
