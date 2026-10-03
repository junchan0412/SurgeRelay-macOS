# 项目改进实施与验收记录

更新日期：2026-10-04（Asia/Shanghai）。范围对应 [原始综合报告](PROJECT_REVIEW_2026-10-02.md) 第 1–8 部分。原报告描述的是审计开始时的 `386bc2e` 基线；其中“尚未实现”不能直接用于判断当前工作区。本文件按当前实现与证据重新归并，不再累加相互矛盾的历史待办。

**总体状态：已按用户最终确认收尾。** 代码修复、新功能、受控功能回归与保留范围的验收已完成；用户于2026-10-04确认接受现有轻量列表性能数据，并保留未直接测得GPU实际呈现帧/掉帧的限制。Web服务仍由用户自主开启/关闭；500以上模块的后续测试与专门优化已按用户要求取消。

## 1. 已实现的功能与可靠性

| 对应原报告建议 | 当前实现 | 验证与保留边界 |
|---|---|---|
| Web 编辑保留双目标、文案一致性 | 表单提交完整 storageTargets，兼容单目标；发布到 GitHub 的入口语义、README 和开发脚本已更新 | Web 行为/DOM及真实 Chrome 表单验证通过；原生隔离应用重开编辑仍保留双目标 |
| 逐目标发布结果与重试 | 本地/GitHub 分别记录结果，持久恢复记录，只重试未完成目标；原生/Web 共用发布预览、执行与结果业务 | 单元与 fixture 浏览器覆盖部分成功、重载恢复、取消、过期票据；远端403已由生产GitHubClient HTTP mock验证；不对真实仓库写入测试内容 |
| 同步 diff 与共同基线 | 区分同步状态，提供行级 diff、覆盖方向、基线 scope、比较后复核、GitHub head CAS、本地协调写入前 hash 检查 | 原生/Web入口及竞态回归已实现；不是自动三方合并，也不承诺非协作写入者在最终检查与 rename 之间绝无竞争 |
| 持久草稿 | 原生后台落盘、Web IndexedDB；草稿带基线，恢复时提示变化，保存期间保护后续输入；工作区隔离 | Chrome 验证 5,700,016 UTF-8 bytes 草稿重载恢复；这是恢复正确性，不是大文本键入性能证据 |
| 条件编辑与恢复转换 | PUT 保存及 DELETE 恢复均有 If-Match、busy/模块变化保护；返回正文与 hash 分离 | 单元及 Web 回归覆盖 stale 拒绝和草稿保留；新增大 HTTP 正文 XCTest 已通过，最新全量集成518通过、2skip、0失败 |
| 发布前规则检查 | 确定性结构错误、缺失本模块资源阻止发布；未知段、重复项等标 warning；原生/Web显示行号与确认入口 | lint 回归已实现；不等于证明所有规则在 Surge 中实际生效，不将启发式升级为确定错误 |
| 版本历史、diff 与恢复 | 保存正文、转换正文、override 状态和原始资源；最多20版/128MiB，至少保留最近1版；历史与当前可比较正文和资源 | 本次回退只恢复缓存并重建汇总，不立即发布，保留草稿并把该模块刷新设为仅手动；后续发布仍按现有发布设置执行，并应用当前元数据/参数设置 |
| 回退与资源归属崩溃恢复 | 回退事务 journal 支持 prepared 回滚、committed 前滚、metadata 待确认及启动恢复；资源发布采用原始 bytes、持久 journal/归属 receipt、文件身份与 hash 核验 | 已有新 store 实例重启及恢复中再次中断故障注入；旧文档“资源写入与归属记录窗口尚无恢复设计”已过时。不是跨本地/GitHub 的分布式事务 |
| 分阶段进度与明细 | 下载、转换、缓存、发布指标与回退原因；活动阶段节流显示，明细持久化，两端可查看 | 受控九格 metrics on/off 与浏览器展示已验证；真实公网 Script-Hub/GitHub端到端性能仍未覆盖 |
| 刷新策略与失败退避 | 按模块刷新间隔、普通失败退避、429/Retry-After、下次重试；手动更新可绕普通退避但遵循服务器 deadline | 相关规划/请求回归已实现；不再列为未实现功能 |
| 持久化离开 MainActor | 模块、设置、活动、发布恢复记录和草稿经串行后台写入，错误可见；迁移/退出 flush | 已有顺序、错误、迁移/生命周期回归；不是把所有磁盘操作都移出了主线程 |
| 多工作区/多仓库与模板 | 单活工作区、独立配置/缓存/凭据上下文；切换前 flush、停止旧服务/任务并清票据；模块设置可保存为模板 | Web fixture 验证 SSE 切换、相同模块ID、草稿迁移与请求 scope；模板排除来源地址和凭据。不是同时运行多个工作区；最终原生工作区/模板流程仍需验收 |

