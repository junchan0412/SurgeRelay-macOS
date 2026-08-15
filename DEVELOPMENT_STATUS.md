# Surge Relay Development Status

Updated: 2026-08-16

This document tracks the optimization work completed after the deep audit and the remaining work that should guide future development. The current release target is `1.3.37 (86)`.

## 当前状态

- `1.3.37 (86)` 的变更已记录在 `CHANGELOG.md`，包含右键菜单“复制模块 / 拷贝更新地址 / 拷贝输出路径”与菜单栏“需要处理”监控计数。
- 此前版本已落地：多选 / 发布所选按模块存放位置发布、侧边栏多维筛选与排序、远程来源本地模块本地发布、新模块首次更新失败自动重试等。
- 凭据存储已从系统钥匙串迁移到配置目录内的 AES-256-GCM 本地加密文件，无开发者账户签名也能正常保存。
- 自定义图标会重写模块输出中的 `#!icon`，桌面端、Web 管理端和发布产物使用同一个值。
- 订阅模块可以从登记的 Script-Hub 转换地址恢复内嵌 `originalURL`，即使转换内容缺少 `#SUBSCRIBED` 标记，也能按订阅初始地址继续更新。
- 初始来源恢复“远程来源”分类：有有效 `#SUBSCRIBED` 记录时归为订阅来源；没有该记录但更新地址为 HTTP/HTTPS 时归为远程来源；只有本地文件且无记录时才归为自写模块。
- 侧边栏提供“全部 / 可更新 / 不可更新 / 更新失败 / 尚未更新 / 参与总模块 / 不参与总模块 / 本地 / GitHub / 订阅来源 / 远程来源 / 自写模块 / 独立发布 / 仅缓存 / 需要处理 / 覆盖冲突 / 未分类”筛选，并与搜索叠加；支持按名称 / 最近更新 / 最近创建 / 状态优先级排序，筛选与排序选择跨启动持久化。
- 本地独立模块的自覆盖保护仅在“转换前来源”确实是本地文件时启用，远程来源本地模块会正常写入其输出目录。
- 新模块首次自动更新遇到瞬时 404 / 5xx / 网络抖动失败时会自动重试一次，无需用户手动再次更新。
- 发布链路仍为固定自签名 + Sparkle EdDSA；ATS 全局放宽与 App Sandbox 关闭状态与 `docs/RELEASE_HARDENING.md` 保持一致。

## Completed Work

### Product Behavior

- GitHub Token 与 Web 管理令牌改存到配置目录内的本地加密文件；启动、设置保存和 Web 管理令牌重置都不再访问系统钥匙串。
- 自定义图标会写入模块输出的 `#!icon`，来源图标缺失或不匹配时自动替换，未填写自定义图标时保留来源图标。
- 登记地址是 Script-Hub 转换 URL 的模块可以从地址本身恢复内嵌 `originalURL`，并在缺少 `#SUBSCRIBED` 标记时按订阅初始地址更新。
- 模块详情始终显示“更新地址”，只有在原始地址或登记地址与更新地址不同时才额外展示对应行，减少重复信息。
- 通用设置页的配置储存目录旁新增 Finder 快捷入口。
- Web management exposes a lightweight `/api/activity` progress endpoint and polls it during bulk updates, with soft reconnect across brief SSE drops.
- Network recovery restarts the local Web server when needed and re-queues automatic GitHub publish after connectivity returns.
- Settings tabs keep a small back/forward history; the module detail toolbar can hide or show the sidebar.
- Web favicon/PWA icons ship as transparent multi-size assets with maskable manifest entries.
- Source format recognition treats `.sgmodule` / `.plugin` / `.lpx` as definitive, repairing mislabeled Quantumult X records and keeping native Surge updates on the direct fetch path.
- Local and GitHub standalone destinations are modeled separately from initial source provenance. Initial source resolves valid converted `#SUBSCRIBED originalURL` metadata to subscribed, HTTP/HTTPS update addresses without that marker to remote, and local files without metadata to self-authored.
- Draft modules remain in a pending-source state until their first successful update. A valid subscription uses `originalURL` as the resolved update source, while registration URLs and local storage paths retain separate responsibilities.
- Standalone publishing is destination-specific: local modules publish only locally, GitHub modules publish only to GitHub, and cache-backed modules can still contribute to the combined module without producing a standalone file.
- The macOS and Web editors share the same default-storage decision, destination-specific folder options, disabled-target warnings, and source/storage terminology.
- Module sidebar sections can be collapsed or expanded. Storage grouping always follows the persisted local/GitHub destination; disabling standalone publishing is shown as cache-backed output behavior instead of inventing a third remote storage category.
- Local physical modules repair missing `#SUBSCRIBED` provenance and stale relative filenames at startup. Confirmed subscription metadata survives later native upstream/cache payloads that omit the Script-Hub marker.
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

