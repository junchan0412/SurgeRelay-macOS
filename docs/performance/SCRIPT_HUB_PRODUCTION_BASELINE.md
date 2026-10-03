# 生产 Script-Hub 脚本受控九格（2026-10-03）

这是对先前固定 helper transform 基准的补充：实际执行缓存中的生产 `Rewrite-Parser.js` 与 `script-converter.js`，使用 QX/Loon 代表输入。8 模块×1轮 smoke 的 off/on 均通过，再顺序执行 24 模块×5轮正式 off/on，每格另有1轮预热、最多4个并发作业。没有修改产品代码、网络策略或真实工作区。

## 输入与隔离边界

- QX：1500条 `url reject` 重写与 hostname，64,917字节；验证生成1500条 Surge `- reject` 规则。
- Loon：1500条302重写与MITM，104,345字节；验证生成1500条 Surge 302规则。
- native：原生 Surge规则输入51,411字节。
- helper路径与mixed路径交替使用两种输入；mixed保持50% native / 50% helper。缓存hit不启动helper，缓存正文为原harness的有效Surge fixture；该格不代表再次执行生产parser。
- 来源正文由driver经过真实loopback HTTP获取，随后测试prelude仅允许该精确来源URL，将已下载字节交给生产parser；生产JS原始字节原样拼接执行。**生产helper网络bridge在本测试中被替代，私网阻断没有放宽；不是联网端到端、ScriptHubClient脚本资产物化或完整AppModel更新验收。**
- 两份脚本来自已有ScriptHubEngine缓存，仅记录脚本内容与hash，不读取或复制私人配置。上游commit未独立确认，版本身份以manifest中的完整SHA-256为准。原JS快照当时位于 `/tmp/surge-relay-production-script-fixture/`，该临时目录已按用户要求于2026-10-03清理；manifest、产物及原始结果保留在本报告目录。重新测量须重新准备脚本并核对manifest中的相同hash。

## 正式结果

| 路径 | 缓存场景 | off 批次中位数 ms | on 批次中位数 ms | 差异 | on 模块p95 ms | on合计RSS峰值 MiB |
|---|---|---:|---:|---:|---:|---:|
| native | hit | 8.91 | 9.19 | +3.15% | 1.76 | 14.7 |
| native | invalidated | 15.66 | 16.13 | +2.99% | 3.16 | 18.4 |
| native | partial | 14.72 | 14.90 | +1.22% | 3.21 | 20.0 |
| helper | hit | 9.29 | 9.41 | +1.35% | 1.84 | 21.1 |
| helper | invalidated | 496.60 | 489.20 | -1.49% | 101.15 | 83.7 |
| helper | partial | 420.09 | 437.59 | +4.16% | 103.66 | 84.8 |
| mixed | hit | 10.17 | 10.22 | +0.44% | 2.02 | 26.8 |
| mixed | invalidated | 282.98 | 280.87 | -0.75% | 94.10 | 91.6 |
| mixed | partial | 233.64 | 251.77 | +7.76% | 95.90 | 77.3 |

本组开启指标的批次中位数变化为 **-1.49%～+7.76%**，均在原10%开销预算内。每格仅5轮，不是稳定置信区间；负值属于波动，不能解释为指标提升性能。各格式输入大小不同，不能用路径之间耗时直接比较转换算法效率。

每格正式HTTP请求120次；全helper失效格执行120次真实生产parser，mixed失效格60次。partial格每5个来源一个503，正式25次503中15次有缓存回退、10次无缓存失败；helper部分失败格执行95次，mixed执行50次。结果计数由harness断言核验。代表产物另外核查了完整1500条规则，而不只是成功退出。

CPU计数包含driver与已回收helper、采样开销；RSS是每100ms采样的进程树合计，不等同应用footprint且可能漏掉短峰值。真实磁盘缓存/本地输出写入继续参与计时，未访问GitHub发布目标。完成后无该harness/helper残留进程。

## 证据与复现

- [正式 off](script-hub-production-2026-10-03/off.json)、[正式 on](script-hub-production-2026-10-03/on.json)
- [来源、脚本/二进制/源码/产物哈希](script-hub-production-2026-10-03/manifest.json)
- [QX代表产物](script-hub-production-2026-10-03/validated-qx-0.sgmodule)、[Loon代表产物](script-hub-production-2026-10-03/validated-loon-2.sgmodule)
- [harness源码](script-hub-production-2026-10-03/benchmark_production_scripts.swift)、[运行脚本](script-hub-production-2026-10-03/run.sh)

本次临时目录为 `/tmp/surge-relay-production-script-fixture`（已清理，见[清理记录](development-cleanup-2026-10-03.json)）。复现前需要重新准备该目录内同hash生产脚本及fixture，先执行 `zsh run.sh 8 1`，再用同一编译产物分别运行 `benchmark worker off.json 24 5 off` 与 `benchmark worker on.json 24 5 on`。运行前停止其他编译、UI与性能采样；源码/脚本变化后不能复用本次结果。
