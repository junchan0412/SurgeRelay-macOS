# Web activity 分流与后台编码复测（2026-10-02）

后续已完成完整 DTO 后台构造，当前实现及最新数据见 [后台快照复测](WEB_SERVER_BACKGROUND_SNAPSHOT.md)。本文保留为分流阶段的历史对照。

## 实现边界

本轮保留完整 state 快照，没有引入 module delta。新版前端通过 `/api/events?activity=1` 协商独立 activity 事件；不带该参数的旧客户端继续收到含实时 activity 的完整 state。仅存在旧客户端时，服务端才为 activity 更新生成兼容 full JSON，多个旧客户端共享一次编码。兼容 full 不发送给新版客户端。

MainActor 上分别观察 core（modules/settings/history/workspace）与 activity。纯进度、状态与阶段更新只捕获小 activity DTO，不重新扫描或编码完整模块列表。core 变更仍捕获完整 DTO。JSONEncoder 在独立 actor 中串行执行；GET `/api/state` 也先捕获 Sendable DTO，再在后台编码。

state 与 activity 携带 runtimeID/revision，同一 AppModel 的 HTTP 与 SSE 使用同一单调版本计数。前端分别判断 core 与 activity 版本，防止旧 full 中的 activity 覆盖较新进度，同时允许较新 core 正常应用。一次编码使用已经捕获的一致快照，不因编码期间变化而无限丢弃、重编。新连接先收 full state，再收最新 activity；每个连接仅一个正在发送的帧，其他更新合并到共享的最新 state/activity，两个通道交替发送以避免饥饿。

`stop()` 取消 producer、请求任务与所有连接，并清除待发帧。进入编码前和编码后检查取消；已经执行中的同步 JSONEncoder 不能在中途强制中断，可能存在一次有限的收尾工作。停止后的数据不再投递。

## 验证与测量方法

- Release `build-for-testing` 成功；WebManagementHTTPTests 定向执行 20 项：19 通过、1 个 opt-in benchmark 跳过、0 失败。新增测试覆盖独立版本、activity 不重建 core、legacy 实时 full、新连接 state→activity、HTTP/SSE 统一版本、预先取消编码与 stop 取消 producer。
- 正式 benchmark 独立执行 1 项、0 失败、55.885 秒。默认测试跳过不算正式负载验收。
- 同旧基线：5000 模块、真实 AppModel/WorkspaceContext、生产 Server/StateBuilder，1 秒推送间隔，1/3/10 个 TCP/SSE 客户端，保留 8 流上限。10 个请求仍为 8 接受、2 个 503。新版客户端均协商 `activity=1`。
- 同一 M4 / 10 核 / 16 GiB、macOS 27.2、Xcode 27.0，Release/testability/signing 配置不变。实际 Host 路径通过测试启动检查，PID 6866，运行后无 Host/xcodebuild/xctrace 残留。
- CPU 包含测试 Host、服务端、客户端和 driver，100% 表示一个逻辑核心。RSS 每 100 ms 采样，场景在同一进程顺序运行，不是长期泄漏测试。
- MainActor snapshot 耗时单独计时；background 时间是等待 encoder actor 返回的时间，包含 executor 排队/切换和编码，小 activity 编码可能与 full 编码计入同一次调用。它不是 JSONEncoder 的独立 profiler 时间。
- 客户端流式计数，不保留历史完整 JSON；不含浏览器 DOM/JS、原生列表渲染或真实下载/转换。activity 和 module-state 阶段仍分别按约 4 Hz 修改实际模型属性，每个稳态窗口约 2–4 秒。

## activity-only：消除重复 full

| 请求 / 接受客户端 | 旧 CPU | 新 CPU | 旧完整状态正文 | 新完整状态正文 | 新 activity 正文 | 新 activity 帧数 |
|---|---:|---:|---:|---:|---:|---:|
| 1 / 1 | 14.61% | 0.79% | 27.75 MiB | 0 | 2,351 B | 4 |
| 3 / 3 | 15.30% | 0.73% | 83.25 MiB | 0 | 7,053 B | 12 |
| 10 / 8 | 18.36% | 0.74% | 222.00 MiB | 0 | 18,808 B | 32 |

