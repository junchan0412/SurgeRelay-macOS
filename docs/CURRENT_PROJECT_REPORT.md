# Surge Relay 当前项目报告

检查与更新时间：2026-11-12（Asia/Shanghai）

本报告依据当前代码、工程配置、Git 记录和本地检查描述项目状态。发布基线为 `v3.1.0`（build 117），包含完整工作区迁移、客户端独立存储目录、多客户端工作台和转换工具。版本与规模由 [自动状态页](../DEVELOPMENT_STATUS.md) 提供，历史材料经 [文档导航](README.md) 进入归档。

## 当前状态

- `project.yml`、已登记的 Xcode 工程、最新 appcast 条目和本地 tag 一致：**3.1.0（build 117）**，主应用、helper 和两个测试目标均为 **macOS 15.0**。
- 当前架构是 SwiftUI + AppKit 原生工作台、内置 Script-Hub helper、Web 管理台和本地/GitHub 双目标发布，提供模块、规则集与独立脚本三个转换入口。
- 模块输入支持 Surge、Loon、Quantumult X，输出支持 Surge、Loon、Egern、Quantumult X、Stash 和 Shadowrocket。每个模块独立拥有来源、输出客户端、参数、缓存、历史、输出路径和存放目标，同一来源可按客户端维护多个版本。
- 转换工具接受粘贴文本、远程地址或本地文件，按客户端生成规则 `.list` 或脚本 `.js`，支持复制、保存/下载、取消与工作区草稿隔离。
- 本地输出具备受管标记、路径和 hash 校验、旧路径迁移、手动接管、外部修改保护和 iCloud 资源事务恢复。
- 编辑器支持参数模块、版本历史、持久草稿和差异比较。原生模块配置保存使用持久队列，支持按序执行、重启恢复和重试/取消；失败提交撤回，从历史备份恢复的请求需核对后重试。Web 活动页显示同一队列并提供重试/取消，忙碌时的模块创建/修改保留草稿并返回冲突。
- 更新流水线与 Script-Hub helper 最多 4 路并发；Web 已实现 activity 分流、后台快照构造、条件写入和生命周期保护。
- 发布继续使用固定自签名证书与 Sparkle 2 EdDSA；凭据使用配置目录内 AES-256-GCM 加密文件。网络与文件访问边界见 [SECURITY.md](../SECURITY.md) 和 [发布策略](RELEASE_HARDENING.md)。
- PR 与 `main` push 已配置 Swift/Web 回归 workflow，复用 release preflight、自动状态页和隔离 fixture；单元回归使用临时 QA 配置、Release 和 ad-hoc 签名，保存 xcresult、日志及执行/跳过摘要。
- 每客户端独立设置本地目录和启用状态，新配置只开启 Surge；发布、扫描、同步、清理、恢复和目录菜单使用对应客户端根目录。
- 工作区可整体迁移配置与缓存，保存身份、凭据、草稿、历史、队列和当前工具表单；成功登记后载入新位置，失败保留原数据。

源码中的 XCTest 方法数是静态规模指标，不等于本次通过的测试数。当前主要成本集中在文件事务、长文本编辑、模块详情与元数据解析，应按真实问题选择优化对象。

## 3.1.0 工作区与存储

| 能力 | 完成结果 |
| --- | --- |
| 迁移工作区 | 活动及非活动工作区可迁至选定位置的 `Configuration`、`Cache`；活动任务取消、等待和落盘后迁移，登记失败回滚目标数据 |
| 重启定位 | 配置与缓存路径一起登记；默认工作区同步两项选择，旧组件缓存进入新缓存，退休旧持久 writer 防止视图退出后重建原位置 |
| 独立客户端目录 | 六客户端各自启用、选目录及维护清单；新配置仅Surge启用，旧显式发布开关保留，旧混合清单按模块/资源归属拆分 |
| 共享目录 | 发布预览携带客户端身份，清理保护其它客户端当前输出与资源，目录变更不转移旧覆盖权限 |
| 界面 | 工作区页面提供迁移按钮及两项路径；原生/Web展示客户端目录，编辑器文件夹和工具保存位置跟随所选客户端 |

当原配置目录与缓存目录重叠或旧缓存包含登记/其它工作区时，迁移仍完成，旧缓存中的用户文件留在原处并显示清理提示。各客户端发布目录保持原设置，不随工作区数据迁移改变。

## 多客户端与转换工具

