# 生产 Web 服务 5000 模块负载基准（2026-10-02）

## 有效测量

本次使用生产 `WebManagementServer`、`WebEventPayloadCache`、`WebManagementAPI/StateBuilder` 和真实 `AppModel`，模型采用随机临时 `WorkspaceContext`，禁止旧工作区回退且不持久化初始化。没有修改产品 API、SSE 上限、推送间隔或 OS 权限。

- Release、`ENABLE_TESTABILITY=YES`、`CODE_SIGNING_ALLOWED=NO`，Apple M4 / 10 核 / 16 GiB，macOS 27.2（26B5091g）、Xcode 27.0（27A266a）。
- 实际执行路径已在测试启动时核验：`/private/tmp/surge-relay-web-load-release/Build/Products/Release/Surge Relay.app/Contents/MacOS/Surge Relay`；测试 bundle 也来自该 `/tmp` 构建。
- PID 4936，执行 1 个 opt-in benchmark，0 failures，测试方法耗时 56.001 秒；测量后无测试 Host、xcodebuild 或 xctrace 残留。
- 请求 1、3、10 个客户端，保持生产默认 1 秒事件循环与 8 个 SSE 上限。10 客户端时确实接受 8 个、HTTP 503 拒绝 2 个，没有悄悄提高限额。
- 客户端为真实 TCP/SSE 流式接收器，不保留完整历史帧，不执行浏览器 DOM/JS 解析或被拒客户端的自动重试。5000 模块 fixture 不绑定到原生列表 UI。
- CPU/RSS 包含服务器、XCTest Host 和测量/客户端 driver；CPU 的 100% 表示一个逻辑核心，不是整机 10 核的 100%。RSS 每 100 ms 采样，可能漏掉更短峰值。

## 主要结果

activity-only 阶段只改变进度与状态文本，modules 内容保持不变。module-state 阶段按约 4 Hz 改变真实模块状态；实际每个窗口记录 15–16 次修改，未执行真正的下载或转换任务。

| 请求客户端 | 接受 / 拒绝 | idle CPU | activity-only CPU | module-state CPU | activity窗口完整JSON正文 MiB | activity正文 MiB/s | 该场景最高采样RSS MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 / 0 | 0.63% | 14.61% | 21.59% | 27.75 | 6.85 | 273.5 |
| 3 | 3 / 0 | 0.61% | 15.30% | 21.22% | 83.25 | 20.75 | 283.1 |
| 10 | 8 / 2 | 0.61% | 18.36% | 24.48% | 222.00 | 54.42 | 330.0 |

每个完整状态帧约 **9.25 MiB（初始 9,698,940 字节）**。仅 activity 变化的约 4 秒窗口内，三组都只生成 3 次完整 JSON，但会向每个已接受客户端发送；8 个流合计收到 **222.00 MiB** 正文，约 **54.42 MiB/s**。

| 请求客户端 | 初次编码最大 ms | activity回调 / 实际编码 | activity编码最大 ms | module-state编码最大 ms | 停止连接观测 ms | 重启并收到完整状态 ms |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 185.25 | 3 / 3 | 133.15 | 228.97 | 26.87 | 205.00 |
| 3 | 171.45 | 3 / 3 | 130.19 | 222.35 | 26.82 | 205.30 |
| 10 | 167.84 | 3 / 3 | 131.09 | 225.35 | 26.84 | 237.43 |

停止连接的约 27 ms 包含测试端 25 ms 检查周期，不能当成精确到毫秒的内核关闭延迟。编码耗时是实际 `WebManagementAPI.eventPayload` 执行时间；当前在 MainActor 上执行，activity-only 的 130–133 ms 与模块状态更新时的 222–229 ms 都明显超过单帧预算，但本测试没有测浏览器或原生界面的真实帧率。

## 空闲与生命周期验收

