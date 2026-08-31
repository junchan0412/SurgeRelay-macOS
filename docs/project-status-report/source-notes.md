# Surge Relay 项目现状审计来源说明

生成时间：2026-08-30 20:54:01 +08:00

## 审计目标

本报告整合仓库中已有的用户说明、开发状态、发布记录、安全说明、上游同步记录与部署指南，并以当前代码、Git refs、构建和测试证据校正旧报告中的过时结论。报告同时记录按照首次审计建议顺序完成的优化结果。

主要读者为项目维护者与参与协作的 coding agent。报告用于回答：当前项目是否具备继续开发和常规发布验证的条件，哪些问题已经完成，哪些限制仍需后续环境或发布流程解决。

## 基线

- 仓库：`/Users/qidewei/Documents/Surge Relay`
- 分支：`main`
- HEAD：`4b591fc56d7d2989767912a38c337f257bb24a31`
- 标签：`v1.4.0`
- 当前版本：`1.4.0 (95)`
- macOS deployment target：`26.0`
- Swift：`6.0`，strict concurrency 为 complete
- 主要外部依赖：Sparkle `2.9.3`
- 本地 upstream/main：`a3e667c0ca72b681167445ee8d280e0e43d473c9`
- 相对本地 upstream/main：behind 51 / ahead 256
- 本报告反映 HEAD 加本轮未提交优化工作区；没有回滚或覆盖工作区中既有修改。

## 主要来源文件

| 来源 | 用途 | 当前判断 |
| --- | --- | --- |
| `README.md` | 用户能力、安装、安全、开发入口 | 已同步本地/GitHub 发布行为、参数化 release 示例和兼容性策略 |
| `DEVELOPMENT.md` | 架构边界、测试归属、构建发布流程 | 已同步参数化 preflight 与独立 UI test scheme |
| `DEVELOPMENT_STATUS.md` | 当前版本、规模、热点和维护决策 | 已改为 `script/generate_project_status.mjs` 自动生成 |
| `CHANGELOG.md` | 版本事实与发布历史 | 与 1.4.0 (95) release metadata 一致 |
| `SECURITY.md` | 当前安全边界 | 已明确兼容性优先策略暂无迁移时间表 |
| `docs/RELEASE_HARDENING.md` | 签名、公证、ATS、Sandbox 取舍 | 已记录迁移前置条件与当前无时间表 |
| `docs/UPSTREAM_SYNC.md` | 选择性上游同步边界 | 已刷新本地 refs 与 behind/ahead 快照 |
| `docs/GitHub-Cloudflare-Guide.md` | 发布与 Cloudflare 配置流程 | 已同步当前发布/凭据字段并明确公开仓库受支持 |
| `Deployment/CloudflareWorker/README.md` | Worker 部署说明 | 已使用中性 owner/repository 占位符 |
| `Deployment/CloudflareWorker/wrangler.jsonc` | Worker 默认配置 | 已移除绑定特定 upstream fork 的默认值 |
| `project.yml` / `project.pbxproj` | target、scheme、版本与 build 配置 | 已加入独立 `SurgeRelayUITests` target 与 UI scheme |
| `SurgeRelayUITests/SurgeRelayUITests.swift` | UI 自动化 flows | 覆盖设置、模块编辑器、详情页和 Web DOM 搜索 |

## 已完成优化

### P0：恢复测试确定性

首次审计中 273 个常规 Xcode 测试有 4 个失败。失败都发生在 `public.example` 被 Surge Enhanced Mode 合成为 `198.18.5.229` 后，SSRF 防护在进入 URLProtocol mock 前按设计阻断请求。

本轮将相应用例改为 `https://8.8.8.8/...` 数字地址夹具，避免系统 DNS、Fake-IP、VPN 或企业网络影响 mock 路径。修复后的完整 xcresult 记录 273 通过、0 失败、0 跳过。

### P0：建立自动当前状态入口

- 新增 `script/generate_project_status.mjs`。
- `DEVELOPMENT_STATUS.md` 由 project.yml、Git refs、源码规模、热点与维护策略生成，不再人工维护。
- `script/check_release_configuration.sh` 增加状态页新鲜度检查。
- `node script/generate_project_status.mjs --check` 用于证明工作区状态页未漂移。

### P1：同步维护文档

- “发布所选”统一为支持本地与 GitHub storage location。
- Release 命令示例统一使用 `X.Y.Z` / `N`。
- Cloudflare 指南使用当前“发布 / 凭据”字段，不再描述旧的单一同步流程。
- 公开仓库明确受支持；Worker 示例不再默认绑定特定 owner/repository。
- UPSTREAM_SYNC 使用当前本地 tracking refs，不将未 fetch 的状态写成远端实时事实。

### P1：补齐 UI 自动化基础

- 新增 `SurgeRelayUITests` target 和 `Surge Relay UI Tests` 独立 scheme。
- 独立 scheme 避免 macOS UI automation 权限问题影响常规单元测试。
- 设置、编辑器、详情页和 Web 管理相关控件增加 accessibility identifiers。
- Web DOM test 增加搜索交互断言。
- UI scheme `build-for-testing` 成功，且无编译警告。
- 实际 UI test run 在测试代码执行前失败，错误为 `Timed out while enabling automation mode`；这是系统 automation 初始化限制，不是 assertion 失败。

