# Web 真实浏览器验收与性能基线

本次运行加载工作区当前 `SurgeRelay/WebResources`，使用已安装的 Chrome 和现有 Playwright 1.62.1，无依赖安装。fixture 仅监听 `127.0.0.1` 随机端口，API 状态与模块正文只存在进程内存中；浏览器使用临时隔离 profile，并阻止访问 fixture 以外的地址。未启用用户的真实 Web 服务，未调用 GitHub 或 Surge。

## 环境与结果

Apple M4，10 核，16 GiB RAM；macOS 27.2；Chrome 154.0.8037.93 **headless**；Node v26.10.0。桌面 viewport 1280×900，移动 viewport 390×844。正式性能采样期间其他代理暂停编译及原生性能测试。

| 模块数 | 筛选至两次 rAF p95 | 同步 input 处理 p95 | 滚动帧间隔 p95 | Long task | JS heap used |
|---:|---:|---:|---:|---:|---:|
| 100 | 34.8 ms | 2.4 ms | 16.8 ms | 0 | 2.77 MiB |
| 1,000 | 34.7 ms | 11.6 ms | 16.7 ms | 0 | 3.04 MiB |
| 5,000 | 51.6 ms | 26.7 ms | 16.8 ms | 1，62 ms | 7.71 MiB |

每档使用新 browser context，完整加载并等待 600 ms 后采样。筛选在“命中一个模块”和“恢复全部模块”之间交替：4 次预热、30 个有效样本。时间从真实 DOM `input` 事件派发前开始，记录同步处理及两次 `requestAnimationFrame` 后时间。后者包含约两帧的等待，不能等同于纯计算耗时或用户点击的端到端延迟。Long tasks 覆盖预热、有效筛选和滚动阶段。

滚动阶段沿真实 `.module-navigation.scrollTop` 在 180 个 rAF 帧内由顶部推进到底部，记录相邻帧时间。三档均未出现超过 33.34 ms 的滚动采样帧。5,000 模块全部真实存在于 DOM 中；筛选同步处理已超过单个 60 Hz 帧预算，后续可优先优化大列表筛选与重新展示。

这些帧间隔来自 headless Chrome 的 rAF 调度，**不能证明有屏显示稳定 60 FPS，也不能推导 120 Hz 或 iPhone 上的手势流畅度**。JS heap 来自 Chromium `performance.memory`，不包含完整 DOM、GPU、浏览器进程 RSS。没有测量首次载入峰值；API 为本地内存 fixture，因此也不是后端吞吐或网络性能结果。

## 功能验收

当前成功验收 JSON 中没有页面 JavaScript error：

- 双目标编辑通过真实表单选择和点击提交，检查请求含 `storageTargets: [local, gitHub]` 与兼容的 `storageLocation: local`。
- 小文本通过 Playwright `fill` 输入成功。
- 5,700,016 UTF-8 bytes 的草稿经过真实 IndexedDB 保存、页面 reload、点击恢复后与原文完全相同。大文本采用 `value` 赋值加 `input` 事件布置，**仅验证持久化恢复，未声称大文件键入顺滑**。
- 服务器版本在编辑后改变时，条件写入被 fixture 返回 412 拒绝，草稿保留；“查看服务器版本”显示新文本，确认后的条件重试保存成功。
- 实际 `prefers-reduced-motion: reduce` 下，分组展开完成后没有运行中的 CSS/WAAPI 动画。
- 连续快速操作分组、高级区和弹层，最终展开状态、临时 height 清理与重新打开状态正确。
- 390 px 移动 viewport 无横向溢出。

真实验收发现并修复了一个模拟测试未覆盖的问题：减少动态效果的 CSS 原先仅匹配元素及 `::before` / `::after`，遗漏 `dialog::backdrop`，导致遮罩仍执行 220 ms 动画。现已将 `*::backdrop` 纳入规则，并加入回归断言。

早期探测中，向 textarea 直接 `fill` 5.7 MB 文本，以及随后从大文本状态执行 `fill`，出现过 30 秒工具超时。最终小文本真实输入通过，但这不足以排除大文本选择或编辑路径的性能问题；本次未将超时简单归因于产品或 Playwright，也未将程序赋值作为键入性能替代结果。

## 可复用运行方式

需要现有 Chrome 与 Playwright 包；脚本不会安装依赖。指定实际已有包的 `index.mjs`：

```sh
SURGE_RELAY_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs node script/measure_web_browser.mjs acceptance
SURGE_RELAY_PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs node script/measure_web_browser.mjs performance
```

参数可为 `acceptance`、`performance` 或 `all`。设置 `SURGE_RELAY_HEADED=1` 可运行有屏 Chrome，但结果应单独标注，不与本次 headless 数值混用。正式采样前应暂停编译、其他性能任务和重负载应用。

结果输出到 `docs/performance/web-browser-<phase>.json`；验收另输出 accessibility snapshot。JSON 保存了原始 30 个筛选样本、long task entries、浏览器环境和 viewport。`script/browser_fixture_server.mjs` 可由其他验证脚本复用，调用结束必须关闭 browser 与 fixture。
