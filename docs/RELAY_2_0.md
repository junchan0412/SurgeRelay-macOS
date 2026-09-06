# Surge Relay 2.0

2.0 重新组织模块更新、缓存提交、界面状态与发布构建，并将 macOS 和 Web 的主要操作统一为工作台、模块详情和活动记录。

## 性能与稳定性

| 环节 | 1.4.7 基线 | 2.0 |
| --- | --- | --- |
| 批量更新 | 逐个等待来源和转换 | 最多 4 个模块同时执行，按原顺序合并 |
| 原生来源变化 | 检查来源后再次下载转换 | 检查响应直接用于转换，同时保存 ETag / 内容 hash |
| 模块统计 | 读取缓存前拼接全量模块签名 | `moduleRevision` 驱动缓存失效 |
| 搜索与分组 | 主线程计算和反复 JSON 编码 | 后台计算、输入防抖与轻量搜索键 |
| 资源指纹 | 拼接全部脚本字节后计算 SHA-256 | 逐块计算，相同输入保持相同 hash |
| Web 进度 | 构建完整模块投影并读取图标 | 独立活动响应、模块投影缓存 |
| 转换缓存 | 分开替换内容与脚本资源 | 暂存完整快照后原子替换，失败保留上一版 |
| 取消更新 | 可能留下更新中状态 | 取消准备和执行任务，收尾状态、记录和持久化 |
| 发布构建 | 脚本覆盖为 Swift 5.9 / `-Onone` | Swift 6 / complete concurrency / `-O` / whole-module optimization |

受控流水线基准使用 24 个各等待 25 ms 的异步任务，在同一台 Mac 上比较串行和 4 并发执行：

| 模式 | 耗时 |
| --- | ---: |
| 串行 | 0.637441 秒 |
| 4 并发 | 0.157015 秒 |

该基准耗时降低约 75.4%，用于验证等待型任务的调度收益，不代表所有真实来源均能达到相同比例。Script-Hub 的 JavaScript 执行仍受引擎串行隔离约束，真实结果受网络、缓存、模块数量和转换成本影响。

正式 universal App zip 从 1.4.7 的 12,425,004 字节降至 2.0.0 的 10,060,053 字节，减少约 19.0%。签名、Sparkle、zip/pkg 启动与 appcast 校验均通过。

## 界面与操作

- 工作台汇总模块数量、待处理问题、发布去向与最近活动。macOS 统计入口可直接筛选模块；发布卡片可直达发布设置。
- 模块详情先展示来源、转换方式与输出，校验值、来源记录等技术信息按需展开。侧栏精简重复标签并保留原有分组、筛选和排序。
- 活动记录可查看更新、缓存回退和发布结果；macOS 支持筛选异常记录和跳转到模块。
- 设置采用分类侧栏；模块编辑先设置来源，再设置显示与输出，可选设置逐步展开。
- macOS 和 Web 内容页在切换模块时保留未保存草稿，保存响应不会覆盖保存期间继续输入的文本。草稿仅在当前运行会话中保留；退出 App 或刷新网页前仍应保存。
- Web 手机布局保留返回导航，隐藏面板使用 `inert` 隔离焦点。连接支持退避重连、隐藏页暂停和单次轮询；迟到响应不能覆盖较新状态。
- 新增 macOS 快捷键：`⌘1` 工作台、`⌘2` 活动记录。

视觉以 Apple 的 macOS 分栏、键盘和系统控件规范为基础，参考 Things 的列表层级：工具需要长时间阅读来源、路径和错误信息，因此采用中性内容表面、少量青绿色强调、清晰字重与 8/16/24/32 间距。macOS 工具栏和侧栏保留系统材质，普通内容区域减少重复模糊层；Web 使用对应的浅色 / 深色调色和状态色。

参考：[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)、[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Things](https://culturedcode.com/things/)。

## 验证与复现

- 330 项 Swift 测试在 Debug 与优化 Release 构建中均通过，无跳过。新增覆盖并发上限、取消和顺序、真实本地来源更新、网络大小限制、网络取消、缓存快照回滚、旧缓存兼容、下载复用、汇总失效、搜索参数变更与指纹兼容性。
- Web 行为与 DOM 测试通过。新增覆盖连接关闭后迟到回调、旧事件流、隐藏页暂停、请求不重叠、草稿切换、保存中继续编辑和 HTML 转义。
- 本机 Xcode UI runner 在连接框架前被系统终止，未执行 UI 断言；这两次运行不计为通过。界面另在隔离数据中通过原生 App 与真实浏览器操作检查。
- Web 资源改为完整目录打包，61 个资源与源码逐字节一致；包内 HTML 引用与脚本语法在 zip 和 pkg 两种产物中直接验证。
- 发布脚本校验 universal 架构、版本、嵌套签名、Sparkle EdDSA、SHA-256、zip/pkg 和 appcast；启动冒烟使用 QA 配置，避免触发用户真实自动发布。

```bash
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
node script/generate_project_status.mjs --check

xcodebuild test -project "Surge Relay.xcodeproj" -scheme "Surge Relay" \
  -destination "platform=macOS,arch=arm64" -skipPackagePluginValidation

REQUIRE_SPARKLE_SIGNATURES=1 REQUIRE_STABLE_CODESIGN=1 \
UPDATE_APPCAST=1 VERIFY_APPCAST=1 RUN_LAUNCH_SMOKE_TEST=1 \
./script/build_release_assets.sh

VERSION=2.0.0 BUILD=103 ./script/check_release_configuration.sh
```

优化 Release 的单元测试需要在 `xcodebuild test -configuration Release` 中加入 `ENABLE_TESTABILITY=YES ENABLE_DEBUG_DYLIB=NO`，以便测试访问内部接口；分发构建保持关闭 testability。

流水线基准在 `ModuleUpdatePipelineTests.testNetworkWaitBenchmark` 中，结果作为 `relay-network-benchmark` XCTest attachment 保存。UI QA 构建入口为 `SURGE_RELAY_RUN_UI_QA=1 ./script/build_and_run.sh --verify`；可加 `SURGE_RELAY_UI_QA_APPEARANCE=light` 或 `dark` 检查外观。

## 兼容边界

继续支持 macOS 26 及以上、Apple Silicon / Intel、现有配置和发布地址。旧组件缓存仍可读取；新快照位于本机缓存的 `Snapshots/<module-id>`，手动覆盖独立保存。凭据、GitHub 提交保护、本地受管文件边界与 Script-Hub 固定来源规则沿用现有设计。

分发继续使用原有固定自签名证书与 Sparkle 公钥；本版本未引入 Apple Developer ID 公证、Sandbox 或 ATS 策略迁移。相关安装说明与取舍见 [Release Hardening](RELEASE_HARDENING.md)。