更新前后变化现在可通过历史版本与当前内容 diff 查看，同步差异有独立入口。没有证据表明已提供“每次更新后自动弹出差异摘要”或自动三方合并；这两项属于可选后续体验，不能与已有 diff 功能混为一谈。

## 2. 动画、编辑器与 Web 性能实现

- CSS、WAAPI 和 dialog backdrop 已统一遵循 Reduce Motion；快速展开/关闭取消旧动画，清理临时高度，恢复焦点。真实 Chrome 验证通过；headless 移动 viewport 不是手机真机手势验收。普通 Tab 仍可即时切换，不把未启用的 page-in CSS 算作已有动画。
- 原生已有大文件纯文本模式、后台语法分析、测量改进、后台查找及准确的“5000+”截断提示。最终同一 Release 构建的三档真实按键已达到本次 AppKit 输入预算；三档组件编辑矩阵已独立通过；实际编辑页签组合、GPU呈现与列表动画不能由组件结果替代。
- 转换已有独立 JSC helper、进程隔离、超时与强制取消边界；无限脚本退出与 helper 执行有定向验证。不能把 Task.sleep 并发基准称为真实转换提速。
- Web SSE 共用生产者与编码缓存，现代客户端分离 state/activity，保留旧 full 客户端；每连接最多一个正在发送的帧，只保留最新待发状态，两个通道公平发送。连接、请求读取与服务关闭有约束和回归。
- 完整 DTO、summary、目录选项、图标路径检查及 JSON 已迁入后台 actor；MainActor 只原子捕获 Sendable 输入和 revision。HTTP state 与 SSE 共用版本；activity fallback 保持平铺字段并带 runtimeID/workspaceID/revision，前端拒绝晚到旧响应。
- 这次后台迁移覆盖 state/SSE 和 activity 的派生计算。history、发布预览、同步差异等 API 仍可能同步 `.json`；不宣称所有编码均已后台化。

## 3. 已验证证据及时间边界

**最新Release回归：518通过、2个opt-in benchmark跳过、0失败（2026-10-04）。** 最终结果与源码摘要已归档在[最终验证记录](performance/final-validation-2026-10-04.json)，发布preflight也通过。下述2026-10-03路径为历史运行标识。 结果：`/tmp/surge-relay-goal-build/Logs/Test/Test-Surge Relay-2026.10.03_11-47-18-+0800.xcresult`。此前以为被中断的这轮运行实际已经正常结束；它取代514通过/1skip作为当前全量结果。两个跳过项分别为生产Web负载和编辑器组件矩阵，均已独立正式运行通过；不把skip算作本轮重新测量，也不将独立通过数加到全量计数。

此前508通过/2失败/1skip为较早整合，两个编辑器夹具问题随后修复，24项编辑器定向通过后完成本次全量；505通过+1skip发生在大HTTP补丁前。历史计数不累加，也不替代最终结果。

大 HTTP 补丁已通过应用 Release 构建及新增 HTTP XCTest：32KiB headers 后提前认证；仅有效模块 UUID 的 PUT preview 允许20MiB正文，其他路径维持4MiB；覆盖5MiB保存/回读、stale/busy、提前拒绝及framing边界。最新518项通过的全量结果覆盖这些改动与当前编辑器集成状态。

