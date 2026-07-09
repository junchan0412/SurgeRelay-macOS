# Security Notes

Surge Relay is a local macOS utility that reads user-selected module sources,
converts them with an embedded Script-Hub-compatible engine, and publishes the
result to local Surge folders or GitHub repositories.

## Distribution Trust

Releases are signed with the fixed self-signed certificate
`Surge Relay Self-Signed Code Signing` and update packages are signed with
Sparkle 2 EdDSA signatures. Without Apple Developer ID notarization, the first
manual browser download can still receive macOS quarantine. Use the in-app
updater for later updates whenever possible.

## Web Management

The Web Management server is disabled by default and listens on loopback unless
remote access is explicitly enabled.

- Requests larger than 4 MB are rejected.
- Invalid, negative, or oversized `Content-Length` values are rejected with
  `400 Bad Request`.
- Unsafe methods require same-origin `Origin` or `Referer`.
- Non-browser clients can use `Authorization: Bearer <token>`.
- Browser sessions use an `HttpOnly` `SameSite=Strict` cookie after the token
  bootstrap request.
- The browser frontend does not persist the raw access token in
  `sessionStorage`.

## Script-Hub Engine Supply Chain

The default Script-Hub module URL is pinned to a specific
`Script-Hub-Org/Script-Hub` commit instead of the floating `main` branch.

When updating the embedded engine, Surge Relay:

- accepts only `https://raw.githubusercontent.com/Script-Hub-Org/Script-Hub/...`;
- rejects `main`, `master`, and `HEAD` revisions;
- rewrites script references from the module to the same pinned revision;
- records the upstream revision and per-script SHA-256 hashes;
- rejects a repeated pinned revision if previously recorded script hashes
  change.

The JavaScriptCore HTTP bridge only allows `http` and `https`, blocks loopback,
`.local`, private, link-local, multicast, and reserved addresses, and limits
bridge responses to 20 MB.

## GitHub Publishing

GitHub owner, repository, and branch values are structurally validated before
API URLs are built. Module output directories continue to use the existing
normalization rules so generated module paths stay predictable.

## macOS Permissions

The app currently keeps `NSAllowsArbitraryLoads=true` because users can add
arbitrary HTTP module sources that must still be convertible. App Sandbox is currently disabled because Surge Relay writes to user-selected Surge/iCloud
directories and maintains compatibility with existing non-sandboxed installs.

Future sandboxing should use security-scoped bookmarks for local module roots
and migration coverage for existing configuration directories. The current
release hardening status and migration order are tracked in
`docs/RELEASE_HARDENING.md`.
