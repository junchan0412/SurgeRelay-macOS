# Upstream Sync Notes

本文件记录本 fork（`junchan0412/SurgeRelay-macOS`）相对 upstream（`EEliberto/SurgeRelay-macOS`）的提交分叉情况，以及后续如何更精准地同步。

最后审查日期：2026-07-25  
审查基线：

| 引用 | SHA | 说明 |
| --- | --- | --- |
| fork `main` / 当前审查点 | `633e543` | `Update 1.3.19 release metadata` |
| upstream `main` | `a3e667c` | `Revert "Fix macOS 27 toolbar layout"` |
| 共同祖先 `merge-base` | `30203ef` | `Update README.md` |

对比命令：

```bash
git fetch upstream main
git fetch origin main
git rev-list --count origin/main..upstream/main   # behind
git rev-list --count upstream/main..origin/main   # ahead
git log --oneline origin/main..upstream/main
```

审查时计数：**behind 51 / ahead 220**。

## 1. 分叉模型（先读这个）

本 fork 不是 upstream 的快进分支，而是从 `30203ef` 之后各自演进：

- fork 侧大量重构：本地/GitHub 双发布、`#SUBSCRIBED` 初始来源、Script-Hub 固定 revision、AppModel/Web 资源拆分、自签名 + Sparkle 发布链路。
- upstream 侧主要演进：iCloud 输出、Web 视觉/移动端、欢迎向导、**Surge Ponte 客户端/服务端远程管理**、以及大量 release/appcast/图标杂项提交。

因此默认策略是：

1. **不要**对 upstream 做无过滤 merge / rebase。
2. 按“主题/能力”挑选可移植补丁，移植到本 fork 的现有模块边界中。
3. 每次同步后更新本文件的“已审查 upstream tip”和“已移植/跳过”清单。

## 2. 本 fork 不可被 upstream 覆盖的边界

移植任何 upstream 改动前，先检查是否触碰这些边界：

| 边界 | 本 fork 现状 | 不要直接采用的 upstream 方向 |
| --- | --- | --- |
| 模块关系模型 | `storageLocation` × `initialSource(#SUBSCRIBED)` | 把 iCloud/GitHub/远程来源揉成单一 `storageMode` 语义 |
| 发布模型 | `publishToLocal` + `publishToGitHub` 可并存；独立模块按 `storageLocation` 输出 | 仅 iCloud 或仅 GitHub 的旧路径假设 |
| 架构 | AppModel 扩展拆分、planner/service 化、Web 资源拆分（`web-*.js`） | 重新塞回巨大 `AppModel.swift` / 单体 `RootView` / 单体 `app.js` |
| 远程管理 | 本机 Web 管理 + 钥匙串 token | Surge Ponte 服务端/客户端整套模式（除非明确立项） |
| 发布产物 | 固定自签名 + Sparkle EdDSA + `script/build_release_assets.sh` | upstream 自己的 build 号、appcast 私钥、误提交图标/README 回滚链 |
| Worker 示例 | 保留 `Deployment/CloudflareWorker` | upstream `2dbd992` 删除 Deployment 目录 |

## 3. 落后 51 个提交总表

按时间从新到旧。分类：

- `port`：值得移植或已移植
- `adapt`：概念有价值，但必须按本 fork 模型重写
- `skip-release`：纯发版/appcast/build 号
- `skip-noise`：图标目录增删、README 误改回滚、误上传撤回
- `skip-product`：与本 fork 产品方向冲突或已由本 fork 覆盖

