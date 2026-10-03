# 分阶段指标受控基准（2026-10-02）

本次测量使用真实本机 HTTP、生产代码中的 SurgeModuleSanitizer、实际独立 JSC helper 进程、atomic 缓存和本地发布文件写入。它是隔离的阶段测试，不是公网 Script-Hub、完整 AppModel/UI 或 GitHub 发布的端到端性能结果。helper 执行固定字符串转换脚本，输入以字面量传入；没有放宽 HTTP bridge 的私网限制，也没有访问外网。

## 环境与口径

- Apple M4，arm64，10 核，16 GiB RAM；macOS 27.2（26B5091g）。
- Swift 6，独立 `-O` 编译的 driver/helper；非完整签名 Release.app。
- 每批 24 个模块，每个来源正文 51,411 字节，最多 4 个并发作业。
- 每格 1 轮预热、15 轮正式测量；表中批次时间为 15 轮中位数，模块 p95 基于每格 360 个作业。
- `hit` 返回 HTTP 304；`invalidated` 返回新正文；`partial` 每 5 个来源返回一次 HTTP 503，并交替保留/删除其回退缓存。
- RSS 为每 100 ms 采样的 driver 与 helper 后代进程 RSS 合计峰值，排除 ps 采样进程；可能漏掉更短的峰值，也可能重复计入共享页，不等同应用 footprint。
- CPU 为父进程及已回收子进程时间，包含采样与正式轮次之间的缓存准备；不是仅业务阶段 CPU。
- 字节数为内容大小，未计协议/TLS流量、文件系统或备份开销。关闭 metrics 的对照文件不报告虚构的字节数。

## 九格结果

| 处理路径 | 缓存状态 | metrics off 批次中位数 ms | metrics on 批次中位数 ms | 变化 | on 模块 p95 ms | on 采样 RSS MiB |
|---|---|---:|---:|---:|---:|---:|
| 原生处理 | 缓存命中 | 8.91 | 8.88 | -0.3% | 1.76 | 16.8 |
| 原生处理 | 内容失效 | 16.51 | 16.40 | -0.7% | 3.15 | 22.6 |
| 原生处理 | 部分失败 | 15.31 | 15.75 | +2.9% | 3.23 | 25.5 |
| 实际 helper | 缓存命中 | 10.04 | 10.52 | +4.8% | 1.99 | 27.6 |
| 实际 helper | 内容失效 | 236.24 | 238.26 | +0.9% | 40.86 | 52.2 |
| 实际 helper | 部分失败 | 195.15 | 200.28 | +2.6% | 41.04 | 49.9 |
| 50/50 混合 | 缓存命中 | 11.39 | 12.14 | +6.5% | 2.34 | 36.6 |
| 50/50 混合 | 内容失效 | 113.38 | 114.36 | +0.9% | 39.70 | 42.1 |
| 50/50 混合 | 部分失败 | 103.67 | 107.55 | +3.7% | 38.72 | 52.2 |

本机这组受控样本中，开启指标后的批次中位数变化为 -0.7%～+6.5%，均未超过预设 10% 开销预算。负值属于测量波动，不能解释为指标功能提升性能；该预算结果也不能外推为公网或完整应用保证。

缓存命中格均未启动 helper，下载正文为 0。每格正式测量实际收到 360 次本机 HTTP 请求。每个部分失败格包含 45 次缓存回退和 30 次缺缓存终止；其余来源继续处理。请求次数、回退/失败数量及下载字节总数均通过确定性检查。所有操作使用随机临时目录，没有触碰用户工作区或真实发布目标。

分阶段 p95、CPU、字节、helper 执行次数保存在原始 JSON：

- [metrics on](stage-metrics-on-2026-10-02.json)
- [metrics off](stage-metrics-off-2026-10-02.json)

原生处理/缓存命中主要是本机请求与文件操作；helper 格包含进程启动、IPC 和真实 JSC 执行。不同路径的倍数不能当作真实 Script-Hub 转换的加速或减速结论。真实公网下载与真实 GitHub 发布仍需可控公网 fixture、专用仓库和单独授权测量。

## 复现

在项目根目录执行，不需要第三方依赖；进行正式对照时应暂停编译、UI性能采样与其他重负载任务。

```sh
stage_bench_root="$(mktemp -d)"
xcrun swiftc -swift-version 6 -parse-as-library -O \
  SurgeRelay/Models/StageMetric.swift SurgeRelay/Models/RelayError.swift \
  SurgeRelay/Services/ScriptHubNetworkPolicy.swift SurgeRelay/Services/ScriptHubWorkerFiles.swift \
  SurgeRelay/Services/SourceRetryAfter.swift SurgeRelayScriptWorker/ScriptHubJavaScriptRuntime.swift \
  SurgeRelayScriptWorker/ScriptHubWorkerMain.swift -o "$stage_bench_root/worker"
xcrun swiftc -swift-version 6 -parse-as-library -O \
  SurgeRelay/Models/StageMetric.swift SurgeRelay/Models/RelayError.swift \
  SurgeRelay/Services/EmbeddedScriptHubEngine.swift SurgeRelay/Services/ScriptHubNetworkPolicy.swift \
  SurgeRelay/Services/ScriptHubWorkerFiles.swift SurgeRelay/Services/SourceRetryAfter.swift \
  SurgeRelay/Services/SurgeModuleSanitizer.swift script/benchmark_stage_metrics.swift \
  -o "$stage_bench_root/benchmark"
"$stage_bench_root/benchmark" "$stage_bench_root/worker" "$stage_bench_root/off.json" 24 15 off
"$stage_bench_root/benchmark" "$stage_bench_root/worker" "$stage_bench_root/on.json" 24 15 on
```

本次二进制 SHA-256：

- driver：`070234321e7022e506688f5caea50ed27e953ee0ce872c460a8dbe982c96b891`
- helper：`4794667363fe23a2b8a78616d0de7ef2ef3bbfa9925f1cb1c48bb2c256ae8eb0`
