# Changelog

## 1.2.0

- 新增本地与 GitHub 发布清理清单，模块改名、删除或切换文件夹后会清理旧的已发布文件。
- 优化 GitHub 文件夹菜单刷新，避免 Web 管理状态轮询频繁访问 GitHub API。
- 将 fork 构建的 Sparkle 更新源切换到 `junchan0412/SurgeRelay-macOS`。
- 完善模块文件夹与 `category` 的测试覆盖和文档说明。
- 新增 GitHub Actions 打包流程，可为 Release 上传 ad-hoc 签名的 `.app.zip` 安装包。

说明：Release 安装包为 ad-hoc 签名 zip，未做 Developer ID 公证。签名 DMG 与 Sparkle appcast 需要在具备完整 Xcode、签名和 Sparkle 私钥的环境中单独生成。

## 1.1.0

- 新增 Sparkle 自动更新与“检查更新…”入口。
- 修复移动端 Web 首页横向滑动、编辑弹窗动画和拷贝反馈。
- 移除 Web 端诊断入口。
- 改进模块同步、发布稳定性与 Web 管理体验。