| SHA | 日期 | 标题 | 分类 | 结论 |
| --- | --- | --- | --- | --- |
| `a3e667c` | 2026-07-23 | Revert "Fix macOS 27 toolbar layout" | skip-noise | 与 `5c7845a` 成对回滚；净效果为零 |
| `5c7845a` | 2026-07-23 | Fix macOS 27 toolbar layout | adapt | 侧边栏显隐工具栏可参考；NSSegmentedControl 细节与本 fork 的 detail pane 结构不同 |
| `5c234b4` | 2026-07-23 | Release 260723 / 27072301 | skip-release + skip-product | 夹带 Ponte/远程客户端与大型发版噪声 |
| `b19d0dd` | 2026-07-17 | Release 27071709 | skip-release | 远程客户端细节，附发版 |
| `feeb3cd` | 2026-07-17 | Release 27071708 | adapt | `/api/activity` 实时进度、SSE soft reconnect、`RELEASE.md` 有参考价值；Ponte 客户端本体不移植 |
| `7659fde` | 2026-07-17 | Release 27071707 | skip-release | 仅版本/appcast |
| `71c14ba` | 2026-07-17 | Fix Sparkle edSignature | skip-release | 仅 appcast 签名修正 |
| `a201014` | 2026-07-17 | Release 27071706 | adapt | `NetworkPathMonitor`、断线恢复、菜单栏断开态有参考；服务端常驻/Ponte 模型不直接合 |
| `da6f407` | 2026-07-17 | Release 27071705 | skip-release | ModulesView 小改 + 发版 |
| `d5ea0da` | 2026-07-17 | Release 27071704 | adapt | Web 小改可对照；发版噪声大 |
| `cbad896` | 2026-07-17 | Fix web icons transparency | adapt | favicon/PWA 图标透明度可参考；本 fork 图标集不同，勿整包覆盖 |
| `2f4814b` | 2026-07-17 | Fix Sparkle signing | skip-release | 发版签名 |
| `4d34018` | 2026-07-17 | Update README.md | skip-noise | upstream README 文案 |
| `ef1b1a1` | 2026-07-17 | Update README.md | skip-noise | 同上 |
| `817babb` | 2026-07-17 | Delete Surge Relay.icon | skip-noise | 图标目录来回删 |
| `ba96e73` | 2026-07-17 | Revert accidental README/icon uploads | skip-noise | 事故回滚 |
| `5a68545` | 2026-07-17 | Release 27071701 | skip-product | 引入 WelcomeWizard + Ponte + 大量 UI 重做；与本 fork 架构冲突 |
| `cd77104` | 2026-07-10 | Fix Sparkle update signing | skip-release | 发版 |
| `e9e27f0` | 2026-07-10 | Fix Web layout | **port** | 移动端滚动/`100lvh`/`copy-button`/icon-dialog 等布局修复；已部分吸收 |
| `6a014f5` | 2026-07-10 | Restore README exactly | skip-noise | README 恢复 |
| `b6ba14e` | 2026-07-10 | Restore README | skip-noise | README 恢复 |
| `a689976` | 2026-07-10 | Delete devices icons.icon | skip-noise | 设备图标包删除 |
| `f208085` | 2026-07-10 | Delete Surge Relay.icon | skip-noise | 图标目录删除 |
| `2dbd992` | 2026-07-10 | Delete Deployment directory | **skip-product** | 本 fork **保留** Worker 示例，禁止跟随删除 |
| `05675a7` | 2026-07-10 | Format 260710 release notes | skip-release | appcast 文案 |
| `65bf590` | 2026-07-10 | Release 260710 | skip-product | 大视觉/平台 summary 图标与本 fork 发布模型不同 |
| `760632c` | 2026-07-03 | Release 26070303 | adapt | 含 `MainWindowCloseBehavior` 使用点、设置导航；发版噪声大 |
| `a26366b` | 2026-07-03 | Improve GitHub/Cloudflare guide | **port** | 指南与截图有用；已移植并改链到本 fork |
| `41629f1` | 2026-07-03 | Publish 26070302 feed | skip-release | appcast |
| `64a39ab` | 2026-07-03 | Fix mobile Web layout | **port** | toast/安全区/参数区移动端布局；已移植 |
| `c039417` | 2026-07-03 | Update README.md | skip-noise | README |
| `75948d0` | 2026-07-03 | Update GitHub/Cloudflare section | adapt | README 配置说明；本 fork README 已有对应段落 |
| `0f02efb` | 2026-07-03 | Fix formatting issue in README | skip-noise | 格式 |
| `12c3384` | 2026-07-03 | Update README.md | skip-noise | README |
| `5e13631` | 2026-07-03 | Update GitHub-Cloudflare-Guide | **port** | 指南迭代，已并入移植版 |
| `9666d9a` | 2026-07-03 | Update GitHub-Cloudflare-Guide | **port** | 同上 |
| `5abec80` | 2026-07-03 | Update GitHub-Cloudflare-Guide | **port** | 同上 |
| `5fe440c` | 2026-07-03 | Update GitHub-Cloudflare-Guide | **port** | 同上 |
| `3a865c0` | 2026-07-03 | Delete docs/images | skip-noise | 删除旧 SVG 示意图 |
| `28dbd76` | 2026-07-03 | Add direct setup links | **port** | 指南深链，已并入 |
| `1e38621` | 2026-07-03 | Add GitHub and Cloudflare setup guide | **port** | 指南初版，已并入 |
| `bfd5ff4` | 2026-07-03 | Publish 260703 feed | skip-release | appcast |
| `89da8fc` | 2026-07-03 | Release 260703 | skip-release | 发版 |
| `77682d8` | 2026-07-02 | Delete Surge Relay.icon | skip-noise | 图标目录 |
| `ecc3ad8` | 2026-07-02 | Publish 26070202 feed | skip-release | appcast |
| `5cdc38e` | 2026-07-02 | Update settings and iCloud output | adapt | iCloud 写出协调、设置分栏导航有参考；存储模型不同，不可整提交合入 |
| `3523977` | 2026-07-02 | Release 260702 source | skip-release | 发版/资源 |
| `13f40c3` | 2026-07-02 | Publish 260702 feed | skip-release | appcast |
| `19e249c` | 2026-07-01 | Delete Surge Relay.icon | skip-noise | 图标目录 |
| `3111632` | 2026-07-01 | Update README.md | skip-noise | README |
| `3fc72a6` | 2026-07-01 | Release 1.1.1 | **port** | 引入 `MainWindowCloseBehavior`：关闭主窗口隐藏到菜单栏；已移植 |

