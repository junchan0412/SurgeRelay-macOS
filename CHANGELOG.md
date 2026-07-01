# Changelog

## 1.2.4

- 新增 `script/verify_release_assets.sh`，自动校验 Release 产物的 sha256、App 版本号、构建号、通用架构、ad-hoc 签名、pkg payload、postinstall 隔离属性清理脚本与 Sparkle EdDSA 签名。
- `script/build_release_assets.sh` 在生成 `.app.zip`、`.pkg`、校验和与 Sparkle 签名后会自动执行发布产物校验。
- Release 构建脚本支持通过 `SPARKLE_ED_KEY` 环境变量注入 Sparkle 私钥，便于 GitHub Actions 等 CI 环境生成签名元数据。
- Release 构建脚本会在调用 Sparkle 签名前预检私钥来源，避免 Keychain 私钥缺失时长时间卡住；无私钥的预览构建需显式设置 `SKIP_SPARKLE_SIGNING=1 REQUIRE_SPARKLE_SIGNATURES=0`。
- GitHub Actions 发布打包流程改为复用本地 Release 脚本，生成 `.app.zip`、`.pkg` 与 sha256 校验文件。
- 发布 appcast 前可使用同一脚本加 `--appcast appcast.xml` 校验最新 Sparkle 条目的版本号、构建号、下载地址、包大小和 EdDSA 签名是否与实际 `.pkg` 一致。

## 1.2.3

- Web 管理新增访问令牌，所有 `/api/*` 接口与实时事件流都需要通过令牌验证。
- Web 管理默认仅允许本机访问；局域网访问需要在设置中显式开启。
- Web 管理链接与二维码会自动携带访问令牌，浏览器会保存到当前会话并从地址栏移除。
- 设置页新增“允许局域网访问”“拷贝访问地址”“重置令牌”，诊断报告记录远程访问开关但不包含令牌。
- 新增 Web 管理访问控制回归测试，覆盖本机、远程、缺失令牌和错误令牌场景。

## 1.2.2

- GitHub Token 改为保存到 macOS 系统钥匙串，避免继续写入 iCloud 同步配置文件。
- 启动时会自动迁移旧版 `settings.json` 中的 GitHub Token；迁移成功后同步配置中的旧字段会被清空。
- 如果钥匙串暂时不可用，App 会暂时沿用旧配置中的 Token，避免升级后丢失凭据。
- 设置页更新 GitHub Token 保存提示，并补充钥匙串读写回归测试。

## 1.2.1

- 新增“扫描本地模块”：递归扫描本地模块根目录下已有 `.sgmodule`，读取 `#!name` 与 `#!category`，并按原文件夹纳入 Surge Relay 管理。
- 支持本地 `file://` Surge 模块来源，可和远程来源一样参与启用、排序、编辑、汇总和发布。
- 输出文件名唯一性改为按“文件夹 + 文件名”判断，不同分类文件夹可保留相同文件名。
- Release 增加 `.pkg` 更新包；在无 Apple 开发者账号/未公证的情况下，更新安装后自动清除 App 隔离属性，避免每次更新都手动执行 `xattr -cr`。
- 1.2.1 起切换到新的 Sparkle EdDSA 公钥，为后续版本的 App 内更新签名做准备。

说明：从 1.2.0 更新到 1.2.1 请优先使用 `.pkg` 安装包。由于旧 Sparkle 公钥对应私钥不可用，1.2.0 无法通过可信 Sparkle 链路直接更新到 1.2.1。

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
