# Surge Relay 项目综合报告

审计日期：2026-10-02（Asia/Shanghai）
代码基线：`386bc2e`，版本 **2.2.1（107）**，审计开始时工作区无未提交改动。
范围：现有功能、原生与 Web 交互和动画、性能实现、验证结果、后续功能建议。

**总体结论**

Surge Relay 已形成“接入来源 → 转换或直接读取 → 编辑与合并 → 本地/GitHub 发布 → 自动维护与活动追踪”的完整工作流。它已经超过单一转换工具，适合继续发展为可解释、可恢复的模块维护工作台。

当前优势是业务链路完整、原生与 Web 共用业务层、网络及存储边界较明确，并且具备有针对性的回归测试。下一阶段收益最大的工作是：先修复 Web 编辑不能保留双目标的问题，再补齐双目标发布的部分成功恢复、提供冲突 diff、改善大文本编辑、降低 Web 空闲状态成本，再统一动效细节。继续增加纯装饰动画的优先级较低。

代码支持单模块同时存放到本地和 GitHub，部分现行文档仍按单一目标描述。报告以当前源码为准；不能将自动生成状态文档或旧审计中的所有文字直接视为当前事实。

本次通过 **362 项原生单元测试**、Web 行为与 DOM 行为测试及发布配置 preflight。原生 UI Runner 两次均在启动阶段被系统终止，未完成 UI 验收。没有采集真实帧率、峰值内存、功耗、真实来源转换吞吐，因此以下视觉效果主要是实现分析，性能问题区分为“代码确定”与“影响程度待测”。

**1. 产品定位与工程结构**

| 维度 | 当前情况 | 判断 |
|---|---|---|
| 平台 | macOS deployment target 26.0，Swift 6，strict concurrency complete | 平台要求较新，原生系统组件可用；兼容范围应清晰告知用户 |
| 界面 | SwiftUI + AppKit 文本编辑器；随应用提供 Web 管理台 | 原生适合集中维护，Web 适合跨设备查看与轻量操作 |
| 业务 | MainActor AppModel 统筹；Planner 决策；actor Service 执行网络、转换、文件任务 | 决策可独立测试；仍需留意主线程上的编码、持久化和文本处理 |
| 规模 | 142 个应用 Swift 文件，约 23,312 行；47 个 unit test 文件、1 个 UI test 文件 | 已是需要持续维护状态与跨端契约的中等规模工具 |
| 测试 | 源码共 364 个 XCTest 方法，其中 unit 362、UI 2 | 测试数量不能替代覆盖率或性能验收 |
| 分发 | 自签名与 Sparkle EdDSA，保持兼容性优先 | 不应把 Developer ID、公证、Sandbox 改造作为此次功能报告的前置要求 |

依据：[工程配置](</Users/qidewei/Documents/Surge Relay/project.yml:1>)、[AppModel](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel.swift:75>)、[当前生成状态](</Users/qidewei/Documents/Surge Relay/DEVELOPMENT_STATUS.md:1>)。

**2. 现有功能与完成度**

