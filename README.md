# Surge Relay for macOS

Surge Relay 是一款用于集中管理、转换、编辑和发布 Surge 模块的 macOS 应用。它适合需要长期维护大量 `.sgmodule`、从 Loon/Quantumult X 等格式转换到 Surge、并把最终模块同步到本地 Surge 目录或 GitHub 仓库的用户。

本 fork 基于 [EEliberto/SurgeRelay-macOS](https://github.com/EEliberto/SurgeRelay-macOS) 修改，继续遵守 Apache License 2.0。转换能力基于 [Script-Hub](https://github.com/Script-Hub-Org) 的本地引擎。

## 当前能力

- 管理远程 HTTP/HTTPS 模块和本地 `file://` Surge 模块。
- 使用内置 Script-Hub 引擎转换 Quantumult X、Loon 和 Surge 模块。
- Script-Hub 上游默认固定到明确 commit；更新时会记录上游 revision 与脚本 SHA-256 hash。
- 为每个模块配置 Surge `category` 标签、输出文件名、输出文件夹、自定义展示图标和 Script-Hub 参数。
- 模块关系明确分为“模块存放位置”和“初始来源”：模块可以存放在本地或 GitHub；初始来源只由模块中的 `#SUBSCRIBED originalURL` 判定，缺失该记录即视为自写模块。
- 本地发布和 GitHub 发布可以同时开启；每个独立模块只写入自己选择的存放位置，本地根目录和 GitHub 模块目录共用一套相对输出路径逻辑。
- 本地发布根目录可配置，例如 iCloud Surge 目录；输出文件夹菜单会读取根目录下已有文件夹，也可以新建文件夹。
- GitHub 发布可发布到公开或私有仓库；公开仓库使用 Raw 地址，私有仓库需要配置公共转发地址。
- 总模块功能默认关闭，可在设置中手动开启；关闭后相关界面和“包含在总模块中”开关会隐藏，独立模块仍可转换和发布。
- 支持扫描本地根目录已有 `.sgmodule`，在确认预览后纳入管理。
- 支持 App 内 Web 管理、菜单栏操作、后台更新状态、任务取消、发布预览和删除确认。
- GitHub Token 与 Web 管理令牌保存到 macOS 钥匙串，并按需读取。
- 使用 Sparkle 2 App 内自动更新，Release 产物包含 `.app.zip` 和 `.pkg` 安装包。

## 安装与更新

请从 [GitHub Releases](https://github.com/junchan0412/SurgeRelay-macOS/releases) 下载最新版本。

首次安装可以下载 `Surge-Relay-版本.app.zip`，解压后把 `Surge Relay.app` 拖到 `/Applications`。由于本项目当前使用固定自签名证书签名，没有 Apple Developer ID 公证，首次从浏览器下载后 macOS 可能拦截打开。可以在 Finder 中右键打开，或执行一次：

```bash
xattr -dr com.apple.quarantine "/Applications/Surge Relay.app"
```

后续更新推荐在 App 内使用“查看更新…”。App 会通过 Sparkle 2 从 GitHub Releases 拉取更新包，并校验 Sparkle EdDSA 签名；由于不再由浏览器重新下载 App，通常不需要再次执行 `xattr`。

手动更新备用路径是下载 `Surge-Relay-版本.pkg` 并运行安装器。安装脚本会替换 `/Applications/Surge Relay.app`，并清理安装后 App bundle 的隔离属性。若 macOS 拦截未公证安装器，可在 Finder 中右键打开。

## 管理已有模块

这是当前 fork 最重要的安全边界：Surge Relay 要管理“你已有的原模块”，不是在根目录里制造同名副本。

扫描本地根目录时，App 会读取已有 `.sgmodule` 的 `#!name`、`#!category` 和 Script-Hub `#SUBSCRIBED` 来源记录，并在导入前展示预览。存在可解析的 `originalURL` 时，初始来源显示为对应的订阅格式，并恢复更新地址、Script-Hub 参数和模块标签；没有该记录时，模块归类为“自写模块”，更新地址保存为本地 `file://` 文件。原文件仍留在原位置，不会被复制到另一个同名位置。

已经从本地文件确认的 `#SUBSCRIBED` 初始来源会持久保存。后续从 `originalURL` 下载的上游原生模块即使不再包含该标记，也不会覆盖已经确认的来源。启动时 App 会优先用本地物理文件修复缺失的订阅元数据，并在登记文件名与磁盘文件名仅存在空格/连字符差异时纠正本地相对路径。

左侧模块列表按维护状态分组：

- “需要处理”：最近更新失败或本地编辑与上游更新发生冲突。
- “本地模块”：独立输出只写入本地模块根目录，初始来源可以是订阅来源或自写模块。
- “GitHub 模块”：独立输出只写入 GitHub 模块目录，初始来源可以是订阅来源或自写模块。
- “未分类”：`#SUBSCRIBED` 来源记录无效，需要检查模块内容或更新地址。

未开启“发布为独立模块”只表示转换结果保存在 App 缓存，不会产生第三种“远程模块”存放类型；模块仍按配置归入“本地模块”或“GitHub 模块”。

模块详情页和 Web 管理端都会优先显示“管理关系”：模块存放、初始来源、订阅原始地址、更新地址、登记地址和本地相对路径会按需分开展示。订阅模块从 `originalURL` 更新；如果用户最初登记的是另一个转换后地址，则额外显示为“登记地址”，避免把它误认为实际更新地址。判断独立文件写到哪里时看“模块存放”；判断它是否由订阅转换而来时看“初始来源”；判断后续从哪里读取内容时看“更新地址”或“订阅原始地址”。

本地发布时，如果某个本地 `file://` 模块的输出路径正好就是它自己的原始路径，App 会跳过写入，避免覆盖你正在使用的原模块。只有当你把模块发布到另一个文件名或另一个文件夹时，才会生成新的独立输出文件。

新生成的本地输出会写入 Surge Relay 管理标记。之后 App 只会自动覆盖或清理带有该标记的文件；遇到同名但没有标记的文件，会停止并报错。旧版本已经记录在发布清单中的输出可以在下一次写入时迁移为带标记文件，但删除旧文件仍需要走发布预览和确认流程。

如果你看到清理提示，请先看清楚“将删除的旧文件”列表。App 的目标是清理自己生成过的输出，而不是删除手动维护的原模块、`Surge.conf`、分类文件夹或 `assets` 目录。

自定义图标 URL 只用于 Surge Relay 桌面端和 Web 管理端展示。App 会读取来源中的 `#!icon` 作为展示回退，但转换后的 Surge 输出会移除 `#!icon` 元数据，不会把展示图标写入最终订阅文件。

## 发布目标

在设置的“发布”页可以分别开启“发布到本地”和“发布到 GitHub”。两者可以同时开启，但每个独立模块只进入自己选择的存放目标；总模块仍可同时发布到两个目标。工具栏的“发布全部”只提交 GitHub 模块与总模块；“多选 / 发布所选”也只允许选择 GitHub 独立模块，不会删除其他已发布文件。

开启本地发布后，需要配置本地模块根目录。常见路径类似：

```text
/Users/你的用户名/Library/Mobile Documents/iCloud~com~nssurge~inc
```

根目录可以直接存放模块，也可以建立分类文件夹，例如 `Ads`、`Rewrite/Media`、`Privacy`。添加或编辑模块时，“存放文件夹”菜单会显示根目录本身和已发现的子文件夹。选择根目录时，模块输出到根目录；选择文件夹时，模块输出到对应相对路径。

更改“配置储存目录”时，App 会迁移 `modules.json`、`settings.json`、Script-Hub 状态、更新历史、备份和手动覆盖内容。迁移成功后，旧目录中的 Surge Relay 配置文件会被清理；原始 `.sgmodule`、`Surge.conf` 和用户文件夹不会被删除。

### GitHub 发布

GitHub 发布需要配置 owner、repository、branch、目录和 Token。模块的输出文件夹逻辑与本地发布一致：根目录表示仓库配置的模块目录本身，子文件夹表示该目录下的相对路径。

公开仓库会直接生成 GitHub Raw 订阅地址。私有仓库需要配合 Cloudflare Worker 转发访问，相关 Worker 示例在 [Deployment/CloudflareWorker](./Deployment/CloudflareWorker)。

发布前可以生成预览，查看将新增、更新和删除的文件。若检测到需要删除旧路径，App 会要求确认；自动发布也会在需要删除时暂停等待确认。发布时会校验同一次提交中是否存在重复目标路径，并在更新 Git ref 后确认远端指向本次 commit。

## 总模块

总模块是可选功能，默认关闭。关闭时：

- 新增模块和扫描导入的模块默认不加入总模块。
- 桌面端、菜单栏和 Web 管理端会隐藏总模块入口和“包含在总模块中”开关。
- 独立模块仍可正常转换、预览、发布和自动发布。

开启后，可以为需要汇总的模块打开“包含在总模块中”。总模块文件名可在设置中配置，发布路径会和独立模块一起进入本地或 GitHub 发布流程。

## Web 管理

启用 Web 管理后，App 会在本机启动一个管理服务。默认仅监听本机地址；如果允许局域网访问，建议只在可信网络内使用。

Web 管理使用访问令牌建立 `HttpOnly` 会话 cookie，普通 API 和事件流禁用缓存，并对写操作做同源 `Origin` 或 `Referer` 校验。命令行或自动化客户端可以使用 `Authorization: Bearer <token>`；浏览器页面建立会话后不再把原始 token 写入 `sessionStorage`。访问令牌不会出现在诊断报告中。你可以在设置中查看 Web 服务状态、访问范围和令牌存储状态。

## 安全边界

Surge Relay 1.3.x 对 Web 管理、Script-Hub 引擎和 GitHub 发布做了安全收紧：

- Web 管理 HTTP 解析器会拒绝负数、非法或超过 4 MB 的 `Content-Length`，避免异常请求造成崩溃。
- Web 写操作需要同源 `Origin` / `Referer`，或显式 Bearer token；URL query token 只用于首次建立会话。
- Script-Hub 上游模块必须来自 `Script-Hub-Org/Script-Hub` 的固定 tag 或 commit，默认不再使用浮动 `main`。
- Script-Hub 模块里引用的脚本会被强制固定到同一个上游 revision，并记录脚本 SHA-256 hash；同一个固定 revision 的 hash 异常变化会被拒绝。
- JavaScriptCore HTTP bridge 只允许 `http` / `https`，会拦截本机、`.local`、内网、链路本地和保留地址，并把响应体限制为 20 MB。
- GitHub owner、repository 和 branch 会做结构化校验；模块目录仍沿用现有路径规范化逻辑。

当前工程仍保留 `NSAllowsArbitraryLoads=true` 和关闭 App Sandbox。原因是 Surge Relay 需要转换用户添加的任意 HTTP/HTTPS 模块来源，并写入用户选择的本地 Surge/iCloud 目录或执行 GitHub 发布；若开启沙盒，需要进一步引入 security-scoped bookmark 并迁移现有本地目录访问模型。发布预检会确认这些取舍仍在文档中明确记录；后续收敛路线见 [Release Hardening](./docs/RELEASE_HARDENING.md)。

## 钥匙串与权限

Surge Relay 只在需要时访问钥匙串：

- 保存和读取 GitHub Token。
- 保存和读取 Web 管理令牌。
- 用户手动触发钥匙串诊断时写入、读取并清理临时测试项。

为了减少更新后反复弹出钥匙串授权，Release 构建使用同一个固定自签名 Code Signing 证书，并保持 `CFBundleIdentifier` 为 `com.allenmiao.SurgeRelay`。从旧的未签名或 ad-hoc 版本升级到自签名版本时，首次访问钥匙串仍可能需要重新允许一次。

## 开发

本项目是 Xcode macOS App。推荐使用命令行构建，当前维护环境使用：

```bash
./script/build_and_run.sh
```

该入口默认执行 Debug 构建并启动 App；可使用 `--debug`、`--logs`、`--telemetry` 和 `--verify`。隔离 UI 验证使用：

```bash
SURGE_RELAY_RUN_UI_QA=1 ./script/build_and_run.sh --verify
```

需要直接调用 Xcode 时使用：

```bash
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
xcodebuild build \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation
```

测试构建：

```bash
node --check SurgeRelay/WebResources/web-logic.js
node --check SurgeRelay/WebResources/web-options.js
node --check SurgeRelay/WebResources/web-format.js
node --check SurgeRelay/WebResources/web-markup.js
node --check SurgeRelay/WebResources/web-api.js
node --check SurgeRelay/WebResources/web-state.js
node --check SurgeRelay/WebResources/web-editor.js
node --check SurgeRelay/WebResources/web-feedback.js
node --check SurgeRelay/WebResources/web-preview.js
node --check SurgeRelay/WebResources/app.js
node script/test_web_resources.mjs
node script/test_web_dom_resources.mjs
./script/check_release_configuration.sh

DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
xcodebuild build-for-testing \
  -project "Surge Relay.xcodeproj" \
  -scheme "Surge Relay" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedDataTest \
  -skipPackagePluginValidation
```

## 发布

正式发布需要 Sparkle EdDSA 私钥和固定自签名 Code Signing 证书。构建脚本会生成 `.app.zip`、`.pkg`、sha256 文件和 Sparkle 签名元数据，并可更新 `appcast.xml`。

发布前可先运行无需证书和 GitHub secret 的配置预检，确认版本号、Sparkle 配置、Web 资源语法和行为/DOM 测试、appcast、entitlement、发布脚本和 GitHub Actions 入口保持一致：

```bash
VERSION=1.3.18 BUILD=67 ./script/check_release_configuration.sh
```

```bash
REQUIRE_SPARKLE_SIGNATURES=1 \
REQUIRE_STABLE_CODESIGN=1 \
VERIFY_APPCAST=1 \
UPDATE_APPCAST=1 \
DEVELOPER_DIR="/Volumes/TR 5000/macOS/Applications/Xcode-beta.app/Contents/Developer" \
./script/build_release_assets.sh
```

本地验证会检查版本号、构建号、签名身份、Sparkle 签名、动态库依赖、zip 元数据、pkg payload 和安装脚本。线上发布后可继续验证 GitHub Release 资产：

```bash
REQUIRE_SPARKLE_SIGNATURES=1 \
EXPECT_ADHOC_SIGNATURE=0 \
EXPECTED_CODESIGN_AUTHORITY="Surge Relay Self-Signed Code Signing" \
./script/verify_github_release_assets.sh \
  --repo junchan0412/SurgeRelay-macOS \
  --tag v1.3.18
```

当前已完成工作、待完成工作和发布核对入口见 [DEVELOPMENT_STATUS.md](./DEVELOPMENT_STATUS.md)。

## 开源协议

本 fork 继续遵守原项目 Apache License 2.0。仓库中的第三方依赖、图标与资源声明见 [LICENSE](./LICENSE) 和 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
