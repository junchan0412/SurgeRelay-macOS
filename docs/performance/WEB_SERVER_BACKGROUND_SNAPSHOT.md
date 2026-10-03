# Web 完整快照后台构造复测（2026-10-02）

本轮接续 [activity 分流复测](WEB_SERVER_ACTIVITY_SPLIT.md)，将剩余的完整 DTO 构造移出 MainActor。协议继续保留完整 state 与独立 activity，不采用 module delta。5000 模块的 module-state 窗口中，MainActor 捕获最大耗时从上一版 **140–142 ms 降至 0.105–0.117 ms**；原有计算继续在后台执行，总准备与编码成本没有消失。

## 捕获与后台工作

MainActor 同步捕获 modules 数组、moduleRevision、settings、原始目录列表、history 前四项与完整 history 的值语义引用、workspace 标量、workActivity/同步模块 ID 集合等 Sendable 输入，并在同一个不含 await 的捕获中分配 revision。没有在此调用 moduleSummary、updateAdmission、moduleOutputFolderOptions、synchronizingModuleID 或 latestGitHubPublish 等隐含遍历的计算属性。

后台 actor 完成 summary、更新准入、首个同步模块查找、发布历史摘要、目录选项归并、URL 生成、图标缓存路径检查、module DTO 与 JSON 编码。后台不引用 AppModel 或 Observation 对象。core 原始快照保存同 revision 的 activity 输入；即使编码期间模型继续变化，full 中的模块和 activity 仍来自这次捕获。前端继续分别比较 core 与 activity 版本。

模块投影缓存迁到后台，按 runtime/moduleRevision/settings/cacheDirectory 复用；summary 也按 runtime/moduleRevision/汇总开关缓存。纯 activity 更新不会重建模块 DTO。旧客户端兼容 full、多客户端共享编码、两个待发通道、公平发送与连接限额继续保留。后台逐模块投影检查取消；已经开始的同步 JSONEncoder 仍只能完成有限收尾后响应取消。

`GET /api/state` 使用同一不可变输入→后台准备/编码路径。`GET /api/activity` 的派生计算也在后台，并保留旧 flat 字段、增加 workspaceID/runtimeID/revision 供 fallback 轮询处理乱序。其他 API（例如 `/api/history`、发布预览、同步差异）仍可能使用同步 `.json`；本轮不宣称所有 API 的编码均已迁出 MainActor。

## 验证与正式运行

- Release build-for-testing 成功。
- WebManagementHTTPTests：**22 项执行，21 通过、1 opt-in benchmark 跳过、0 失败**，1.390 秒。包含先前分流/legacy/取消测试，以及不可变原始快照、捕获不触发 AppModel summary、polling flat 字段兼容和统一 revision 测试。
- 独立正式矩阵：**1 项通过、0 失败，56.242 秒**。默认 skip 与正式测量分开记录。
- 实际 Host：`/private/tmp/surge-relay-web-load-release/Build/Products/Release/Surge Relay.app/Contents/MacOS/Surge Relay`，启动前核验；PID 7729，完成后无 Host/xcodebuild/xctrace 残留。
- 继续使用同一 M4 / 10 核 / 16 GiB、macOS 27.2、Xcode 27.0、Release/testability/signing 配置、5000 模块、1 秒推送间隔及 8 流上限。1/3/10 请求分别接受 1/3/8，10 请求仍拒绝 2 个。

## 完整模块状态变化

| 请求 / 接受客户端 | 上版 MainActor DTO 最大值 | 本版 MainActor 输入捕获最大值 | 后台 prepare 最大值 | 后台 JSON 最大值 | 后台 prepare+JSON 最大值 | full 编码次数 |
|---|---:|---:|---:|---:|---:|---:|
| 1 / 1 | 140.81 ms | 0.105 ms | 143.22 ms | 74.78 ms | 218.00 ms | 3 |
| 3 / 3 | 140.41 ms | 0.117 ms | 140.55 ms | 72.05 ms | 212.17 ms | 3 |
| 10 / 8 | 141.75 ms | 0.116 ms | 142.05 ms | 72.22 ms | 212.80 ms | 3 |