| 能力 | 完成结果 |
| --- | --- |
| 输出客户端 | Surge/Egern/Shadowrocket `.sgmodule`、Loon `.plugin`、QX `.conf`、Stash `.stoverride`；来源、输出客户端与本地/GitHub 存放分别建模 |
| QX 输出 | 本地转换规范重写、规则、脚本、MITM、Header/Body 与 Map Local；生成实际脚本资源，不支持项返回明确错误 |
| 自动来源 | 无明确扩展时读取实际文本识别；无法唯一识别的内容使用上游 `all-module`，保持来源未定状态 |
| 缓存与历史 | `OutputFormat.json` 与正文/资源原子提交，历史和恢复事务保留输出类型；目标变化后禁止旧缓存冒充新格式，旧覆盖先归档，新输出提交成功后移出当前缓存 |
| 本地文件 | 扫描 `.sgmodule/.module`、`.plugin/.lpx`、`.conf` 和带订阅来源的 `.stoverride`，按当前磁盘字节登记，保留合法文件名 |
| 规则工具 | 自动读取 QX/Surge/Loon/Clash payload/域名/CIDR，包含裸 IPv6 规范化；六目标输出 `.list`，QX补策略，Stash生成 YAML payload；Surge/Egern/Stash支持域名与剩余规则 |
| 脚本工具 | QX原生保留、QX转共同API兼容脚本、通用脚本转QX；标准 HTTP 方法和 status/statusCode 保留，HTTP错误响应不能作为脚本输出 |
| 界面与自动回归 | 原生/Web可转换、复制、保存结果；输入代际、工作区、运行时与取消请求隔离；CI执行真实pin模块矩阵和工具矩阵并保留产物 |

3.0.0（116）提供多客户端能力和三个转换入口。当前 Script-Hub pin 为 `6b4fb62240629d2fc66b08bc271f8c1f83a5dcd1`。

## 本轮 P1 优化

| 方向 | 完成结果 |
| --- | --- |
| 回归自动化 | `.github/workflows/qa.yml` 在 PR 与 `main` push 执行 `Swift and Web regression`；`script/run_swift_qa.sh` 提供相同本地入口，结果保留为 14 天 CI artifact |
| 保存提交 | 写盘失败撤回此次请求，同时替换 writer 的重试快照；已有已接受请求继续保留 |
| 队列恢复 | 当前有效队列继续自动执行；历史备份恢复项持久标记为需核对后重试或取消，避免已完成/已取消编辑自动重放 |
| Web 状态 | 活动页按提交顺序显示等待、正在保存和失败状态；队列通过 activity 分流更新，重试/取消按当前工作区执行，正在执行项禁止取消 |
| 忙碌与草稿 | Web 编辑器显示忙碌提示；409/412 保留表单，任务完成清除忙碌提示；旧工作区响应保持隔离 |

## 2026-11-01 目录清理

| 位置 | 整理结果 |
| --- | --- |
| 根目录 | 保留用户指南、开发约束、自动状态页、CHANGELOG、安全与许可证文档，各自职责明确 |
| `docs/` | 当前报告、文档导航、发布安全、上游同步和 Cloudflare 指南 |
| `docs/performance/` | 保留 9 份历史测量摘要与复现说明，新增 [基线导航](performance/README.md)，统一标注测量范围和历史性质 |
| `docs/archive/legacy-audits-2026-10/` | 7 个早期审计、实施清单、旧优化计划和 1.4.7 状态页面文件 |
| `docs/archive/performance-raw-2026-10/` | 67 个原始 JSON/JSONL/日志、采样与 Script-Hub 夹具文件 |

共接续归档 **74 个既有文件**，约 **12.5 MiB**。这些材料保留用于追溯，移动归档不计作磁盘空间回收。与 `HEAD` 逐文件核对后，原始数据和转换产物字节保持一致；变化仅限 3 份 Markdown 的相对链接和归档运行脚本的仓库定位。

归档的 `script-hub-production-2026-10-03/run.sh` 保留此前移除个人硬编码路径的修复，并按新目录层级定位仓库；`.gitattributes` 同步匹配新路径，继续保留转换产物的原始结尾字节。历史绝对源码路径和当时的待办保留为追溯记录，说明见 [归档导航](archive/README.md)。

目录整理时可再生的 `build/`、`dist/`、`DerivedData/`、`.build/` 和 `node_modules/` 目录已不存在，未统计其删除或回收量。3 个 `.DS_Store`（共 22,540 字节）可逆移入 `~/.Trash/SurgeRelay-cleanup-2026-11-01/01a196a0/`，保留原相对路径。该次整理保持应用源码、用户配置与生产模块原有内容。

