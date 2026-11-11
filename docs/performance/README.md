# 性能与验收基线导航

这里保留 2026-10-02～04 的测量摘要、范围限制和复现方法。数值只对应报告记录的源码、fixture、构建和运行环境；当前版本的验收状态以 [当前项目报告](../CURRENT_PROJECT_REPORT.md) 为准。

| 摘要 | 测量范围 |
| --- | --- |
| [原生交互验收](NATIVE_UI_ACCEPTANCE.md) | 隔离 App 的实际窗口操作 |
| [原生 100 模块列表](NATIVE_LIST_ACCEPTANCE.md) | 更新中滚动、筛选与展开；保留原验收范围 |
| [原生编辑器组件矩阵](NATIVE_EDITOR_COMPONENT_MATRIX.md) | 100 KiB / 1 MiB / 5 MiB 组件操作与取消 |
| [Web 浏览器基线](WEB_BROWSER_BASELINE.md) | headless DOM、草稿恢复、筛选及滚动 |
| [Web 负载原始对照](WEB_SERVER_LOAD_BASELINE.md) | 优化前的生产 TCP/SSE 负载 |
| [Web activity 分流](WEB_SERVER_ACTIVITY_SPLIT.md) | 分流后的网络正文和编码成本 |
| [Web 后台快照](WEB_SERVER_BACKGROUND_SNAPSHOT.md) | 完整 DTO 后台构造后的复测 |
| [阶段指标基线](STAGE_METRICS_BASELINE.md) | 隔离下载、helper、缓存与本地输出 |
| [生产 Script-Hub 基线](SCRIPT_HUB_PRODUCTION_BASELINE.md) | 固定脚本 hash 下的受控 QX/Loon 转换 |

Web 服务三篇报告按“原始负载 → activity 分流 → 后台快照”阅读。较早报告中的待办可能已由后续阶段完成，不能直接照搬为当前缺陷。

原始 JSON、JSONL、日志、脚本夹具与产物位于 [历史证据](../archive/performance-raw-2026-10/)。新增测量先保留运行版本、App 路径、环境、样本量和 hash，再归档原始产物并更新摘要；脚本生成的新文件不应长期堆在本目录。