- 凭据文件使用 AES-256-GCM 加密并限制为当前用户可读写；诊断报告只导出存储位置和检查状态，不导出密钥或令牌内容。
- Local publish continues to rely on managed-file markers and explicit cleanup previews; generated outputs must not silently overwrite user-owned original modules.
- Local source self-export protection is centralized in `PublishCoordinator`.
- GitHub publish planning validates duplicate paths, selected publish sets, stale deletes, and no-op publishes before writing.
- Release packaging strips quarantine/resource-fork metadata from generated zip/pkg contents.

### Testing And Release Tooling

- Release preflight 会校验 `SurgeRelay/` 与 `SurgeRelayTests/` 下所有 Swift 源文件都已登记到 Xcode 工程，避免新增文件后忘记同步 `project.pbxproj`。
- `script/build_and_run.sh` is the shared Debug build, launch, log, telemetry, verification, and isolated UI-QA entrypoint; `.codex/environments/environment.toml` and the shared Xcode scheme use the same project configuration.
- Unit tests have been split into focused files for publishing, GitHub releases, Web management, Web HTTP security, settings, diagnostics, Script-Hub, local publishing, local import, ordering, search, metadata refresh, update failures, and task activity.
- Web resources now have Node syntax checks, split behavior tests, a small aggregate entrypoint, and a lightweight DOM regression harness.
- `script/check_release_configuration.sh` verifies version/build metadata, Sparkle configuration, appcast latest item, Web resources, release scripts, and GitHub Actions release workflow references.
- `script/build_release_assets.sh` builds `.app.zip`, `.pkg`, sha256 sidecars, Sparkle EdDSA signature files, and can update `appcast.xml`.
- Release builds use the fixed self-signed code signing identity `Surge Relay Self-Signed Code Signing` and Sparkle EdDSA update signatures.

### Performance And Memory

- Activity polling uses a compact payload instead of full `/api/state` snapshots during long update runs.
- Search metadata and module-summary signatures are cached across bulk updates; module persistence is deferred during updateAll so progress ticks no longer rewrite modules.json on every source.
- Sidebar presentation is rebuilt from a stable signature instead of every AppModel field change; detail selection uses asymmetric transitions while preview editors stay mounted after first open.
- Sidebar module rows no longer observe the full AppModel graph, reducing list thrash during mass updates; status-card compositing and icon reloads were lightened for smoother progress animation.
- Detail/preview segmented control and section collapse use short snappy transitions while keeping the preview editor mounted after first open.
- Module metadata parsing is line-based and avoids recompiling regular expressions during refreshes.
- Local output-folder discovery runs off the main actor and reuses a bounded cache instead of recursively scanning during SwiftUI redraws.
- Module icons load and decode on utility tasks keyed by icon revision; hidden preview editors are mounted only after the preview tab is used and are released when the selected module changes.
- Sidebar grouping performs one classification pass over modules, and code-highlighting patterns are reused across editor updates.

## 目标

- 发布 `1.3.24 (73)`，随后继续推进 macOS 设置窗口、模块编辑器、详情页和 Web 管理端的自动化 UI 截图/交互覆盖。
- 为 Web 管理端补充 Playwright 冒烟测试；继续拆分 `WebResources/app.js` 和较大的 Swift 文件。
- 持续对照 `docs/UPSTREAM_SYNC.md` 选择性移植 upstream 修复，不合并与本 fork 存储/发布模型冲突的改动。
- 在 Apple Developer ID 可用前维持固定自签名 + Sparkle 更新；可用后补充 Developer ID 签名、公证、stapling 与验证。
- 逐步收敛全局 ATS 放宽与 App Sandbox 关闭状态：先引入用户来源网络策略或显式例外模型，再补 security-scoped bookmark 与迁移测试。

## Pending Work

### High Priority

- Add automated UI screenshot or interaction coverage for the macOS settings window, module editor, module detail page, and Web management page.
- Continue shrinking `WebResources/app.js` by extracting detail-action routing or module-editor orchestration if those sections keep growing.
- Continue shrinking the largest Swift files that still exceed roughly 300 lines, especially `EmbeddedScriptHubEngine.swift`, `ModuleFileStore.swift`, `PersistenceStore.swift`, `ModuleDetailView.swift`, and larger focused test files.
- Keep comparing upstream `EEliberto/SurgeRelay-macOS:main` using `docs/UPSTREAM_SYNC.md`; selectively port fixes that improve stability without undoing this fork's storage/publishing model.

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

Before publishing (当前目标版本为 `1.3.24 (73)`):

```bash
git diff --check
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
VERSION=1.3.24 BUILD=73 \
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
./script/check_release_configuration.sh
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
