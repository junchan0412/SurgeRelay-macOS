# Surge Relay 深度调研报告

生成时间：2026-07-04

本报告基于当前工作区源码、脚本、文档与构建命令输出。当前工程是 Xcode macOS App，主 scheme 为 `Surge Relay`，目标平台 macOS 26.0。调研开始时版本元数据为 `1.3.7 (56)`，本轮优化发布目标为 `1.3.8 (57)`。维护环境需要显式使用：

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer"
```

不设置该变量时，系统会使用 `/Library/Developer/CommandLineTools`，`xcodebuild` 会直接失败。即使设置正确，当前 macOS/Xcode beta 组合会输出 CoreSimulator 版本警告，但 macOS 构建和测试可继续执行。

## 1. 项目结构现状

主要模块：

- `SurgeRelay/AppModel.swift`：应用状态、更新、扫描、发布、诊断和任务调度的核心协调者。
- `SurgeRelay/Models/RelayModule.swift`：模块模型、来源格式、存放位置、输出路径和草稿数据。
- `SurgeRelay/Services/ScriptHubClient.swift`：内置 Script-Hub 转换入口。
- `SurgeRelay/Services/ModuleFileStore.swift`：转换缓存、本地发布、管理标记和资产文件。
- `SurgeRelay/Services/GitHubClient.swift`：GitHub tree/blob/commit/ref 发布与预览。
- `SurgeRelay/Services/WebManagementServer.swift` 与 `WebManagementAPI.swift`：内置 Web 管理服务。
- `SurgeRelay/Views/ModulesView.swift`：主模块列表、详情、预览、发布预览和本地导入。
- `SurgeRelay/WebResources/app.js`：Web 管理前端主要逻辑。

文件规模热点：

| 文件 | 行数 | 风险 |
|---|---:|---|
| `AppModel.swift` | 2862 | 业务职责高度集中，更新/发布/扫描互相影响时回归风险高 |
| `SurgeRelayTests.swift` | 2768 | 测试覆盖集中，后续新增场景容易继续膨胀 |
| `ModulesView.swift` | 1898 | UI、状态卡、发布预览、本地导入和详情混合 |
| `WebResources/app.js` | 1242 | Web UI、状态 diff、编辑器、路由和 API 混合 |
| `WebManagementServer.swift` | 741 | HTTP 解析、安全校验、连接生命周期集中 |

结论：工程功能已较完整，但核心复杂度集中在少数大文件。短期优化应优先做“纯逻辑抽取”和“运行时开销削减”，避免大规模重写造成新风险。

## 2. 已实现能力评估

当前 App 已支持：

- 本地模块与 GitHub 模块双发布目标。
- 转换前来源区分本地 Surge 文件、远程 Quantumult X、远程 Loon、远程 Surge 模块。
- 本地根目录扫描已有 `.sgmodule`，识别 `#SUBSCRIBED` 并恢复原始远程来源。
- 独立模块发布、可选总模块、发布预览、旧文件删除确认。
- GitHub 发布到公开或私有仓库，私有仓库支持 Cloudflare Worker 公共地址。
- Web 管理、菜单栏入口、更新取消、钥匙串诊断、安装/Release 诊断。
- Sparkle 2 自动更新、固定自签名证书签名、`.app.zip` 与 `.pkg` 发布资产。

近期工作区还加入了：

- `storageLocation` 和 `sourceOrigin` 的明确模型关系。
- 更新失败原因格式化，例如 404、403、429、DNS、超时、HTTPS 证书错误。
- GitHub 自动发布空集合保护。
- Web 管理端同步展示模块关系与失败原因。

## 3. 性能热点

### 3.1 主窗口启动和列表搜索

`ModulesView` 当前会通过 `.task(id: contentIndexToken)` 为所有模块构建 `contentIndex`，内部调用 `model.previewContent(for:)`。这会读取组件缓存、物化参数并套用模块元数据。对于模块数量较多的用户，这属于启动后不必要的全量 I/O 和字符串处理。

建议：

- 默认只使用模块元数据搜索。
- 只有用户输入搜索词后，才懒加载模块内容搜索索引。
- 搜索词清空后释放内容索引，减少内存占用。

### 3.2 重复派生状态计算

`ModulesView`、`MenuBarContent`、`WebManagementAPI` 多处直接 `filter` 模块数组计算启用数量、独立发布数量、可更新数量。数量不大时无明显问题，但随着功能增加会造成逻辑分叉。

建议：

- AppModel 暴露少量统一派生属性，例如 `updateableModuleCount` 已经开始这样做。
- 后续可增加发布目标统计、总模块统计，减少 Web 和桌面 UI 各算各的。

### 3.3 Web 管理前端 diff

`app.js` 的 `patchLiveState` 通过拼接字段字符串判断是否重渲染列表。该方式简单但脆弱，新增字段容易漏加，字段里含分隔符也会增加误判风险。

建议：

- 抽出 `moduleListSignature(module)`，集中维护列表相关字段。
- 对大型列表，可进一步分行更新，减少整列 innerHTML 重建。

## 4. UI/UX 评估

### 4.1 主窗口结构