三组约 4.1 秒 activity 窗口均为 **0 次 full 编码、4 次共享 activity 编码**。8 个流的正文从 222 MiB 降为约 18.37 KiB（减少约 99.992%）；新窗口多发了一次小 activity 更新，因此不是以少推送一次换取结果。

| 请求客户端 | 旧 activity full 编码最大耗时（MainActor） | 新 activity snapshot 最大耗时（MainActor） | 新后台调用最大耗时 |
|---|---:|---:|---:|
| 1 | 133.15 ms | 0.149 ms | 0.233 ms |
| 3 | 130.19 ms | 0.138 ms | 0.281 ms |
| 10 | 131.09 ms | 0.136 ms | 0.246 ms |

activity-only 的主线程工作与传输量均明显降低。这里没有测量真实 UI 帧率，不将这些耗时换算成动画 FPS。

## core 更新仍有完整投影成本

| 请求客户端 | 旧 module-state CPU | 新 CPU | 新 full 编码次数 | 新 MainActor snapshot 最大值 | 新后台调用最大值 | 新场景最高采样 RSS |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 21.59% | 16.39% | 3 | 140.81 ms | 76.15 ms | 277.08 MiB |
| 3 | 21.22% | 17.12% | 3 | 140.41 ms | 73.74 ms | 277.41 MiB |
| 10 | 24.48% | 20.23% | 3 | 141.75 ms | 73.91 ms | 324.19 MiB |

初始完整 JSON 为 **9,699,004 B（约 9.25 MiB）**。真实模块状态变化仍会重建全量投影；8 流 module-state 窗口仍收到约 222 MiB full 正文。JSON 编码已经离开 MainActor，但 **140–142 ms 的 core DTO 构造仍在 MainActor**，是明确保留的后续优化点，不能宣称全面消除了大模块集合下的界面卡顿。

后续宜先分析 `moduleProjection` 的逐项派生、URL/文件信息访问成本与可缓存字段，再评估不可变输入的后台投影或小范围更新。module delta/批次协议应独立设计并保持兼容，不属于本轮成果。单次短窗口的 CPU/RSS 改善仅是本环境观察，不作为通用性能承诺。

## 生命周期

各组 idle 窗口均为 0 full 编码、0 activity 编码、0 状态正文；常规缓存回调仍存在。隐藏关闭所有流、等待 1.1 秒收尾后的窗口，以及 stop 收尾后的窗口，均为 0 回调、0 编码、0 收到字节。普通 HTTP 在没有 SSE 时仍可访问，旧监听端口关闭后无法成功响应，重连/重启都验证最新 marker。

stop 的连接结束观测约 25–27 ms，包含测试端 25 ms 检查周期，不能看成精确内核延迟。idle 窗口短于 15 秒 keep-alive 周期，不能推导为长期绝对零网络流量。当前验证包含真实 loopback 双通道顺序与旧客户端兼容；慢速网络的双通道公平性来自每连接一帧在途、两通道交替的实现约束，尚未完成独立限速/丢包 soak test。

## 结果文件

- [分流原始数据](web-server-load-split-5000-2026-10-02.json)
- [分流构建、源码与二进制 SHA-256](web-server-load-split-build-release-tmp-2026-10-02.json)
- [原协议基线报告](WEB_SERVER_LOAD_BASELINE.md)
- 正式结果 bundle：`/tmp/SurgeRelay-web-load-split-2026-10-02.xcresult`
- 定向回归 bundle：`/tmp/SurgeRelay-web-split-regression-2026-10-02.xcresult`

复现时沿用基线文档的 `/tmp` Release build-for-testing，再从新生成的 xctestrun 创建专用副本，设置 `SURGE_RELAY_UI_QA=1`、`SURGE_RELAY_WEB_LOAD_BENCHMARK=1`、`SURGE_RELAY_WEB_LOAD_OUTPUT` 为 `/tmp` 路径、`SURGE_RELAY_WEB_LOAD_EXPECTED_HOST` 为该构建真实 Host。仅选择 `WebManagementHTTPTests/testProductionWebLoadBenchmark`，禁用并行，在没有其他编译/UI/性能任务的窗口运行。
