# Surge Relay 优化清单

本清单由 `docs/project-status-report/report.html` 的审计结论整理，用于约束 `1.4.1` 的优化与发布范围。

## 1.4.1 发布范围

| 优先级 | 优化项 | 状态 | 验证依据 |
| --- | --- | --- | --- |
| P0 | 消除网络 mock 对系统 DNS、Fake-IP、VPN 和企业网络的依赖 | 已完成 | `Surge Relay` scheme 273 / 273 通过 |
| P0 | 将 `DEVELOPMENT_STATUS.md` 改为自动生成的当前状态入口 | 已完成 | `node script/generate_project_status.mjs --check` 通过 |
| P0 | 在 release preflight 中检查状态页新鲜度 | 已完成 | `script/check_release_configuration.sh` 覆盖生成状态检查 |
| P1 | 同步 README、开发指南、上游同步和 Cloudflare 部署说明 | 已完成 | 文档使用当前发布模型、参数化版本示例和中性 Worker 占位符 |
| P1 | 为设置、模块编辑、详情页和 Web 搜索补自动化入口 | 已完成 | 独立 UI scheme `build-for-testing` 通过；Web DOM tests 通过 |
| P1 | 将 UI tests 与常规单元测试隔离 | 已完成 | 新增 `SurgeRelayUITests` target 与 `Surge Relay UI Tests` scheme |
| P2 | 缩小 `ModuleSidebarView.swift` 的认知负荷 | 已完成 | 筛选栏抽取后由 655 行降至 485 行 |
| P2 | 固化当前 release hardening 决策 | 已完成 | README、SECURITY 与 `RELEASE_HARDENING.md` 明确兼容性优先策略 |

## 发布门禁

- [x] 版本、build、CHANGELOG、Xcode 工程和 appcast 一致。
- [x] `git diff --check`、状态页检查、Web tests、Web DOM tests 和 release preflight 通过。
- [x] 常规 Xcode 测试全量通过。
- [x] Release configuration 构建成功。
- [x] `.app.zip` 与 `.pkg` 中的 App 使用固定自签名证书签名并通过 bundle 校验。
- [x] `.app.zip` 与 `.pkg` 生成 SHA-256 和 Sparkle EdDSA metadata。
- [ ] Git tag、GitHub Release、线上 assets 与 appcast 完成核验。

## 已知限制

- UI test target 与测试代码可以编译链接，但当前机器在执行测试代码前出现 `Timed out while enabling automation mode`。实际 UI assertions 需要在允许 Xcode UI automation 的 macOS 桌面会话中补跑。
- 当前没有 Apple Developer ID、notarization、ATS 收紧或 App Sandbox 迁移时间表。
- 正式迁移前必须先完成用户来源例外模型、security-scoped bookmarks、旧安装迁移和回归测试。

## 后续版本候选

- 根据真实变更频率与缺陷数据评估是否拆分 `ModuleCodeTextView.swift`。
- 根据解析规则变更频率与测试成本评估是否拆分 `ModuleMetadataParser.swift`。
- 在合适的 macOS runner 上把独立 UI scheme 纳入稳定的自动化执行环境。
- 发布流程具备 Apple Developer ID 后，再评估 notarization、stapling、ATS 和 Sandbox 迁移。
