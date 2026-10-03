# 原生输入定位与复测（2026-10-03）

环境：Mac mini / macOS 27.2（26B5091g），arm64 Release、Swift 6、-O。使用独立 bundle ID 与 QA 配置，发布、Web、自动任务关闭。CUA 对文本末尾逐次发送 x；不以 CUA 调用耗时作为输入延迟。最终三档使用同一 Release 进程 PID 14034、bundle ID 后缀 attribution20261003，每档正式输入40次真实按键。

测量边界为 CodeTextView.keyDown 入口到 NSApplication.didUpdateNotification，保留逐事件记录及同一更新周期内合并情况。它不测 GPU/像素呈现延迟，也不是 FPS。正文初始数据有 metadata 补全与前轮测试草稿，实际 UTF16 长度以 JSONL 为准。

| 版本 | 100 KiB p95 | 1 MiB p95 | 5 MiB p95 |
|---|---:|---:|---:|
| 最初 Release 基线 | 143.65 ms | 885.04 ms | 未采集 |
| native UTF8 转换 | 77.34 ms | 70.64 ms | 304.64 ms |
| 批量转换 + 快照缓存 | 未复测 | 未复测 | 137.12 ms |
| 最终同构建：共享 UTF16 扫描 + plain 自然尺寸 | **72.548875 ms** | **22.086375 ms** | **56.420999 ms** |

原始基线见 100KiB.jsonl、1MiB.jsonl 和 summary.json；第一轮修复见各 *-native-utf8.jsonl；第二轮见 5MiB-bulk-copy.jsonl。不同阶段不得混称最终同一构建验收。最终证据见 [100KiB-final.jsonl](100KiB-final.jsonl)、[1MiB-final.jsonl](1MiB-final.jsonl)、[5MiB-final.jsonl](5MiB-final.jsonl) 和 [final-summary.json](final-summary.json)。100KiB的40次事件合并为39个更新组，1MiB和5MiB均为40组；统计保留此差异，不虚构40个独立呈现样本。

## 已确认根因

原始1MiB样本逐事件相减得到 keyDown 到 didChange 入口 p95约4.77ms，之后到didUpdate约883.90ms。独立 attribution 构建增加阶段计时，定位显式尺寸约7ms、gutter重建约8ms，不能解释大部分延迟。随后真实输入期间的 sample 显示 SwiftUI AttributeGraph 和保存按钮状态比较进入 _stringCompareSlow / Unicode NFC normalizer / NSBigMutableString.characterAtIndex。AppKit foreign String 被反复逐字符读取，是主要瓶颈。

attribution-before.jsonl 混合了定位样本与 sample 运行期间样本，不能作为无探针基线。attribution-before-sample.txt 为独立120秒采样，包含空闲窗口；仅用于调用栈归因，不提供整体CPU占比。此前15秒采样未覆盖实际输入，已排除，未收录为证据。

把字符串转为连续native UTF8解决SwiftUI反复慢比较。随后对真实NSTextStorage/NSBigMutableString进行单独-O微基准，NSString批量UTF8转换将5MiB ASCII复制p95从83.11ms降为11.37ms；Unicode从112.80ms降为9.70ms，UTF8/UTF16精确校验通过。见 string-copy-benchmark.json；这是转换成本，不是输入延迟。

批量转换后缓存native快照，同一次修改的binding和updateNSView复用；输入、撤销、外部重载使缓存失效。最终24项编辑器定向测试通过；覆盖包含组合字符、中文、emoji ZWJ、CRLF、撤销、旧快照稳定性以及后续扫描/测量边界。原有Unicode语义不做规范化。

## 最终修复与有屏核验

修复链路为 AppKit foreign String → NSString 批量 native UTF8 快照及同次修改缓存 → 行索引/尺寸共用 UTF16 扫描 → plain 模式在零或未指定宽度下返回自然尺寸。减少重复全文处理，同时保留原始 Unicode 内容。

共享扫描复测曾确认另一布局边界：加载5MiB后SwiftUI提出width=0、bounds=0，原guard拒绝测量，滚动范围未建立；历史定位记录见 [zero-width-geometry.jsonl](zero-width-geometry.jsonl)。最终构建已修复plain自然尺寸，六位行号所需gutter也从44pt调整至56pt。

最终同一进程实际核验：

- 5MiB正文可点击、滚动至末尾并继续输入，正文和光标可见。
- 搜索 `fixture.invalid` 显示 `5000+`；点击下一项跳至第6行。
- 六位行号 `174767` 完整显示，截图已经核验。

这些交互与截图检查独立于计时，避免用didUpdate达标掩盖显示错误。三档最终p95均低于100ms，说明本次固定fixture末尾输入的AppKit更新预算通过；不证明GPU像素呈现、FPS、任意文本或设备都满足相同预算。

## 剩余验收

三档查找/正则、替换与Undo、Tab/换行、窄宽resize、查找取消及外部reload的组件矩阵已补齐，见 [Release组件矩阵](../NATIVE_EDITOR_COMPONENT_MATRIX.md)：独立1通过、0skip、0失败（7.839秒）。其每项仅一次组件耗时，不是输入p95或真实页签操作。100KiB病理正则观察到取消至worker完成5.568ms；1MiB/5MiB在取消前已完成，未取得取消延迟。全文layout次数为null，不能用三次显式测量调用代替。

仍需实际“详情↔预览”切换时的未保存草稿、选区、滚动与进行中查询组合；组件调用也不能描述为替换/Undo、Tab/换行、resize已完成真实窗口端到端操作。100/1000/5000模块更新中列表指标另行验收。

最新24项编辑器定向通过，随后最终全量集成 **514通过、1个opt-in生产Web负载benchmark跳过、0失败**。结果：`/tmp/surge-relay-goal-build/Logs/Test/Test-Surge Relay-2026.10.03_05-50-50-+0800.xcresult`，日志：`/tmp/surge-relay-final-integration-after-editor.log`。生产Web负载正式矩阵此前独立通过，本次skip不算重新测量。

此前508通过/2失败/1skip属于较早整合，夹具问题已修正；更早505通过/1skip发生在大HTTP正文补丁前。最终514项结果覆盖大HTTP和最终编辑器改动。发布preflight最后检查结果待补；本次输入与全量测试通过不将整个项目目标标记complete。