## 验证记录与范围

| 时间与来源 | 结果 | 能证明的范围 |
| --- | --- | --- |
| 2026-10-25 的 2.5.0 发布记录，[CHANGELOG](../CHANGELOG.md) | 592 项 Release 测试通过、2 项可选测试跳过；macOS 15 目标 Debug 构建通过 | 历史构建/回归记录；运行宿主为 macOS 27.2 |
| 2026-11-11 `./script/run_swift_qa.sh build/qa-local/swift-validated-20261111` | 596 项 Release 测试通过、2 项可选性能测试跳过；App/helper 与测试目标构建通过 | 隔离 QA 配置、Swift 6 完整并发检查、保存队列撤回/备份恢复、Web 队列接口与既有文件/参数回归；日志、xcresult 和摘要在指定结果目录 |
| 2026-11-11 `./script/run_swift_qa.sh build/qa-tools/final` | 650 项 Release 测试通过、2 项可选性能测试跳过 | 多客户端模型/模板/路径、工具API、取消与保存队列联动、缓存/历史类型恢复、源文本识别、脚本资源与HTTP状态语义；App/helper构建通过 |
| 2026-11-12 `./script/run_swift_qa.sh build/qa-storage/final` | 668 项 Release 测试通过、2 项可选性能测试跳过 | 工作区成功/失败/重启/旧writer/legacy/自重叠迁移及UI状态保留；独立目录、共享根清理、manifest、扫描和Web客户端映射 |
| 本次隔离原生UI验收 | 工作区迁移和独立Loon目录保存通过 | 实际按钮完成迁移，登记的配置/缓存路径生效；Surge目录不受Loon目录改变影响，新配置其它五客户端关闭 |
| 本次 `script/test_script_hub_matrix.py` | 24 项实际pin模块转换通过 | 三种显式来源和共享规则自动来源 × 六客户端；检查拒绝、重定向、脚本引用、MITM和适用规则，产物在 `build/qa-multiclient/automatic-matrix` |
| 本次 `script/test_script_hub_tools.py` | 38 项实际pin工具转换通过 | 四种规则来源 × 六客户端、QX/common脚本、反向QX适配和HTTP错误响应；严格原生API替身检查HTTP方法、状态码、存储、通知和完成回调，产物在 `build/qa-tools/verified-matrix` |
| 本次 `VERSION=3.1.0 BUILD=117 ./script/check_release_configuration.sh` | 通过 | 版本、部署目标、Sparkle/appcast、entitlements、Web 资源、发布脚本、workflow 和 Swift 工程登记 |
| preflight 内的 Web 检查 | 19 个分拆脚本、aggregate 和 DOM harness 通过 | 客户端选择、工具参数/输出/取消、工作区/输入代际和既有 Web 行为；19 是脚本数 |
| 本次 `python3 -B script/test_native_qa_fixture.py` | 2 个测试通过 | 隔离原生 QA fixture 的生成与清理行为 |
| 2026-11-01 目录整理检查 | 语法、自动状态一致性、diff whitespace、120 个相对链接与 74 文件归档完整性通过 | 历史目录整理记录；历史绝对路径另作说明 |
| 2026-11-12 3.0.0 发布资产 | arm64/x86_64 通用 App、zip/pkg payload、固定证书、Sparkle签名及appcast验证通过 | 构建目标macOS 15.0；zip/pkg均使用独立QA配置启动，未执行真实安装 |
| 本次3.1.0发布资产 | arm64/x86_64通用App、固定证书、zip/pkg隔离启动与appcast验证通过 | 两架构及helper部署目标macOS 15.0；实际OS宿主为macOS 27.3 |

可选跳过项为原生编辑器组件矩阵和 5,000 模块 Web 服务负载基准，需分别设置对应采集环境变量。常规回归不执行性能采集。

本次维护机为 macOS 27.3（26C5035r），Xcode 27.2（27B52）。验证使用隔离 QA 工作区和 macOS 15 部署目标；正式通用发布资产已构建并通过zip/pkg隔离启动检查；原生设置控件已在隔离QA工作区完成迁移与目录保存交互；真实浏览器性能采样和客户端导入运行不属于本次发布验证。macOS 15 实机/虚拟机运行验收仍无记录。

## 当前风险与限制