### 统计

| 分类 | 约计 |
| --- | --- |
| skip-release / skip-noise | ~33 |
| skip-product（Ponte/大重做/删 Deployment） | ~4 个主题提交 |
| port / 已吸收 | ~10 |
| adapt / 后续候选 | ~4 个主题 |

## 4. 本次已选择性移植到本 fork

审查分支：`codex/upstream-sync-review`

| 主题 | upstream 来源 | 本 fork 落地 | 说明 |
| --- | --- | --- | --- |
| 关闭窗口驻留菜单栏 | `3fc72a6` / `760632c` | `SurgeRelay/Views/MainWindowCloseBehavior.swift` + `RootView` | close 按钮改为 `orderOut` + `.accessory` |
| 从菜单栏恢复主窗口 | 配合上项 | `MenuBarContent.activateMainWindow` | 恢复 `.regular` activation policy 再 `openWindow` |
| 移动端 toast / 安全区 | `64a39ab` | `WebResources/app.css` + `index.html` | toast 换行、safe-area、`aria-atomic` |
| 复制按钮/成功态样式 | `e9e27f0` | `WebResources/app.css` | `.copy-button` / `.copy-success` |
| 预览区移动端高度 | `e9e27f0` 思路 | `app.css` 使用 `100svh` | 与本 fork 已有 `100svh` 移动壳层对齐 |
| GitHub + Cloudflare 指南 | `1e38621`…`a26366b` | `docs/GitHub-Cloudflare-Guide.md` + `docs/images/*` | 链接改为本 fork；README 增加入口 |
| Worker 示例 | 对比 `2dbd992` | **不删除** `Deployment/CloudflareWorker` | 明确与 upstream 相反 |

## 5. 明确不移植，以及原因

### 5.1 Surge Ponte 远程客户端/服务端

涉及提交簇：`5a68545`、`a201014`、`feeb3cd`、`b19d0dd`、`5c234b4` 等。

新增/重写面包括：

- `WelcomeWizardView`
- `RemoteManagementClient`
- `AppModel+RemoteClient`
- `AppModel+WebServerLifecycle`
- `NetworkPathMonitor`
- `RemoteConnectionState`
- 菜单栏断开态 / 全页 server unavailable

原因：

1. 与本 fork 的“本机 Web 管理 + 本地/GitHub 发布”产品边界不同。
2. upstream 把大量逻辑重新堆回 `AppModel`/`RootView`，会冲掉本 fork 已完成的拆分。
3. 若未来要做，应作为独立特性设计，而不是 cherry-pick 大提交。

可拆出的局部灵感（以后单独做）：

- 网络恢复 debounce（`NetworkPathMonitor`）
- 更新过程的轻量 `/api/activity` 进度投影
- 菜单栏连接状态着色