| 功能 | 当前实际实现 | 效果及边界 |
|---|---|---|
| 多格式来源 | Surge 模块直接读取；Quantumult X、Loon 等通过内置 Script-Hub 转换；支持本地与远程来源 | 用户可集中维护异构来源；转换结果不等于已经验证规则在 Surge 中实际生效 |
| 来源与存放分离 | 区分 initialSource 与 storageTargets；名称、说明、category、icon、输出路径可配置 | 模型较完整，但“双目标”与旧单目标文案需要统一 |
| 本地导入 | 目录扫描、导入预览、文件夹与来源元数据处理 | 比直接拖入后立即写文件更易核对；复杂目录与大量文件仍需规模测试 |
| 转换维护 | 批量有界更新、缓存、取消、失败回退、来源版本检查 | 网络等待可并行，有缓存时可保留有效内容；缓存回退应始终明确提示 |
| 本地自动同步 | 文件事件约 900 ms 防抖，后台 hash，只转换真实变化项；忙时延后 | 避免保存文件触发整库转换，对外部编辑器工作流有价值 |
| 总模块 | 按选定模块合并其配置段；General/MITM 有专门合并规则 | 能集中安装和维护；文本合并成功不代表规则冲突已被语义分析 |
| 内容编辑 | 撤销/重做、查找替换、正则、跳转行、缩进、切换注释；手动 override 与恢复转换结果 | 已接近日常编辑工作台；尚非带完整 lint/诊断的专业配置 IDE |
| 草稿 | 原生与 Web 切换模块保留未保存草稿，Web 保护保存中的新输入 | 降低导航误丢失；当前会话内保存不等同于崩溃后恢复 |
| 发布 | 独立模块支持本地、GitHub 或双目标；总模块可同时发布两端；预览、受管旧文件清理、自动发布 | 核心能力完整；双目标失败恢复与命名语义仍可改进 |
| 同步冲突 | 两端 hash 不同可阻止继续更新，原生选择覆盖方向 | 能防止无意识覆盖，但没有共同基线与并排差异来解释冲突 |
| 管理界面 | 总览、模块筛选、详情/内容页、活动搜索、菜单栏、分类设置 | 覆盖日常使用；Web 与原生的功能范围并不完全一致 |
| Web | 模块管理、更新、取消、内容预览与编辑、活动和状态展示；SSE/轮询恢复 | 适合辅助管理；本地/GitHub 同步冲突解决与完整发布流程仍主要依赖原生；Web 已支持手动 override 冲突确认 |
| 凭据与诊断 | AES-256-GCM 本地凭据文件、配置备份/恢复、诊断与发布检查 | 有运维基础；配置备份和缓存快照不能当作用户可浏览的版本历史 |

关键代码：[来源转换](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ScriptHubClient.swift:50>)、[合并](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ModuleMerger.swift:13>)、[本地同步](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel+LocalSourceSync.swift:67>)、[手动编辑](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel+PreviewEditing.swift:5>)、[Web API](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/WebManagementAPI.swift:19>)。

**需要优先澄清的三个产品语义**

1. **“发布全部”实际是 GitHub 发布入口。** “发布所选”才按模块目标分别写本地/GitHub。README 已对这一行为做出解释，但按钮及 accessibilityLabel 仍容易让用户理解为全部目标。建议明确标为“发布到 GitHub”，或提供带目标摘要的统一发布入口。
2. **单模块双目标已经实现。** 原生编辑器使用 storageTargets 集合，而 README 多处仍写“每个独立模块只写入自己选择的存放目标”。应明确列出本地、GitHub、双目标三种情况及全局开关的影响。
3. **差异不一定是真正冲突。** 当前同步规划主要比较两端 hash，缺少共同基线，因此单边正常修改也可能需要选择覆盖方向。建议区分“本地领先”“远端领先”“两端均修改”。

依据：[发布入口与顺序](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel+Publishing.swift:5>)、[按钮文案](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleSidebarToolbarContent.swift:52>)、[双目标编辑器](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleEditorSections.swift:30>)、[双目标提示](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ModuleDraftPlanner.swift:77>)、[旧说明](</Users/qidewei/Documents/Surge Relay/README.md:122>)、[冲突规划](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ModuleSyncPlanner.swift:15>)。

**跨端编辑还存在一项高优先级问题。** Web 的 collectModuleFields 始终提交单个 storageLocation，不提交 storageTargets。服务端先从已有模块建立 draft，再设置 storageLocation；该 setter 会把 storageTargets 重设为单元素集合。因此双目标模块在 Web 里即使只改名称并保存，按当前调用路径也会退化为单目标，而不是原样保留。此项属于代码路径核验，未在真实用户数据上执行复现。

依据：[Web 提交字段](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-editor.js:186>)、[服务端字段赋值](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/WebManagementModels.swift:185>)、[目标集合 setter](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Models/ModuleDraft.swift:17>)。API 已支持 storageTargets，修复不需要先建设完整的新发布系统。

**3. 动画：实现效果与成本**

动画总体服务于导航连续性、任务反馈和局部状态变化，原生主要采用 180–250 ms 动效，Web 多为 140–280 ms。对这种需要阅读配置、比较内容的工具，短促、局部、有明确状态含义的反馈比长转场更合适。