1. **最低系统运行证据不足。** macOS 15 目标构建和新系统上的回归已记录，但还缺旧系统实际运行结果。
2. **远端合并门禁待启用。** QA workflow 已完成本地配置和验证，尚无 GitHub Actions 执行记录；需将 `Swift and Web regression` 设置为分支保护的必需检查。手动发布 workflow 仍单独执行，原生 UI runner 依赖桌面会话权限。
3. **Web 尚未提交到保存队列。** Web 已展示和管理原生待保存请求，但忙碌时创建/修改模块仍返回 409 并保留草稿。
4. **文件和编辑器边界复杂。** `ModuleFileStore.swift`、`ModuleCodeTextView.swift`、`ModuleDetailView.swift` 与 `ModuleMetadataParser.swift` 是维护热点；行数只是成本线索，已有事务、路径/hash/身份保护不能在整理中丢失。
5. **分发方案存在明确限制。** 自签名、全局 ATS 放宽与 App Sandbox 关闭仍是兼容性优先的当前决策，Developer ID/notarization 迁移没有排期。
6. **证据有适用范围。** 确定性网络 mock 和隔离 fixture 不能覆盖全部真实来源、iCloud 竞争和 GitHub 远端场景。性能摘要对应 2026-10-02～04 的构建；上游 behind/ahead 仍是 2026-08-30 本地 refs 快照，本次未 fetch。
7. **客户端兼容边界。** Egern使用Script-Hub现有的Surge兼容模块；无来源的原始Stash覆写尚不能作为模块输入。QX跨格式模块脚本需要公共托管，不支持项会阻止输出；各客户端实际导入运行仍需设备验收。

## 后续计划与优化方向

按依赖和风险安排以下阶段，不在缺少设备或测量证据时承诺日历日期。

| 优先级与阶段 | 下一步 | 完成标准 |
| --- | --- | --- |
| P0 · 下一次发布验收 | 准备 macOS 15 实机或虚拟机，验证 App/helper、Sparkle 更新、目录选择、本地/iCloud 输出与参数模块 | 保存 OS/build、实际 App 路径和资产 hash；启动、转换、发布、重启恢复有明确结果；旧系统运行与目标构建分别记录 |
| P1 · 回归自动化 | 提交 QA workflow 后验证 GitHub Actions，并将稳定检查名设为分支保护必需项；UI scheme 在有权限的桌面环境单独执行 | PR 的失败检查可阻止合并；CI 记录执行数/跳过原因；常规回归不依赖签名私钥或用户生产配置 |
| P1 · 文件与恢复 | 在本地/iCloud 实际输出环境复测移动清理、参数保留、重启恢复与资源 receipt | 目标写入失败保留旧文件；外部修改、根目录变化与 receipt 场景不越权覆盖；Surge 参数声明/模板在两目标保留 |
| P1 · 原生/Web 体验 | 评估 Web 创建/修改接入持久队列的提交语义与草稿基线 | 工作区隔离、提交顺序、重启恢复、重试/取消均可观察；412/409 保留草稿，旧响应不覆盖新修改 |
| P2 · 有依据的性能维护 | 对长文本、目录扫描、元数据解析和文件 I/O 复测；在实测热点上按现有职责逐项整理 | 同 fixture/build 的前后对照及 hash 完整；保持取消、Unicode 位置、可见行号和事务保护；每次改动都有直接收益 |
| P2 · 文档和产物治理 | 把链接/版本核对接入自动门禁，评估测量脚本默认输出到已忽略的构建目录；更新上游审查快照 | 当前入口无断链；原始结果归档或保存为 CI artifact；fresh fetch 后记录 upstream tip/merge-base/计数，只挑选可移植提交 |

Developer ID、notarization、ATS 与 Sandbox 作为后续独立评估项：具备签名路径、来源例外模型、目录授权与旧配置迁移方案后再确定计划，继续遵守 [兼容性优先的发布策略](RELEASE_HARDENING.md)。

## 持续维护规则

行为和架构变更更新 `README.md` / `DEVELOPMENT.md`；发版事实写入 `CHANGELOG.md`；现状判断和验收结果更新本报告。随后运行 `node script/generate_project_status.mjs` 并执行 `--check`，保持自动状态页可复现。

旧审计和已完成的临时采集进入 archive；保留摘要、复现命令、结果 hash 与证据链接。既有归档目录沿用整理分组，单份材料的时间以其记录为准；新增采集按产生月份归档，当前文档中的日期按实际检查日期更新。
