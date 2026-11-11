# Surge Relay Project Status

> 本文件由 node script/generate_project_status.mjs 自动生成。不要手工编辑；修改代码、版本或维护策略后重新运行生成器。

## 当前基线

| 项目 | 当前值 |
| --- | --- |
| 版本 | 3.1.0 (117) |
| macOS deployment target | 15.0 |
| Swift | 6.0，strict concurrency complete |

## 当前维护决策

- **当前入口分工明确。** DEVELOPMENT_STATUS.md 提供自动生成的版本、规模和验证入口；docs/CURRENT_PROJECT_REPORT.md 提供现状判断、清理记录和后续计划；历史报告和原始采集只在 docs/archive/ 中追溯。
- **继续采用兼容性优先策略。** 当前没有 Apple Developer ID、notarization、ATS 收紧或 App Sandbox 迁移时间表。
- **保持现有分发模型。** Release 继续使用固定自签名证书与 Sparkle 2 EdDSA；首次安装仍可能受 Gatekeeper quarantine 影响。
- **保持现有权限模型。** NSAllowsArbitraryLoads=true 与 App Sandbox disabled 继续服务于用户自定义 HTTP/HTTPS 来源和用户选择目录写入。
- **迁移只在兼容方案具备后启动。** 未来变更必须先完成用户来源例外模型、security-scoped bookmarks、旧配置迁移和回归测试，不以日历日期强推。

## 当前能力

- 集中管理远程、本地与 Script-Hub 转换模块，并区分 storageTargets 与 initialSource（storageLocation 保留旧单目标兼容）。
- 来源、输出客户端与存放目标独立：支持 Surge、Loon、Egern、Quantumult X、Stash、Shadowrocket 输出，同一来源可维护不同客户端版本。
- 六客户端分别启用并设置本地目录，新配置仅Surge开启；目录菜单、扫描、同步与发布清单按客户端隔离，共享根目录互相保护当前输出。
- 工作区可迁移配置与缓存，保持身份、凭据、草稿、历史和工具表单；失败回滚目标，重启使用新登记，旧writer退出后不重建原路径。
- 原生/Web转换工具支持规则集、域名集、剩余规则与独立脚本，输入可为文本、远程地址或本地文件，结果可复制、保存/下载。
- 本地与 GitHub 发布可并存；每个模块独立选择本地、GitHub 或双目标，更新或编辑仅刷新自身输出；所选发布记录逐目标结果并支持只重试未完成目标。
- 支持本地模块扫描、转换预览、文本覆盖、冲突处理、发布预览、受管文件清理和自动发布。
- 监听本地模块目录，源文件在 App 外改动后按来源内容 sha256 只重新转换改动过的模块。
- 模块内容编辑器支持撤销/重做、查找与替换（含正则）、跳转到行、切换注释和缩进操作。
- 原生查找和批量替换在可取消后台任务中计算，长文档行号按可见区域绘制；大文件自动使用纯文本和逻辑行尺寸，小文件语法范围后台计算；全部替换不受 5,000 条高亮上限影响。
- 提供 macOS 与 Web 工作台、活动记录、按需展开的模块详情、菜单栏与分类设置。
- 活动记录支持模块、提交和发布文件检索；Web 列表复用未变化行并保留键盘焦点，内容页支持保存重试与写入期间的草稿保护。
- 使用最多 4 个模块的有界并发更新、完整缓存快照、可取消网络请求和流式资源指纹。
- 缓存/历史/恢复事务携带输出格式，保持 YAML 和 QX 原始文本；切换目标先生成新缓存，旧手动覆盖归档保留。
- 两端内容页持久保留未保存草稿并核验恢复基线；Web 保存使用 ETag 条件写入，支持退避重连、隐藏页暂停和过期响应隔离。
- 原生模块配置保存提供持久队列、按序执行、重启恢复和重试/取消；失败提交撤回，历史备份恢复项需核对后重试。Web 活动页展示队列并提供重试/取消，忙碌时的模块修改保留草稿并返回冲突。
- Web 服务可自主开启/关闭；关闭释放监听与连接，开启时使用有界连接、请求期限与共享状态编码缓存。
- 双目标同步提供共同基线、单边领先分类、行级差异和覆盖前版本核验。
- Script-Hub 在独立 helper 进程内执行，最多 4 路，支持总执行时限和强制取消；helper 随应用分发。
- 凭据使用配置目录内 AES-256-GCM 加密文件，不依赖系统钥匙串。
- Release preflight 覆盖版本、Sparkle、appcast、entitlements、Web 资源、workflow 和 Xcode 工程源文件登记。
- PR 与 main push 执行隔离的 Swift/Web 回归，保存 xcresult、日志及执行/跳过摘要。
- PR 回归执行固定 Script-Hub 模块矩阵与规则/脚本工具矩阵，检查实际产物和标准HTTP脚本API语义。