| 场景 | 实现 | 效果判断与性能注意点 |
|---|---|---|
| 原生详情/内容切换 | 220 ms snappy，opacity + 6 pt 位移 | 帮助识别切换，幅度小；预览打开后保留 pane，利于保留草稿，但占用也保留 |
| 原生侧栏展开 | 200–220 ms，插入淡入/顶部移动，移除淡出 | 分组方向清楚；数百行同时展开需要测量布局成本 |
| 原生单行状态 | 180 ms，opacity + 0.85 scale，spinner/状态图标切换 | 反馈局部化；行视图避免直接依赖整个 AppModel，有利于减少刷新 |
| 原生任务进度 | 数字/进度约 250 ms，容器约 220 ms，numericText、等宽数字 | 数字跳动较少；进度变化应与真实完成任务一致 |
| 图标刷新 | 异步缓存加载，保留旧图直至新图就绪 | 减少占位图闪烁，比额外增加图片转场更有价值 |
| Web 按钮/开关 | 140–180 ms 的 hover、press、switch 反馈 | 成本较低，可确认点击和状态变化 |
| Web 更新状态 | 1.1 s opacity 循环 pulse | 不改布局；大量可见更新行时仍需检查能耗 |
| Web 进度 | width 300 ms transition | 直观；会涉及布局，单条通常不是主要负担，不宜批量复制到每行 |
| Web 对话框 | 打开 220 ms，关闭 160 ms，淡变/缩放/平移 | 状态边界明确；关闭与焦点恢复应同一时机完成 |
| Web 高级区域 | grid rows 260 ms；分组 WAAPI height+opacity 220 ms；手机弹层高度 280 ms | 内容高度连续，但不是纯合成动画，涉及测量和重排 |
| Web 手机导航 | 侧栏退出 260 ms、详情进入 280 ms | 已考虑安全区、44 px 触控目标、焦点与 inert；快速切换仍需真机验收 |
| Web 复制/toast | 复制成功约 1.6 s；toast 2.6 s，错误更长 | 信息有时间被读到；错误应保留可再次查阅入口 |

原生证据：[详情切换](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleDetailPaneView.swift:114>)、[侧栏和状态](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleSidebarView.swift:253>)、[任务卡](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleSidebarStatusCard.swift:65>)、[图标缓存](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/Components.swift:36>)。Web 证据：[CSS](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/app.css:409>)、[高级区域](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-editor.js:38>)、[反馈](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-feedback.js:98>)。

**动效方面可确认的缺口与待测问题**

- **Reduce Motion 有局部遗漏，代码可确认。** 原生 RootView 有 transaction 统一禁用动画；Web CSS 也有减少动画规则。但 animateOptionGroup 直接调用 220 ms 的 Web Animations API，没有检查 prefers-reduced-motion。CSS 的 animation-duration 规则不能覆盖这次 WAAPI 调用。应优先修复，而不是仅调短 CSS 时间。
- **Web 普通 Tab 切换并没有启用已有 page-in 动画。** CSS 定义了 240 ms 入场，但正常详情渲染和 Tab 切换传入 false。不能将“存在 CSS 定义”当成已实现的正常切页效果。即时切换可以保留，是否加淡变应由一致性和实测决定。
- **手机弹层快速展开可能存在动画竞争，待复现。** 参数分组有防重复进入标记，但 animateAdvancedResize 没有同等取消/合并机制；快速多次点击可能叠加高度动画与清理回调。
- **动画流畅度主要受内容工作影响。** 大文本全文高亮、窗口测量、整列表计算和状态编码可能占用主线程。仅调整 easing 或时长不能解决这些负担。

依据：[原生 Reduce Motion](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/RootView.swift:6>)、[WAAPI 遗漏](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-editor.js:63>)、[CSS 减少动态效果](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/app.css:734>)、[Web Tab](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-detail.js:38>)。

**4. 性能基础：已经做对的部分**