### 5.2 iCloud 专用输出/设置大改

提交：`5cdc38e`、`65bf590` 等。

原因：本 fork 已用可配置本地根目录覆盖 iCloud Surge 路径，并有 managed-file / 冲突保护；upstream 的 storage UI 与双发布模型不一致。

### 5.3 发版与 appcast 链

所有 `Release …` / `Publish … feed` / Sparkle edSignature 修正。

原因：版本号体系、签名身份、仓库、脚本都不同；只同步**代码行为**，不同步 upstream 的 appcast 历史。

### 5.4 图标目录反复增删与 README 事故

`Surge Relay.icon` / `devices icons.icon` 的多次 Add/Delete，以及 `ba96e73` 事故回滚。

原因：无产品价值，只会污染历史。

## 6. 后续精准同步流程

每次准备吸收 upstream 时按此清单执行：

```bash
# 1. 更新远端
git fetch upstream main
git fetch origin main

# 2. 看新增落后提交（相对上次记录的 upstream tip）
git log --oneline a3e667c..upstream/main

# 3. 只看源码路径，过滤发版噪声
git log --oneline --name-only a3e667c..upstream/main -- \
  SurgeRelay docs Deployment script

# 4. 对可疑提交做文件级 diff，而不是整提交 cherry-pick
git show <sha> -- SurgeRelay/path/of/interest

# 5. 手工移植到本 fork 对应模块
#    - 窗口行为 -> Views/
#    - Web 布局 -> WebResources/
#    - 发布/存储 -> Services/*Planner + AppModel+*
#    - 文档 -> docs/

# 6. 验证
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
  xcodebuild test -project "Surge Relay.xcodeproj" -scheme "Surge Relay" \
  -destination 'platform=macOS,arch=arm64'
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs

# 7. 更新本文件
#    - 刷新 “已审查 upstream tip”
#    - 把新提交写入分类表
#    - 记录移植/跳过原因
```

### cherry-pick 禁用条件

出现以下任一情况时，禁止直接 `git cherry-pick`：

- 同时改 `AppModel.swift` 超过约 100 行且本 fork 已拆扩展
- 引入 `WelcomeWizard` / `RemoteManagementClient` / `RelayDeviceMode`
- 删除 `Deployment/`
- 只改 `appcast.xml` / 版本号 / 图标 asset 来回
- 依赖 upstream 的 iCloud-only 或 Ponte 设置字段

## 7. adapt 候选跟进状态

| # | 主题 | 状态 | 本 fork 落地 |
| --- | --- | --- | --- |
| 1 | Web `/api/activity` 进度 | **done (1.3.20)** | `WebManagementAPI` + `WebActivityPayload.completedCount/totalCount` + `web-state` 轮询/`app.js` soft reconnect |
| 2 | 网络恢复重连 | **done (1.3.20)** | `NetworkPathMonitor` → 重启 Web server / 重排队自动发布 |
| 3 | favicon / PWA 透明图标 | **done (1.3.20)** | `favicon.ico/png`、`apple-touch*`、`brand-icon*` + manifest any/maskable |
| 4 | 设置页历史返回/前进 | **done (1.3.20)** | `SettingsView` back/forward stack |
| 5 | toolbar 侧边栏显隐 | **done (1.3.20)** | `ModuleDetailPaneView` navigation toolbar toggle |

后续若 upstream 继续演进，优先复查 Ponte 之外的局部增强，而不是整提交合入。

## 8. 相关文件

- 本文件：`docs/UPSTREAM_SYNC.md`
- 私有仓库指南：`docs/GitHub-Cloudflare-Guide.md`
- Worker 示例：`Deployment/CloudflareWorker/`
- 发布硬化说明：`docs/RELEASE_HARDENING.md`

## 9. 变更记录

| 日期 | upstream tip 已审查到 | 动作 |
| --- | --- | --- |
| 2026-07-25 | `a3e667c` | 首份分叉审查；移植 MainWindowCloseBehavior、Web toast/copy 样式、Cloudflare 指南；明确跳过 Ponte 与 Deployment 删除 |
| 2026-07-25 | `a3e667c` | 完成 5 项 adapt：`/api/activity`、NetworkPathMonitor、PWA 图标、设置历史、侧边栏切换；发布 1.3.20 |
