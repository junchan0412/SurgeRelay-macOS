# Changelog

## 1.2.22

- App 内 GitHub Release 更新面板新增“安装建议”，会明确提示更新已有安装优先使用 `pkg`，安装器会清除隔离属性，后续无需手动运行 `xattr -cr`。
- 更新面板会区分首次安装可用的 `app.zip` 与更新用的 `pkg`，当 Release 缺少 `pkg` 时会给出注意提示。
- 更新面板补充当前发布资产的信任状态说明：App 为 ad-hoc 签名、`pkg` 未签名且未做 Developer ID 公证，减少下载安装前的信息落差。

## 1.2.21

- 钥匙串主动访问检查新增 `OSStatus` 错误码与修复建议，方便区分钥匙串未解锁、交互被系统禁止、签名权限不匹配或旧项目损坏等情况。
- 设置页“钥匙串”会在检查失败时显示错误码和下一步处理建议，减少排查 GitHub Token 或 Web 管理令牌保存失败时的来回猜测。
- 诊断报告同步导出钥匙串错误码与修复建议，仍不会导出任何 GitHub Token 或 Web 管理令牌内容。

## 1.2.20

- 设置页“钥匙串”新增主动访问检查，会写入、读取并清理一个临时诊断项，用于确认 GitHub Token 与 Web 管理令牌所需的系统钥匙串读写能力。
- 诊断报告新增钥匙串访问检查状态、结果说明和检查时间，仍不会导出任何 GitHub Token 或 Web 管理令牌内容。
- 修正钥匙串状态标签颜色，只有真正保存到系统钥匙串时显示为绿色；内存临时令牌或钥匙串不可用会显示为需要关注。

## 1.2.19

- pkg 更新包新增 `preinstall`，安装前会请求正在运行的 Surge Relay 退出，短暂等待后仍未退出时再兜底结束进程，降低运行中替换 App bundle 导致更新不完整的风险。
- Release 验证会检查 pkg `preinstall` 是否存在、是否可执行，并确认包含退出旧 App 的逻辑。
- `postinstall` 仍负责清理 `/Applications/Surge Relay.app` 的隔离属性，更新已有安装继续无需手动执行 `xattr -cr`。

## 1.2.18

- 新增 `script/verify_github_release_assets.sh`，可直接校验 GitHub Release 线上资产列表、下载后的 sha256 sidecar、GitHub API digest 和包内结构。
- GitHub Actions 打包工作流在上传 Release 资产后会自动运行线上校验，减少资产上传损坏、漏传或 digest 不一致的问题。
- 线上校验脚本会继续复用本地 Release 验证，覆盖 App 版本号、构建号、签名清单、动态库依赖、pkg payload 和 postinstall。

## 1.2.17

- App 内 GitHub Release 更新检查会下载 `.pkg.sha256` 与 `.app.zip.sha256` 小文件，并与 GitHub API 返回的资产 digest 比对。
- 更新面板的资产完整性状态细化为 sha256 匹配、不匹配、缺少 digest、缺少 sha256 或无法读取，下载前即可发现校验文件损坏或不一致。
- 补充 sha256 匹配和不匹配两类 Release API 回归测试，覆盖更新面板的完整性判断。

## 1.2.16

- App 内 GitHub Release 更新面板新增资产完整性区域，会显示 `.pkg` 与 `.app.zip` 的文件大小、GitHub digest 和对应 `.sha256` 文件状态。
- 更新面板会提示安装资产是否缺少 sha256 校验文件，便于在下载安装前发现 Release 资产不完整的问题。
- GitHub Release API 解码测试补充 `digest` 与 `.sha256` 配对覆盖，避免后续调整破坏更新面板的完整性信息。

## 1.2.15

- Release 验证新增主程序动态库依赖解析检查，会读取 `LC_RPATH` 与 `otool -L`，确认 `@rpath` 依赖能够解析到 App bundle 内或系统库路径。
- 发布包会明确验证 `@executable_path/../Frameworks` 运行时搜索路径，进一步覆盖 Sparkle framework 缺失或路径错误导致的启动即闪退问题。
- `.app.zip` 与 `.pkg` payload 会复用同一套依赖解析检查，确保两种安装资产里的 App bundle 都能通过动态链接前置验证。

## 1.2.14

- Release 验证新增嵌入代码签名清单检查，会确认 App、Sparkle framework、Updater 与 XPC 服务均为 ad-hoc 签名且没有混入其他 Team ID，避免安装后因动态库签名不一致而闪退。
- pkg 安装后的隔离属性清理脚本改为识别 installer 目标卷；发布验证会在临时安装根中实际执行 postinstall，确认 App bundle 与主程序的 quarantine 属性会被清理。
- `verify_release_assets.sh` 新增 `--launch-smoke-test` 可选参数，可从 `.app.zip` 解包后的 App 执行启动冒烟测试，用于本地发布前确认 Release 构建不会启动即退出。