| 证据 | 已确认结果 | 不能据此推导 |
|---|---|---|
| [Web 浏览器基线](performance/WEB_BROWSER_BASELINE.md) | 100/1000/5000模块筛选至两次rAF p95为34.8/34.7/51.6ms；5000模块同步input p95为26.7ms，出现1个62ms长任务 | 不是有屏60FPS、120Hz或原生列表验收，也不是完整浏览器RSS |
| [Web 发布浏览器记录](performance/web-publication-acceptance.json) | 预览取消、部分成功重试、同步方向、过期票据、历史回退和草稿保留；无页面错误 | fixture未验证真实GitHub写入、权限错误与公网失败 |
| [Web 工作区记录](performance/web-workspace-acceptance.json) | SSE切换、草稿隔离、IndexedDB迁移、旧workspace请求拒绝 | 不代表最终原生工作区/模板界面已验收 |
| [阶段指标基线](performance/STAGE_METRICS_BASELINE.md) | 原生/helper/混合×命中/失效/部分失败九格；metrics开销中位数变化−0.7%～+6.5%，在受控10%预算内 | helper用固定转换脚本；不是公网Script-Hub、GitHub或完整AppModel/UI的端到端收益 |
| [后台快照正式矩阵](performance/WEB_SERVER_BACKGROUND_SNAPSHOT.md) | Release定向21通过+1skip；正式矩阵1通过，56.242s。5000模块、1/3/10请求接受1/3/8，另2个503 | 短窗口，不是长期soak或10个同时接受的流；未涵盖最新大HTTP补丁 |
| 同上：core变化 | MainActor捕获最大0.105/0.117/0.116ms；后台prepare约140–143ms，JSON约72–75ms | 后台成本仍在，完整状态传输量未减少；不等于整应用主线程最大耗时小于1ms |
| 同上：activity-only | 三组0full编码/正文；4次共享activity编码，8流正文18,808B；idle/隐藏和stop稳态无新编码 | 保留15s keep-alive；短idle窗口不是长期零流量或功耗结论 |
| [原生有屏交互](performance/NATIVE_UI_ACCEPTANCE.md) | 隔离应用设置、双目标新增/重开、活动搜索与清空取消、退出flush | UI Runner automation mode超时仍未解决；后续工作区/模板与大规模动画未包括 |
| [原生编辑输入最终复测](performance/native-input-2026-10-03/README.md) | 同一Release PID14034、bundle ID后缀attribution20261003；每档40次真实x按键，100KiB/1MiB/5MiB p95分别**72.548875/22.086375/56.420999ms**，对应39/40/40个更新组；5MiB点击/滚动/末尾输入、5000+搜索及六位行号截图核验通过 | 三档均低于100ms，但边界为keyDown至AppKit didUpdate；不是GPU呈现延迟/FPS；组件编辑矩阵另见下一行 |
| [原生编辑器组件矩阵](performance/NATIVE_EDITOR_COMPONENT_MATRIX.md) | Release opt-in 1通过/0skip/0失败，最新7.696s；三档查找/正则、实际替换与Undo、Tab/换行、240/960pt resize、查询取消及外部reload通过；原始附件已归档 | 每项一次组件耗时，不是p95/真实SwiftUI页签；新矩阵已补测量临时manager全文次数2/0/0及三档有效取消时延；全App内部layout总数不外推 |
| [原生实际页签状态](performance/native-tab-state-2026-10-03.json) | 隔离有屏1MiB草稿，预览→详情→预览后TABQA20261003、未保存标记、查询、选中匹配、行34957/列177、横向0.600423/纵向1及查找框焦点保持 | 使用保留的Attribution QA构建；查询已完成，不是进行中取消或帧率证据；后续sidebar/recorder改动未改变该编辑器实现 |

Web 后台快照正式结果的场景最高采样RSS为285.80/291.00/328.67MiB，初始full约9.25MiB；8流module-state窗口仍约222MiB full正文。线程迁移没有消除全量投影、传输或内存成本。各独立证据的源码/二进制、环境与样本口径以对应文档和JSON为准，不混用不同补丁版本进行无条件性能承诺。

本轮最终发布配置 preflight 已通过（[归档日志](performance/final-preflight-2026-10-04.log)），包括工程登记、重新生成状态和 Web 行为/DOM 回归。版本仍为2.2.1（107）的未发布工作区。helper签名/运行检查另有此前独立证据。