| 机制 | 当前实现 | 能解决什么 |
|---|---|---|
| 有界并发 | 最多 4 个模块任务，完成后递补、结果保持输入顺序 | 降低网络等待，同时避免无限并发改变合并顺序 |
| HTTP 限制 | 默认单响应上限 20 MiB、每 host 最多 4 连接、资源超时 90 s；检查声明与实际累计大小 | 限制异常大响应；这些上限不是整个进程的内存上限 |
| 可取消请求 | 取消传递到 URLSessionTask，待执行更新不再派发 | 用户停止操作后能减少无效网络工作 |
| 来源版本缓存 | ETag/Last-Modified、304、SHA256 比较 | 避免内容未变时重复转换 |
| 完整快照 | actor 内 staging 后替换正文与 assets | 避免得到一半新正文、一半旧资源 |
| 搜索后台化 | 120 ms 防抖、Task.detached、generation 隔离、正则可取消 | 快速输入不让过时查询覆盖新查询 |
| 查找/替换边界 | 高亮结果最多 5,000，全部替换处理全部匹配 | 控制展示成本，同时保证操作范围完整 |
| 原生行号 | 只绘制可见 viewport 的 glyph/行号 | 避免长文档产生超高位图 |
| Web 大文本 | 超过 256 × 1024 个 JS 字符时只读预览改用 textContent | 降低语法高亮 DOM 成本；这是字符阈值，不是精确文件字节数 |
| Web 增量和生命周期 | 行复用、焦点恢复、请求乱序隔离；隐藏页面断 SSE/停 timer，重连退避至 30 s | 减少后台刷新、焦点丢失和断网重试风暴 |

依据：[更新流水线](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ModuleUpdatePipeline.swift:4>)、[HTTP Client](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/BoundedHTTPClient.swift:7>)、[来源版本](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/SourceRevisionService.swift:18>)、[快照](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/ModuleFileStore.swift:43>)、[搜索调度](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleCodeEditorController.swift:359>)、[Web 大文本](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-preview.js:114>)、[连接生命周期](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-state.js:149>)。

**5. 性能与可靠性重点问题**

| 优先级 | 发现 | 确定性 | 建议 |
|---|---|---|---|
| 高 | Web 编辑只提交 storageLocation，服务端 setter 将 storageTargets 重设为单元素集合 | 代码路径确定，未用真实数据复现 | 编辑时保留完整目标集合；覆盖“只改名称仍保留双目标”的回归场景 |
| 高 | 原生语法高亮仍在主线程全文重置 attributes、多轮正则；24 ms 防抖只减少频次 | 实现确定，卡顿幅度未测 | 先提供大文件纯文本降级，再做后台分词/增量高亮 |
| 高 | 文本测量复制 attributed text 并布局整篇，高亮完成又使尺寸缓存失效 | 实现确定，resize/输入叠加成本未测 | 减少全文测量，细化缓存失效，以输入 p95 和主线程任务时间验收 |
| 高 | EmbeddedScriptHubEngine 是单 actor，同步执行 convert | 串行限制确定 | 先分离下载和转换耗时；不要直接提高外层并发期待同比收益 |
| 高 | 10 s deadline 在 evaluateScript 返回后才开始约束等待完成 | 实现缺口确定，未触发无限脚本测试 | 为耗时脚本提供可终止的执行边界，验证取消到实际停止的延迟 |
| 高 | 本地先发布、GitHub 后发布；后者失败可留下“本地成功、GitHub 失败”的状态 | 顺序确定，未真实发布复现 | 逐目标保存结果，只重试未完成目标，不要求跨网络事务回滚 |
| 中 | 每个 SSE 连接每秒生成并编码完整状态，再比较是否发送 | 成本确定，规模影响未测 | 按 revision 只编码一次并共享给连接，低频模块状态与高频进度分开 |
| 中 | Web DOM 有 patch，但仍为所有可见模块生成 markup，无列表虚拟化 | 实现确定，大列表影响未测 | 先测 1,000/5,000 模块，再决定窗口化，避免提前复杂化 |
| 中 | 常规 saveModules 在 MainActor 同步 JSON 编码与 atomic 写盘 | 路径确定，慢盘风险未测 | 串行后台快照落盘，并保留失败提示和写入顺序 |
| 中 | Web 服务缺少可见的全局连接/SSE 上限和请求读取 deadline | 静态审计未见相应约束 | 长期开启及多客户端场景做限额与超时测试 |
| 低 | 查找截断至 5,000 仍显示“5000 个结果” | 实现确定 | 显示“5000+，仅展示前 5000 项”，与全部替换范围区分 |