- 每个约 3.1 秒 idle 窗口均有 **3 次缓存回调、0 次 JSON 编码、0 个新状态帧、0 状态正文**，说明共享 producer 与惰性编码缓存正常工作，没有变成每客户端编码。
- 模拟隐藏关闭所有 SSE，等待 1.1 秒收尾后，在约 2.1 秒窗口内均为 **0 回调、0 编码、0 接收字节**；普通 HTTP 仍可访问。
- 隐藏期间改变状态，重连后每个接受的客户端都匹配到最新状态 marker。
- `stop()` 后连接结束、监听端口消失，原端口请求无法得到成功响应。收尾后的 stopped 窗口均为 **0 回调、0 编码、0 接收字节**。
- 重启后 1/3/8 个客户端均收到最新完整状态，10 请求仍为 8 接受 / 2 拒绝。
- idle 窗口短于生产 15 秒 keep-alive 周期；结果不能推导为长期完全零网络流量。keep-alive 注释不属于状态 JSON 正文。
- 场景在同一个 Host 顺序执行，模型为重启保留且内存分配器可复用/保留页面；关闭后的 RSS 不立即下降不能单独判作泄漏。

## 结论与下一步

数据支持把 **低频 modules 与高频 activity 分流**：仅几个 activity 字段变化仍反复传输 9.25 MiB 未变化的模块投影，网络负担和 MainActor 编码成本都已经测到。首选保留 `/api/state` 完整初始/重连快照，复用现有 activity 数据结构发送小事件，再按模块 revision 或批次完成发送模块状态。

纯 activity 分流不能完全解决 module-state 阶段的全量投影成本；后续可以比较低频合并模块快照或按 ID 的状态增量，但应另行设计与复跑基准。**本轮没有凭数据结果直接修改协议或推倒服务器架构。** 当前的共享编码缓存、8 流限额、断开与关闭机制通过了本次验收。

这是单次顺序场景实验，每个稳态窗口约 2–4 秒，不是长期 soak test，也不是完整浏览器端到端测量。网络正文和事件计数可直接核对；CPU/RSS 比较还包含 driver、Host 和分配器历史。

## 基线与复现

- [有效原始数据](web-server-load-5000-2026-10-02.json)
- [有效构建与源码/二进制 SHA-256](web-server-load-build-baseline-release-tmp-2026-10-02.json)
- [先前 Release/Documents 路径启动环境失败](web-server-load-release-environment-failure-2026-10-02.json)
- [先前构建基线](web-server-load-build-baseline-release-documents-2026-10-02.json)

先前尝试在 dyld 打开依赖时等待 sandboxd approval，未进入 Swift、AppModel 或 benchmark；它不是服务负载失败。将构建产物与运行时结果放入 `/tmp` 后，同 Release 配置成功运行。路径/环境相关性得到支持，但具体被阻塞文件没有确认，因此不把路径差异当成已完全证明的根因。

默认全量测试会跳过 `WebManagementHTTPTests.testProductionWebLoadBenchmark`。正式运行应先单独 `build-for-testing`，再在静默窗口执行 `test-without-building`；不可把默认 skip 当作已完成负载验收。

构建命令：

```sh
xcodebuild -project 'Surge Relay.xcodeproj' -scheme 'Surge Relay' \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/surge-relay-web-load-release \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES build-for-testing
```

复制生成的 `.xctestrun` 到同一 Products 目录；只在复制件中设置：

- `OnlyTestIdentifiers = ["WebManagementHTTPTests/testProductionWebLoadBenchmark"]`
- `ParallelizationEnabled = false`
- `EnvironmentVariables.SURGE_RELAY_UI_QA = "1"`
- `EnvironmentVariables.SURGE_RELAY_WEB_LOAD_BENCHMARK = "1"`
- `EnvironmentVariables.SURGE_RELAY_WEB_LOAD_OUTPUT = "/tmp/your-web-load-result.json"`
- `EnvironmentVariables.SURGE_RELAY_WEB_LOAD_EXPECTED_HOST` 为本次 `/tmp` App 内实际 executable 路径。

然后单独运行：

```sh
xcodebuild test-without-building \
  -xctestrun /tmp/surge-relay-web-load-release/Build/Products/WebLoadBenchmark.xctestrun \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  '-only-testing:Surge RelayTests/WebManagementHTTPTests/testProductionWebLoadBenchmark'
```

成功结果同时作为 `production-web-5000-module-load` JSON attachment 保留在 xcresult。运行时数据先写 `/tmp`，之后再复制到报告目录；不要求测试 App 获取 Documents 权限。