### 开发临时文件清理

按用户要求先完成清理，再继续剩余验收。2026-10-03已删除32处本次开发旧缓存、构建中间件及trace，删除前allocated估计合计6.42GiB，磁盘可用空间约84→90GiB；详见 [逐项清理记录](performance/development-cleanup-2026-10-03.json)。9月已有的build/dist/codex-run保留，源码、测试、报告和已归档JSON/导出证据保留。

历史报告中的 `/tmp` 构建、trace、UI Runner或测试路径用于标识当时运行，不保证清理后仍可打开。清单内的旧trace与构建目录已经删除，后续复现需重新生成，不能再引用其“仍在磁盘”或重复计算空间。恢复目标时已确认此前SurgeRelay临时目录均不存在、无活跃QA/构建，磁盘可用约96GiB。518项全量xcresult路径仅标识历史运行，当前不能再打开；清理不改变已归档结果，也不把尚未取得的原生帧指标算作完成。

## 4. 原报告第8节范围内的剩余验收

原报告明确先建立“可重复的受控数据集”。用户随后明确：“不需要测试500以上的模块情况了”。据此取消后续500以上模块规模验收及针对该规模的专门优化，原生列表范围仅100模块，当前实际交互组合已完成；不新增500模块档位。既有1000/5000模块数据作为历史保留，不再构成未完成门槛。5MiB文本大小、查找5000项结果上限并非模块数量，继续按原范围验证。其余操作与指标保留，不追加实体硬件、生产写入或无限时长测试作为完成门槛。

| 原矩阵 | 当前覆盖 | 剩余项 |
|---|---|---|
| 列表与动效：按用户最新范围仅100模块，更新中滚动、筛选、展开；帧时、长任务、掉帧、峰值内存 | [当前100模块验收](performance/NATIVE_LIST_ACCEPTANCE.md)：真实更新中滚动/筛选/展开通过；529个active/visible回调，间隔p9541.654ms、最大348.286ms，1Hz RSS峰275972096B，无记录丢失/采集上限 | 回调间隔及节奏缺失估计不是GPU帧时/掉帧或CPU长任务时长；保留未直接测得的指标限制，不宣称满帧，不把16.7ms新增为硬性门槛 |
| 编辑器：100KiB/1MiB/5MiB输入、正则、替换、resize、Tab；搜索时间、取消、全文布局次数 | 三档真实按键p95及5MiB基本搜索/滚动/行号通过；新增三档Release组件矩阵覆盖查找/正则、替换/Undo、Tab/换行、resize、取消/reload | 实际1MiB详情↔预览草稿/查询/选区/滚动已验证；新矩阵已补尺寸测量全文请求/完成计数及三档实际progress后取消时延；不外推全App内部layout总数。组件单次耗时不称p95，不新增全部操作逐档有屏重复门槛 |
| 更新：原生/转换/混合×命中/失效/部分失败；阶段、端到端时间、网络字节、取消停止 | 固定helper九格及[生产Script-Hub九格](performance/SCRIPT_HUB_PRODUCTION_BASELINE.md)通过；网络字节、超时/强制取消已有 | 受控生产脚本逻辑与代表产物已验证；明确保留网络bridge替代、非完整AppModel更新边界，不追加公网门槛 |
| Web：1/3/10客户端，空闲/更新/隐藏恢复；CPU、编码、流量、连接 | 生产矩阵已覆盖，10请求按8流上限接受8并拒绝2 | 原范围基本覆盖；不强制改变限额接受10流或追加长期soak |
| 双目标发布：部分成功、远端权限错误、取消、重试 | 部分成功、取消、只重试失败目标已有；新增生产GitHubClient HTTP403→持久恢复→仅远端重试测试1通过 | 原范围权限缺项已补齐，无需真实仓库写入 |
| 无障碍/中断：Reduce Motion开关、连点、键盘、手机返回；焦点、滚动、高度清理 | Chrome减少动态效果/快切；390px真实Chrome验证Tab键盘、Escape返焦、mobile-back/history前后退和列表滚动；单元覆盖其余导航 | 移动返回组合已补齐；headless viewport结论不外推实体设备FPS |