## 1.2.13

- GitHub 发布在远端分支刚好被其他客户端更新时，会重新读取仓库 tree 并自动重试一次，减少非快进引用更新导致的发布失败。
- 发布历史和状态栏会标记已处理远端更新，便于确认本次发布是否经历过重试。
- 设置页本地模式新增根目录诊断，可查看目录是否存在、是否可写、已发现文件夹数量和 `.sgmodule` 数量；诊断报告也会导出这些信息。

## 1.2.12

- “查看更新…”改为 App 内 GitHub Release 检查面板，会显示当前版本、最新版本、发布说明和可安装资产。
- 更新面板优先提供 `.pkg` 下载入口，方便更新已有安装并通过安装脚本清除隔离属性；同时保留 `.app.zip` 与 Release 页面入口。
- 新增 Release 版本比较和 GitHub Release API 解码测试，避免 `1.2.10` 这类多位版本号被错误排序。

## 1.2.11

- 设置页 Web 管理区域新增服务状态、访问范围和令牌存储状态，便于确认服务是否运行、是否开放局域网访问，以及 Web 管理令牌是否保存在系统钥匙串。
- Web 管理地址展示改为无令牌地址；打开、拷贝访问链接和二维码仍使用含令牌访问链接，减少截图或诊断时泄露访问令牌的风险。
- 诊断报告新增 Web 服务运行状态、访问模式、无令牌管理地址和 Web 令牌存储状态，继续不导出任何令牌内容。

## 1.2.10

- 菜单栏和应用菜单中的“查看更新…”改为直接打开 GitHub Releases 最新版本页，避免旧 Sparkle appcast 显示过期版本。
- App 启动时不再启动 Sparkle updater；在完成可签名 appcast 前，更新路径统一收敛到 GitHub Release 中的 `.pkg` 安装包。
- 文档同步说明当前更新策略：首次安装可用 `.app.zip`，更新已有安装优先使用 `.pkg`，无需重复手动执行 `xattr -cr`。

## 1.2.9

- 汇总模块详情新增 GitHub 发布预览，可在上传前查看新增/更新文件和将删除的旧文件。
- 自动 GitHub 发布如果检测到需要删除旧文件，会暂停并等待用户确认，避免误删移动或改名后的历史路径。
- 本地模式写入新模块时不再静默删除旧路径；如需清理旧文件，会在汇总模块详情显示待确认清理预览。
- “扫描本地模块”的导入预览新增“已跳过”列表，显示空文件、总模块文件、已纳入管理路径、重复来源等跳过原因。

## 1.2.8

- 设置页新增“安装与权限”诊断，显示 App 路径、签名状态、Gatekeeper 评估、隔离属性、Sparkle 自动检查状态和推荐更新方式。
- 设置页新增“钥匙串”诊断，说明 GitHub Token 与 Web 管理令牌的系统钥匙串账号和当前存储状态，诊断报告不会导出令牌内容。
- 诊断导出新增安装环境与钥匙串状态，便于排查首次安装打不开、更新后启动异常和钥匙串不可用问题。
- Sparkle 自动检查更新默认关闭；当前未完成最新 appcast 签名链路前，推荐继续使用 GitHub Release 中的 `.pkg` 更新包。

## 1.2.7

- 本地模式的存放文件夹菜单改为递归扫描本地模块根目录，支持显示并选择多级文件夹。
- “扫描本地模块”的导入预览支持在导入前编辑模块名称、Surge `category` 标签和目标存放文件夹。
- 本地模块导入会按最终目标文件夹检查输出路径冲突，必要时自动追加序号后缀，避免覆盖同一路径。
- 新增本地递归文件夹发现回归测试。

## 1.2.6

- GitHub 存放文件夹菜单改为通过递归 tree 快照发现目录，支持显示模块根目录下的多级文件夹。
- GitHub 发布流程复用同一份递归 tree 快照计算新增、更新和删除文件，减少逐文件 Contents API 查询。
- 当 GitHub 递归 tree 被截断时，发布流程会回退到逐文件 SHA 查询，避免超大仓库下误删或漏传。
- 递归目录发现会跳过 Surge Relay 生成脚本使用的内部 `assets` 目录。
- 补充 GitHub 递归目录发现和发布 diff 的回归测试。

## 1.2.5

- 模块编辑器新增“新建存放文件夹”，本地模式会在本地模块根目录下创建目录，GitHub 模式会保存为空文件夹选项并在后续发布模块时生成对应路径。
- 新增自定义存放文件夹配置，手动创建的文件夹会在重启后继续出现在模块存放文件夹菜单中。
- “扫描本地模块”改为后台扫描并先展示候选列表，显示模块名称、相对路径、分类和目标文件夹，用户确认勾选后再导入。
- 补充文件夹规范化、自定义文件夹解码和本地扫描候选标识的回归测试。

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