## 代码与测试规模

| 指标 | 数量 |
| --- | --- |
| 应用 Swift 文件 | 172 |
| Swift 测试文件（unit / UI） | 54 / 1 |
| 源码中的 XCTest 方法 | 674 |
| Services / Models / Views / Utilities / App-Core | 73 / 27 / 39 / 3 / 30 |
| 应用 Swift 行数 | 31,094 |
| 测试 Swift 行数 | 17,373 |
| CHANGELOG release 段落 | 117 |

## 主要维护热点

文件行数只用于导航维护成本，不等同于缺陷或质量评分。

| 文件 | 行数 |
| --- | --- |
| SurgeRelay/Services/ModuleFileStore.swift | 1348 |
| SurgeRelay/Views/ModuleCodeTextView.swift | 858 |
| SurgeRelay/Views/ModuleDetailView.swift | 702 |
| SurgeRelay/Utilities/ModuleMetadataParser.swift | 689 |
| SurgeRelay/Views/ModulePreviewViews.swift | 587 |
| SurgeRelay/Services/PersistenceStore.swift | 524 |
| SurgeRelay/AppModel+Modules.swift | 495 |
| SurgeRelay/Models/RelayModule.swift | 486 |
| SurgeRelay/Views/NativeQAPerformanceRecorder.swift | 482 |
| SurgeRelay/Views/ModuleCodeEditorController.swift | 472 |

## 当前优化顺序

1. 补齐 macOS 15 的实际运行验收；目标构建与新版系统上的单元测试不能替代旧系统运行结果。
2. 优先验证移动清理、参数模板和保存队列的端到端流程及故障恢复，保持根目录、文件身份和外部修改保护。
3. 将 Swift and Web regression 配置为分支保护的必需检查；独立原生 UI scheme 在具备桌面权限的环境执行。
4. 根据实测瓶颈逐项优化文件 I/O、元数据解析和编辑器热点；保留网络 mock 的确定性，不凭文件大小实施整库重写。
5. 保持文档导航、当前报告、自动状态页与验证摘要一致；旧报告和原始采集只能进入 archive。
6. 继续兼容性优先的 release hardening；没有前置兼容设计时不启用 Sandbox 或收紧 ATS。详细验收标准见 docs/CURRENT_PROJECT_REPORT.md。

## 验证入口

在发布或合并广泛变更前运行：

~~~bash
git diff --check
node script/generate_project_status.mjs --check
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
VERSION=3.1.0 BUILD=117 ./script/check_release_configuration.sh

./script/run_swift_qa.sh

# 需要允许 Xcode UI automation 的 macOS 桌面会话
DEVELOPER_DIR="$(xcode-select -p)" \
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
| docs/CURRENT_PROJECT_REPORT.md | 当前项目报告、清理记录和未来计划 |
| docs/README.md | 文档导航 |
| SECURITY.md | 当前安全边界 |
| docs/RELEASE_HARDENING.md | 兼容性优先的分发策略 |
| docs/UPSTREAM_SYNC.md | 选择性同步边界与 Git refs 快照 |
| docs/archive/legacy-audits-2026-10/project-status-report/report.html | 历史综合审计快照（1.4.7） |