最新全量518通过/2skip/0失败，发布preflight、生成状态及Web回归已有通过记录，不再列为未完成。新增原生功能的入口连通审查已有；针对嵌套版本发布确认等风险补有屏验收有价值，但不把所有新增界面的逐屏人工复查无限扩展为第8节强制矩阵。

### 新增定向证据与跨端覆盖核对

- **实际SwiftUI页签已验证：** [1MiB有屏记录](performance/native-tab-state-2026-10-03.json) 核验预览→详情→预览保留草稿、未保存状态、已完成查询及匹配、光标、水平/垂直滚动和查找框焦点。不能再列“实际Tab未验证”；进行中取消/reload的语义另由组件测试覆盖，取消时延已由2026-10-04实际progress协议补齐。
- **当前100模块实际列表组合已完成：** [验收报告](performance/NATIVE_LIST_ACCEPTANCE.md) 使用leaf菜单拆分后的QA构建，真实HTTP更新中完成14次整页滚动、筛选/清除、折叠/展开；动作进度0→8→12→24，筛选时11项可见。529回调均active/visible，间隔p9541.654ms、max348.286ms；7次1Hz采样RSS峰275972096B，无记录丢失或采集上限。存在明显调度长间隔，不能称为满帧，也不能把回调间隔/估计缺失数当GPU帧时/实际掉帧/CPU长任务时长。旧1000/5000仅保留历史。
- **三档编辑组件矩阵已补齐：** [组件报告](performance/NATIVE_EDITOR_COMPONENT_MATRIX.md) 与 [原始附件](performance/native-editor-component-matrix-2026-10-03.json)。Release独立1通过/0skip/0失败，7.839秒，xcresult为`/tmp/surge-relay-editor-component-matrix-20261003.xcresult`。5MiB全量替换完成含查找刷新1.590秒、Undo调用1.286秒；它们是单次组件成本，不能与最终真实输入p95混用，该独立性能结果不与当前518项全量计数相加。
- **GitHub403已补齐：** `GitHubPublishTests.testGitHub403AfterLocalSuccessPersistsFailureAndRetriesOnlyRemote` 使用生产GitHubClient/REST/URLSession，URLProtocol在POST blobs返回403；验证本地成功、远端失败、明确权限消息、无额外提交及自动重试；磁盘JSON恢复后只重试远端并完成提交，本地不重写。定向 **1通过/0skip/0失败**，结果 `/tmp/surge-relay-goal-build/Logs/Test/Test-Surge Relay-2026.10.03_07-45-02-+0800.xcresult`。这是此前514全量之后新增的独立通过项；当前另有518项全量通过结果，不能通过累加独立测试伪造全量计数。
- **代表性生产转换已补齐：** [生产Script-Hub基线](performance/SCRIPT_HUB_PRODUCTION_BASELINE.md) 实际执行 `Rewrite-Parser.js` 和 `script-converter.js`，QX/Loon各1500条代表规则验证完整产物；8×1 smoke和24×5正式off/on均通过。九格指标开销−1.49%～+7.76%，在10%预算内。脚本身份以manifest完整SHA-256为准；driver真实loopback下载后通过测试prelude交付正文，生产网络bridge被替代，因此不宣称公网或完整ScriptHubClient资产物化/AppModel更新已验收。
- **取消已有明确停止边界：** `ScriptHubTests.testScriptWorkerTerminatesInfiniteJavaScriptAndRecovers` 验证250ms超时且返回<2s；`testScriptWorkerKillsHelperThatIgnoresTermination` 在确认忽略TERM后取消，断言停止返回400ms至2s。这是实际退出边界，不是九格的取消分布。
- **键盘与焦点已覆盖的行为：** `script/web-resource-tests/navigation-preview.test.mjs` 验证搜索ArrowDown进入列表、End/Home/ArrowDown导航、Escape返回搜索、Enter激活命中项、IME保护，以及更新行后焦点保留；同文件验证保存后编辑区scrollTop/selection保留。`detail.test.mjs` 验证ArrowRight/Home切Tab和焦点；`editor-feedback-preview.test.mjs` 验证Escape取消确认及dialog关闭返回opener。这些为模拟DOM/控制器证据，不能描述为真实键盘浏览器全流程。
- **移动返回组合已补齐：** [真实Chrome记录](performance/web-mobile-navigation-acceptance.json) 使用390×844 headless Chrome154.0.8037.98及隔离fixture，5组检查通过、0页面错误；详情Tab实际ArrowRight/Home、编辑弹窗Escape返焦、mobile-back、浏览器back/forward及Command-K通过。真实验收发现返回时document.scrollY从2105丢到0且焦点落BODY；现已保存进入详情前列表位置，返回后恢复原模块焦点和scrollY2105，搜索快捷键不被返焦覆盖。移动布局使用文档滚动，不能误测桌面 `.module-navigation.scrollTop`。复现脚本为 `script/verify_web_mobile_navigation_browser.mjs`。

