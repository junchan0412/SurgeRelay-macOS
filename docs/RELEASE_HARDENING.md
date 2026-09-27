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

## CI Compiler Tracking

The two `v2.2.1` packaging attempts on 2026-09-26 ([first run](https://github.com/junchan0412/SurgeRelay-macOS/actions/runs/36222058619), [latest run](https://github.com/junchan0412/SurgeRelay-macOS/actions/runs/36233815269)) passed release preflight and certificate import, then failed in Swift IR generation before asset upload. Both used `macos-26-arm64` image `20260907.0351.1`, Xcode `26.6 (17F113)`, and Apple Swift `6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`. The failing generated thunk was `$sSbScA_pSgIeAghyg_SbIeAghn_TR`, with `SyncCallEmission::setArgs` and `SmallVectorBase::grow_pod` in the abort backtrace.

As checked on 2026-09-27, the [runner image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) still lists that image and default Xcode. [Swift issue #91702](https://github.com/swiftlang/swift/issues/91702) reports the same compiler version and stack family for a global-actor closure converted to `@isolated(any)`. An upstream contributor points to [PR #87778](https://github.com/swiftlang/swift/pull/87778), integrated in Swift 6.4. This is a related lead, not a confirmed diagnosis of Surge Relay's crash.

`ModuleSidebarView` passes a `@MainActor @Sendable (Bool) -> Void` directly to `Binding.set`, which is a candidate for reducing the generated Bool thunk. The following reduction compiles with local Xcode `27.0 (27A266a)` / Swift `6.4`; Xcode 26.6 is not available locally, so it is **not yet a verified reproducer**:

```swift
import SwiftUI

@MainActor
func binding(setter: @escaping @MainActor @Sendable (Bool) -> Void) -> Binding<Bool> {
    Binding(get: { false }, set: setter)
}
```

Save it as `repro.swift` and compare toolchains with `xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -O -whole-module-optimization -c repro.swift -o /dev/null`. Only report it upstream as a reproducer after confirming the same failure on the affected toolchain.

`Package Release App` records the image, Xcode, Swift, SDKs, source commit, scrubbed build output, and available `.dia` compiler diagnostics in a `release-diagnostics-<run>-<attempt>` artifact retained for 14 days. It excludes signing keychains, certificates, and package payloads; the Sparkle private key is removed from build output before it is saved.

Once the hosted toolchain changes, dispatch the updated workflow from `main` with `verify_only=true` and the existing release tag:

```sh
gh workflow run package-release-app.yml --repo junchan0412/SurgeRelay-macOS --ref main \
  -f tag=v2.2.1 -F verify_only=true -F launch_smoke_test=true
```

This still builds and checks signed packages and a temporary checkout appcast, but skips GitHub Release creation, upload, and replacement. The default `verify_only=false` retains the normal publishing behavior. Do not use the old run's **Re-run jobs** action for compiler checks: the old workflow uploads with `--clobber`, replacing the published assets and their Sparkle metadata. Compare the recorded toolchain and crash signature before deciding whether to report a new compiler bug or perform a normal release.