主要证据：[原生高亮](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleCodeTextView.swift:649>)、[全文测量](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Views/ModuleCodeTextView.swift:88>)、[JS 同步执行](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/EmbeddedScriptHubEngine.swift:80>)、[JS deadline](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/EmbeddedScriptHubEngine.swift:181>)、[双目标发布](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel+Publishing.swift:71>)、[SSE 循环](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/WebManagementServer.swift:180>)、[MainActor 编码](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/WebManagementAPI.swift:3>)、[列表 patch](</Users/qidewei/Documents/Surge Relay/SurgeRelay/WebResources/web-sidebar.js:55>)、[同步落盘](</Users/qidewei/Documents/Surge Relay/SurgeRelay/AppModel+Modules.swift:294>)、[搜索上限](</Users/qidewei/Documents/Surge Relay/SurgeRelay/Services/CodeSearchEngine.swift:24>)。

**6. 本次验证与性能数据**

| 验证 | 结果 | 含义 |
|---|---|---|
| generate_project_status --check | 通过 | 生成器输出与当前文件一致；不代表全部人工文案自动正确 |
| test_web_resources.mjs | 通过 | Web 资源逻辑和契约回归通过 |
| test_web_dom_resources.mjs | 通过 | 模拟 DOM 行为回归通过；不等同真实浏览器渲染验收 |
| check_release_configuration.sh，2.2.1/107 | 通过 | 版本、Sparkle、appcast、脚本、Web 资源和工程登记符合当前检查 |
| Xcode 原生单元测试 | 362 通过，0 失败，0 跳过 | xcresult 确认；本次以本机 Xcode 27.0、arm64 运行 |
| 原生 UI 测试 | 未完成 | Runner 在建立测试连接前被系统 kill；关闭签名和本机 ad-hoc 签名两种构建均未成功启动 |
| 实际动画/内存/功耗 | 未测 | 不提供“60 FPS”“低内存”等无证据结论 |

用户看到的“SurgeRelayUITests-Runner.app 已损坏”弹窗来自临时 UI 测试 Runner，不是应用主程序损坏的证据。补签名未解除启动问题；本次未修改系统安全设置，未继续反复启动 Runner。失败发生在测试启动阶段，不能据此判定两个 UI workflow 的断言失败。

现有测试中的受控等待基准，本次导出附件结果：

| 场景 | 本次耗时 |
|---|---:|
| 24 个任务，每个等待 25 ms，串行 | 0.657401208 s |
| 同样任务，最大 4 并发 | 0.159961458 s |
| 比值 | 约 4.11×，耗时减少约 75.7% |

该测试使用 Task.sleep 模拟等待，只输出附件，没有性能阈值断言。数据能证明这个受控样本中有界并发减少了等待，**不能证明 Script-Hub 转换、真实网络、UI 或整个应用提速 4.11 倍**。单次采样也不能代表稳定分布。

测试依据：[等待基准](</Users/qidewei/Documents/Surge Relay/SurgeRelayTests/ModuleUpdatePipelineTests.swift:55>)、[原生 UI workflow](</Users/qidewei/Documents/Surge Relay/SurgeRelayUITests/SurgeRelayUITests.swift:1>)。本次临时测试日志位于 `/tmp/surge-relay-audit-tests.log`、`/tmp/surge-relay-audit-ui-tests.log`、`/tmp/surge-relay-audit-ui-signed-tests.log`，重启或系统清理后可能消失。

另有开发入口问题：[build_and_run.sh](</Users/qidewei/Documents/Surge Relay/script/build_and_run.sh:12>) 默认指定旧外接卷 Xcode-beta 路径，本机该路径不存在。本次测试使用 xcode-select 当前选中的 `/Applications/Xcode.app` 成功完成单元测试。建议运行脚本默认尊重当前工具链或检查回退，减少新环境无法启动的情况。

**7. 后续新功能：按用户收益排序**

以下均为建议，没有在本次报告任务中实现。工作量是相对量级，尚未作排期承诺。