## 5. 可选外推验证与后续功能

以下不是原第8节新增强制门槛：实体手机/触摸硬件、真实GitHub写入及权限变更、公网Script-Hub网络、限速丢包/慢客户端长期soak、功耗、GPU逐像素呈现测量。它们可用于扩大结论适用范围；没有这些数据时只需准确限定现有证据，不能因此无限延长原目标。

自动更新后差异摘要、自动三方合并、并行多工作区、模块增量协议和虚拟列表属于可选后续迭代。三档查询取消与measurement-layout新矩阵已通过，新增源码的Release集成回归和preflight也已通过。用户已确认按已披露的轻量列表度量口径收尾。100模块实际列表交互、三档输入、组件操作矩阵、真实1MiB页签状态、生产转换九格、Web负载、双目标403恢复和移动返回均已有证据，不重复列为未完成。列表直接呈现帧时、GPU掉帧、CPU长任务时长仍未取得，作为指标覆盖限制明确保留；不将16.7ms说明性预算变成新增硬门槛，也不宣称满帧或整个目标完成。500以上模块验收及专门优化已依用户要求取消。本轮约419MiB单一临时目录已在最终结果归档后删除，当前磁盘可用约91GiB；见[最终清理记录](performance/final-cleanup-2026-10-04.json)。


## 最终补充证据（2026-10-04）

- Release全量回归518通过、2跳过、0失败；两个opt-in分别为用户不再要求重跑的大规模Web负载与已独立运行的编辑组件矩阵，没有执行500以上模块场景。最终preflight、Web资源/DOM、工程登记及diff检查通过。
- 新三档编辑矩阵1通过、0跳过、0失败，7.696秒；固定fixture在真实regex progress之后取消，worker均未提前完成，无internalError，停止完成约6.361/6.305/6.307ms（5ms观察粒度）。[最终附件](performance/native-editor-component-matrix-2026-10-04.json)。
- 尺寸测量临时layout manager的全文请求/完成数为2/2、0/0、0/0；与原全文尺寸测量热点对应，不能扩称整个AppKit内部重排总数。[组件报告](performance/NATIVE_EDITOR_COMPONENT_MATRIX.md)。
- [真实页签证据](performance/native-tab-state-2026-10-03.json)已证明1MiB草稿、查询结果/选区、滚动与焦点保持；不再把它列为未完成。
- [100模块列表证据](performance/NATIVE_LIST_ACCEPTANCE.md)覆盖真实更新中的滚动、筛选与展开；回调p95约41.65ms，仍有长间隔，不称满帧。用户已明确回复“确认收尾”，接受保留上述度量限制；该确认不等于取得GPU帧率数据。
- 版本仍为2.2.1（107），工作区改动未发布。源码、报告与小体积原始证据保留；临时构建/QA目录已在结果归档后清理。

## 最终确认

2026-10-04，用户明确“确认收尾”。最终核对292个源码/测试文件的内容摘要与已验证版本一致；Release回归518通过、2项opt-in跳过、0失败，编辑器矩阵独立通过，发布preflight通过。没有遗留测试应用、构建或采样进程，单一临时QA目录已删除。保留报告与小体积证据，不再追加500以上模块测试。改动保留在工作区，未发布。
