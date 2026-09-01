# Surge Relay Project Status

> 本文件由 node script/generate_project_status.mjs 自动生成。不要手工编辑；修改代码、版本或维护策略后重新运行生成器。

## 当前基线

| 项目 | 当前值 |
| --- | --- |
| 版本 | 1.4.4 (99) |
| macOS deployment target | 26.0 |
| Swift | 6.0，strict concurrency complete |

## 当前维护决策

- **本文件是唯一当前状态入口。** 旧的人工维护完成项、目标、待办和固定版本 release checklist 已由自动生成报告取代。详细审计快照位于 docs/project-status-report/report.html。
- **继续采用兼容性优先策略。** 当前没有 Apple Developer ID、notarization、ATS 收紧或 App Sandbox 迁移时间表。
- **保持现有分发模型。** Release 继续使用固定自签名证书与 Sparkle 2 EdDSA；首次安装仍可能受 Gatekeeper quarantine 影响。
- **保持现有权限模型。** NSAllowsArbitraryLoads=true 与 App Sandbox disabled 继续服务于用户自定义 HTTP/HTTPS 来源和用户选择目录写入。
- **迁移只在兼容方案具备后启动。** 未来变更必须先完成用户来源例外模型、security-scoped bookmarks、旧配置迁移和回归测试，不以日历日期强推。

## 当前能力

- 集中管理远程、本地与 Script-Hub 转换模块，并区分 storageLocation 与 initialSource。
- 本地与 GitHub 发布可并存；独立模块按自身存放位置发布，总模块可同时发布到两个目标。
- 支持本地模块扫描、转换预览、文本覆盖、冲突处理、发布预览、受管文件清理和自动发布。
- 提供 macOS 主界面、菜单栏和带访问控制的 Web 管理端。
- 凭据使用配置目录内 AES-256-GCM 加密文件，不依赖系统钥匙串。
- Release preflight 覆盖版本、Sparkle、appcast、entitlements、Web 资源、workflow 和 Xcode 工程源文件登记。

## 代码与测试规模

| 指标 | 数量 |
| --- | --- |
| 应用 Swift 文件 | 126 |
| Swift 测试文件（unit / UI） | 38 / 1 |
| 源码中的 XCTest 方法 | 280 |
| Services / Models / Views / Utilities / App-Core | 55 / 19 / 28 / 3 / 21 |
| 应用 Swift 行数 | 20,427 |
| 测试 Swift 行数 | 7,730 |
| CHANGELOG release 段落 | 99 |

## 主要维护热点

文件行数只用于导航维护成本，不等同于缺陷或质量评分。

| 文件 | 行数 |
| --- | --- |
| SurgeRelay/Views/ModuleCodeTextView.swift | 560 |
| SurgeRelay/Utilities/ModuleMetadataParser.swift | 496 |
| SurgeRelay/Views/ModuleSidebarView.swift | 486 |
| SurgeRelay/Views/ModulePreviewViews.swift | 417 |
| SurgeRelay/Services/EmbeddedScriptHubEngine.swift | 376 |
| SurgeRelay/Services/ModuleFileStore.swift | 374 |
| SurgeRelay/Views/ModuleDetailView.swift | 360 |
| SurgeRelay/Models/RelayModule.swift | 357 |
| SurgeRelay/Services/PersistenceStore.swift | 336 |
| SurgeRelay/Views/LocalModuleImportPreviewView.swift | 333 |

## 当前优化顺序

1. 保持 BoundedRemoteDataFetcher 与 Web source-name 测试不依赖系统 DNS、Fake-IP、VPN 或企业网络环境。
2. 保持本自动状态页与 project.yml、代码规模和维护策略同步；Git refs 快照单独维护在 UPSTREAM_SYNC。
3. 保持 README、DEVELOPMENT、UPSTREAM_SYNC 与 Cloudflare 指南描述当前发布模型。
4. 保持设置、模块编辑、详情页和 Web 管理的自动化 UI/交互覆盖稳定。
5. 侧边栏筛选 UI 已独立成文件；按实际变更频率继续缩小其他高负荷 Swift 与 Web 文件，避免全局重写。
6. 继续兼容性优先的 release hardening；没有前置兼容设计时不启用 Sandbox 或收紧 ATS。

## 验证入口

在发布或合并广泛变更前运行：

~~~bash
git diff --check
node script/generate_project_status.mjs --check
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
VERSION=1.4.4 BUILD=99 ./script/check_release_configuration.sh

DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
xcodebuild test \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation

# 需要允许 Xcode UI automation 的 macOS 桌面会话
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
xcodebuild test \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay UI Tests" \
  -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation
~~~

正式 release asset 构建仍需要固定自签名证书和 Sparkle EdDSA 私钥。

## 文档与事实来源

| 来源 | 职责 |
| --- | --- |
| README.md | 用户能力、安装、安全与开发入口 |
| DEVELOPMENT.md | 架构边界、测试归属和维护约束 |
| CHANGELOG.md | 版本事实与发布历史 |
| SECURITY.md | 当前安全边界 |
| docs/RELEASE_HARDENING.md | 兼容性优先的分发策略 |
| docs/UPSTREAM_SYNC.md | 选择性同步边界与 Git refs 快照 |
| docs/project-status-report/report.html | 详细综合审计快照 |