### P2：缩小真实热点

- 新增 `SurgeRelay/Views/ModuleSidebarFilterBar.swift`。
- `ModuleSidebarView.swift` 从 655 行降至 485 行。
- 筛选、结果数、清除和排序 UI 被抽取；状态归属、批量选择与列表交互逻辑保持不变。

### P2：固定兼容性优先策略

- 当前没有 Apple Developer ID、notarization、ATS 收紧或 App Sandbox 迁移时间表。
- 继续固定自签名证书 + Sparkle EdDSA。
- 继续 `NSAllowsArbitraryLoads=true` 和 App Sandbox disabled。
- 迁移前必须先具备用户来源例外模型、security-scoped bookmarks、旧安装迁移和回归测试。

## 当前规模快照

- 应用 Swift 文件：126
- Unit/UI Swift 测试文件：38 / 1
- 常规 Xcode 实际执行测试：273
- 常规测试结果：273 通过 / 0 失败 / 0 跳过
- Services / Models / Views / Utilities / App-Core：55 / 19 / 28 / 3 / 21
- 应用与 unit/UI 测试 Swift 行数：28,095（按生成器的文本行口径）
- Web JS 与 Web 测试行数：3,785
- CHANGELOG release 段落：95
- Git commits：263

当前前三个应用源码热点：

1. `SurgeRelay/Views/ModuleCodeTextView.swift`：560 行
2. `SurgeRelay/Utilities/ModuleMetadataParser.swift`：495 行
3. `SurgeRelay/Views/ModuleSidebarView.swift`：485 行

## 自动化验证证据

以下项目已在本轮执行并通过：

- `git diff --check`
- `node script/generate_project_status.mjs`
- `node script/generate_project_status.mjs --check`
- `node script/test_web_resources.mjs`
- `node script/test_web_dom_resources.mjs`
- `VERSION=1.4.0 BUILD=95 ./script/check_release_configuration.sh`
- Xcode 27 beta Debug build
- `Surge Relay UI Tests` scheme `build-for-testing`
- `Surge Relay` scheme 完整常规测试：273 / 273 通过

Xcode 使用：

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer"
```

常规测试结果 bundle：

`/Users/qidewei/Library/Developer/Xcode/DerivedData/Surge_Relay-bqpcmgqrqhmkotdidveliklethnd/Logs/Test/Test-Surge Relay-2026.08.30_20-51-16-+0800.xcresult`

`xcresulttool get test-results summary` 返回：`result=Passed`、`totalTestCount=273`、`passedTests=273`、`failedTests=0`。

## UI automation 限制

独立 UI scheme 的 build-for-testing 成功，证明 target、scheme、宿主应用和测试源码配置有效。实际 `xcodebuild test` 在进入任何测试方法前无法启用系统 automation mode，最终超时。

因此报告区分以下状态：

- UI 测试可构建：通过。
- UI 测试实际 assertions：未执行。
- 当前阻断：macOS/Xcode UI automation runner 初始化。

要完成闭环，需要在允许 Xcode UI automation 的交互式 macOS 桌面会话或合适 CI runner 上重新执行该独立 scheme。

## 图表说明

报告保留一个比较型 bar chart：应用 Swift 文件按层分布。它回答“维护规模主要集中在哪些代码层”，使用 126 个应用 Swift 文件的目录归类；Services 55、Views 28、App/Core 21、Models 19、Utilities 3。类别标签较短、行数充足，bar chart 比表格更便于比较，精确值仍保存在 snapshot dataset 和 semantic fallback 中。

未新增测试趋势图，因为这里只有修复前/后的两个离散验证状态；表格和技术叙述比两点趋势更诚实。验证项目、文档状态、热点与行动顺序继续使用审计表格，便于精确查阅。

## 报告结构映射

采用 technical audience：

- Title：项目现状综合报告
- Technical summary：当前 release、全绿常规验证、已完成优化与 UI runner 限制
- Key findings with visual evidence：验证、文档、架构热点、安全策略
- Scope, data, and metric definitions：审计范围与定义
- Methodology：审计与优化方法
- Limitations and robustness：UI automation、release assets、local refs、代码规模口径
- Recommended next steps：UI 实跑、热点维护、release asset 核验、兼容性策略
- Further questions：剩余环境与发布闭环问题

## 未覆盖范围

- 未导入正式自签名证书或 Sparkle EdDSA 私钥。
- 未构建并检查正式 pkg/app.zip。
- 未核验 GitHub Release 线上资产。
- 未完成 UI assertions、VoiceOver、窄窗口和真实大规模模块数据的人工验收。
- 未执行 upstream fetch；behind/ahead 仅表示当前本地 remote-tracking refs。

## Portable HTML QA

- Canonical artifact JSON syntax：通过。
- Portable artifact validation：通过。
- Portable HTML packaging：通过。
- Structural verification：通过。
- Browser verification：`structural_only`。当前环境没有已安装的 Chromium headless-shell，portable builder 未执行 desktop/narrow viewport、source dialog 和交互检查；semantic fallback 已保留。