| 阶段 | 功能想法 | 用户价值 | 最小可交付版本与验收 | 相对工作量 |
|---|---|---|---|---|
| 先修缺陷 | Web 编辑保留双目标 | 避免改名称等操作意外改变发布目标 | 表单提交完整 storageTargets，或未修改时不覆盖；回归原生创建→Web 编辑→目标仍完整 | 小 |
| 先补闭环 | 双目标发布结果与单目标重试 | 不再把部分成功误解为全部失败 | 分别展示本地/GitHub 结果；一次失败后仅重试失败目标，活动记录可追踪 | 中 |
| 先补闭环 | 更新前后 diff、同步冲突对比 | 用户能看清到底改了什么，再决定覆盖 | 先做只读行级 diff、变化摘要和明确覆盖方向；后续再加共同基线/三方合并 | 中→大 |
| 先补闭环 | 持久草稿与恢复入口 | 长文编辑遇退出或崩溃可找回 | 按模块保存草稿与基线 hash；恢复时若上游变化先提示，明确区分草稿与已发布内容 | 中 |
| 先补体验 | 大文件模式 | 长配置输入、滚动更可控 | 超阈值提示纯文本模式；后台查找继续可用；输入与 resize 有测量预算 | 小→中 |
| 先补体验 | 统一减少动态效果与中断行为 | 动画敏感用户与快速操作均可稳定使用 | CSS/WAAPI 同步遵循偏好；弹层只保留一个有效动画，焦点正确恢复 | 小 |
| 下一阶段 | Web 双目标同步冲突解决与发布预览 | 手机/另一台设备能完成维护闭环 | 有授权的发布预览、目标摘要、冲突 diff 和执行结果；继续复用原生业务层 | 中→大 |
| 下一阶段 | 发布前规则检查 | 降低“转换成功、安装后失效”的概率 | 先做明确规则：重复项、脚本引用缺失、语法问题；不确定的语义问题标为建议 | 中 |
| 下一阶段 | 内容版本历史与回退 | 上游变更后可快速恢复已知可用版本 | 保存有限数量的已发布内容/资源快照，显示 diff，可选择版本重新发布 | 中→大 |
| 下一阶段 | 分阶段任务进度与性能明细 | 用户知道慢在下载、转换还是发布 | 活动中记录下载/转换/缓存/发布时长和回退原因，不加无意义常驻动画 | 中 |
| 规模扩大后 | 按来源刷新策略与失败退避 | 减少无效请求，照顾不同来源更新频率 | 支持少量策略档位、遵循 429/Retry-After、显示下次重试时间 | 中 |
| 规模扩大后 | 多工作区/多仓库、可复用模块模板 | 服务多设备、多账户与重复配置 | 先验证实际用户需求，避免过早改动全部配置模型 | 大 |

优先级判断：如果只安排下一轮工作，建议先修 Web 双目标保存问题，再选择“逐目标发布结果 + diff + 大文本性能基线”，并顺手修复 Reduce Motion 与文档不一致。这组工作直接提高可信度、日常效率和可恢复性。

暂不优先扩展流量仪表盘、复杂粒子动效或完整多用户权限平台。这些功能与现有模块维护主线距离更远，应在需求得到验证后再评估。

**8. 后续性能验收建议**

先建立可重复的受控数据集，再决定是否引入虚拟列表、多个 JS worker 或更复杂缓存。以下是建议目标和测试矩阵，不是当前已达到的数据。

| 场景 | 建议组合 | 观测指标 |
|---|---|---|
| 列表与动效 | 100 / 1,000 / 5,000 模块，批量更新同时滚动、筛选、展开 | p95 帧时间、主线程长任务、掉帧、峰值内存 |
| 编辑器 | 100 KiB / 1 MiB / 5 MiB 文本，输入、正则查找、替换、resize、切 Tab | 输入至显示 p95、搜索完成时间、取消延迟、全文布局次数 |
| 更新 | 原生 / 转换 / 混合来源，缓存命中 / 失效 / 部分失败 | 端到端耗时及分阶段占比、网络字节、取消至停止时间 |
| Web 服务 | 1 / 3 / 10 客户端，空闲 / 更新中 / 隐藏恢复 | 空闲 CPU、每秒 JSON 编码次数、流量、连接数 |
| 双目标发布 | 本地成功远端失败、远端权限错误、取消、重试 | 结果是否准确、是否重复写入、能否只重试失败目标 |
| 无障碍与中断 | Reduce Motion 开/关，快速连点、键盘导航、手机返回 | 不播放非必要位移、无残留高度、焦点与滚动保留 |

60 Hz 的单帧预算约 16.7 ms，120 Hz 约 8.3 ms；可以先以输入响应 p95 小于 100 ms 作为产品目标，再根据设备与数据规模调整。网络耗时、受控等待基准与 UI 响应时间必须分别报告。

本次仅新增此报告；未修改产品代码、用户配置或发布内容。报告中的代码证据均对应开头声明的 Git 基线，后续代码变化可能使行号发生偏移。