表中的 prepare 与 JSON 都是等待后台 actor 的分段调用耗时，包含队列/执行器切换；两段各自的最大值不保证发生在同一次调用，不能简单相加当作精确总最大值。benchmark 分开调用生产准备与编码方法以计时；生产 SSE 在同一个 actor 调用中顺序执行两步。原 `encodeTotalSeconds/encodeMaxSeconds` 字段为完整状态的后台总等待时间，不是 MainActor 工作或纯 JSONEncoder CPU 时间；新增 preparation/jsonEncoding 字段区分两段。

首次连接时 MainActor 捕获最大 0.106 ms；所有矩阵阶段观测到的捕获最大为 0.117 ms。此处只测量 Web 快照捕获，没有包括原生 UI 自身的渲染、AppModel 其他观察者或后续模型修改发生的数组 copy-on-write 成本，不能据此宣称整应用所有主线程任务都小于 1 ms。

## activity、总成本与边界

| 请求 / 接受客户端 | activity CPU | activity full 编码 | activity 正文 | activity MainActor 捕获最大值 | module-state CPU | 场景最高采样 RSS |
|---|---:|---:|---:|---:|---:|---:|
| 1 / 1 | 0.81% | 0 | 2,351 B | 0.093 ms | 16.89% | 285.80 MiB |
| 3 / 3 | 0.79% | 0 | 7,053 B | 0.092 ms | 17.61% | 291.00 MiB |
| 10 / 8 | 0.79% | 0 | 18,808 B | 0.084 ms | 20.10% | 328.67 MiB |

activity 窗口仍为 4 次共享小事件编码、0 full 编码/正文；8 流正文相对原完整状态协议的 222 MiB 仍减少约 99.992%。module-state 窗口仍发送约 222 MiB full 正文，初始 full 仍约 9.25 MiB。这次解决的是准备工作占用 MainActor，不是降低完整快照的传输量或消除后台计算。

上一版场景 RSS 峰值为 277.08/277.41/324.19 MiB，本版为 285.80/291.00/328.67 MiB；不能把线程迁移表述为内存优化。保留不可变输入与缓存可能增加同时存活的数组；单次顺序场景又包含分配器复用，当前数据不能独立归因每一项增量。

idle、断开收尾、stop 收尾窗口均保持 0 新 full/activity 编码与状态正文；断开和 stop 的稳态窗口为 0 producer 回调与接收字节。重连/重启验证了最新 marker，旧端口关闭后无法成功响应。keep-alive 为 15 秒，短 idle 窗口不等于长期无任何网络流量。

CPU 为测试 Host 整个进程（含服务端、流式客户端与 driver），100% 表示一个逻辑核。RSS 每 100 ms 采样，稳态窗口约 2–4 秒；这是同环境单次对照，没有浏览器/原生动画 FPS、限速丢包 soak test 或真实下载转换负载。后续若进一步压缩 core 成本，应单独评估投影派生与文件信息缓存、完整帧频率和模块增量协议。

## 结果文件

- [本版原始数据](web-server-load-background-5000-2026-10-02.json)
- [本版源码/二进制/运行配置 SHA-256](web-server-load-background-build-release-tmp-2026-10-02.json)
- [上一版分流结果](WEB_SERVER_ACTIVITY_SPLIT.md)
- [最初完整协议基线](WEB_SERVER_LOAD_BASELINE.md)
- 正式结果：`/tmp/SurgeRelay-web-load-background-2026-10-02.xcresult`
- 定向测试：`/tmp/SurgeRelay-web-background-regression-2026-10-02.xcresult`

复现步骤仍采用基线文档的 `/tmp` Release 构建与专用 xctestrun，设置 opt-in benchmark、结果路径和预期 Host 环境变量，禁用并行并只运行 `WebManagementHTTPTests/testProductionWebLoadBenchmark`。正式测量期间停止其他构建、UI 自动化与性能采样。