主窗口采用 `NavigationSplitView + List(.sidebar)`，符合 macOS sidebar-detail 模式。当前侧边栏分组已经从“来源类型”过渡到“管理状态 + 存放位置”，方向正确。

可优化点：

- 侧边栏保持轻量：一枚图标、一行标题、一行关系摘要即可；更多信息应留在详情。
- 详情页“管理关系”应作为第一组，先解释模块存放位置、转换前来源、原始地址和本地相对路径。
- 搜索结果为空时应尽量说明是“没有匹配”而不是“没有模块”。

### 4.2 模块编辑器

桌面编辑器已经加入“模块存放”选择，Web 管理端现在也需要保持同一逻辑。添加模块时，用户的核心问题是：

1. 转换前从哪里来？
2. 转换后存放到哪里？
3. 是否发布独立模块？
4. 是否进入总模块？

建议：

- 表单上把“模块存放”和“转换前来源”分区显示。
- 当模块存放为本地时，输出路径预览应保留现有文件名，不把空格重新变成连字符。
- 当总模块关闭时，继续隐藏“包含在总模块中”。

### 4.3 状态和错误

更新失败现在能显示具体原因。后续可以进一步：

- 在失败摘要旁提供“复制错误”按钮。
- 失败模块列表支持一键筛选。
- 404 类错误提示可建议用户检查分支、路径或仓库可见性。

## 5. 逻辑与安全边界

### 5.1 本地文件安全

当前本地发布使用管理标记，默认拒绝覆盖未标记同名文件；本地源文件与本地发布目标相同时会跳过自覆盖。这是核心安全边界，必须继续保持。

建议：

- 后续所有本地清理逻辑继续走 `PublishPreview` 和显式确认。
- 不要把“扫描到的原模块”和“转换后输出模块”混为一个路径概念。

### 5.2 GitHub 自动发布

当前自动发布应只在至少存在一个发布目标时执行。空集合时必须跳过，避免：

- 弹出无意义错误。
- 发布空 tree。
- 把旧发布清单误判为全部过期并删除。

### 5.3 钥匙串与签名

当前策略是固定自签名 Code Signing 证书 + Sparkle EdDSA 更新签名。没有 Developer ID 公证时，首次手动安装仍可能需要用户信任；后续 App 内更新可减少反复 `xattr`。

发布必须验证：

- App 与 Sparkle 嵌套组件使用同一固定签名身份。
- 自签名 Hardened Runtime 场景保留 `disable-library-validation` entitlement。
- `.app.zip` 和 `.pkg` 均无 quarantine、AppleDouble 和资源 fork 元数据。

## 6. 测试覆盖

已有测试覆盖较广，包括：

- 来源格式识别与 Script-Hub 转换 URL。
- 本地扫描与 `#SUBSCRIBED` 解析。
- 本地发布安全、管理标记、旧文件清理。
- GitHub 发布预览、重复路径、引用移动重试。
- Web 管理安全头、会话 cookie、同源校验、认证节流。
- Release 资产解析、安装建议、校验和。
- 更新失败格式化和发布空集合判断。

缺口：

- UI 层缺少自动截图或交互测试。
- Web 前端只有 JS 语法检查，没有 DOM 行为测试。
- 发布脚本多数依赖真实证书/钥匙串/GitHub Release，CI 覆盖依赖 secret 完整性。

## 7. 优先优化路线图

P0：本轮必须做

- 懒加载模块内容搜索索引，降低主窗口启动 I/O。
- Web 管理端补齐模块存放选择和管理关系展示。
- 统一可更新数量和自动发布空集合判断。
- 更新 README / CHANGELOG / DEVELOPMENT，明确模块关系和发布流程。
- 构建测试通过后再 bump 版本。

P1：发布前建议做

- 抽出 Web 前端列表 signature，降低字段漏同步概率。
- 抽出 AppModel 的发布准入/发布文件生成纯逻辑，减少 AppModel 继续膨胀。
- 对 GitHub 自动发布和预览入口补充更多空文件测试。

P2：后续维护

- 把 `ModulesView` 拆为 Sidebar、Detail、ImportPreview、PublishPreview 子文件。
- 把 `SurgeRelayTests.swift` 拆为模型、发布、本地文件、Web、安全、Release 测试文件。
- 为 Web 管理添加轻量 DOM 测试或 Playwright 快照验证。
- 评估 App Sandbox 与 security-scoped bookmark 的迁移成本。

## 8. 发布前核对清单

1. `git diff --check`
2. `node --check SurgeRelay/WebResources/app.js`
3. `DEVELOPER_DIR=... xcodebuild test -project "Surge Relay.xcodeproj" -scheme "Surge Relay" -destination "platform=macOS"`
4. 版本号和构建号同时更新 `project.yml` 与 `Surge Relay.xcodeproj/project.pbxproj`
5. README、CHANGELOG、DEVELOPMENT 与实际行为一致
6. `REQUIRE_SPARKLE_SIGNATURES=1 REQUIRE_STABLE_CODESIGN=1 VERIFY_APPCAST=1 UPDATE_APPCAST=1 ./script/build_release_assets.sh`
7. GitHub Release 包含 `.app.zip`、`.pkg`、sha256 和 Sparkle metadata
8. 远端 Release 资产验证通过
