# Surge Relay (macOS)

<p align="center">
  <img width="160" alt="Surge Relay Icon" src="https://github.com/user-attachments/assets/3672fe08-3217-41f8-a592-9a4f473b216b" />
</p>

<p align="center">
  一款用于集中管理、转换、编辑和发布 Surge 模块的 macOS 应用程序。
</p>

<p align="center">
  基于 <a href="https://github.com/Script-Hub-Org">Script-Hub</a> 的本地转换能力构建。
</p>

Surge Relay 适合需要同时维护大量 Surge 模块的用户，尤其是经常通过 Script-Hub 将 Loon、Quantumult X 或其他代理工具格式转换为 Surge `.sgmodule` 的场景。

它的目标是将模块转换、地址维护、规则编辑和多设备同步集中到一台 Mac 上完成。你只需要在 Surge Relay 中维护上游地址和转换规则，最终生成的 Surge 模块会被发布到稳定的分发地址，所有设备只需要订阅这些固定 URL。

## Fork 修改说明

此 fork 基于原项目的 Apache License 2.0 许可进行修改，保留原许可证与第三方声明。当前 fork 增加了本地/GitHub 模块根目录、每个模块的 Surge `category` 标签、按根目录子文件夹保存独立转换模块、独立模块发布开关、扫描本地根目录已有 `.sgmodule` 纳入统一管理、发布前预览与删除确认、将 GitHub Token 存入系统钥匙串、Web 管理访问控制与运行状态诊断、本地根目录诊断、安装与权限诊断、最近崩溃报告摘要、GitHub Release 更新检查、更新安装建议、Release 资产完整性校验可见性，以及本地和线上发布产物自动校验、动态库依赖验证、版本一致性预检、安全启动冒烟、pkg payload 启动冒烟和安装后处理验证能力。

### v1.2.26 优化

- 设置页“安装与权限”新增最近 24 小时崩溃报告摘要，会显示最近的 `.crash`/`.ips` 文件名、时间和路径，方便排查安装后打开即退出。
- Release 验证脚本的 `--launch-smoke-test` 会分别验证 `app.zip` 解包后的 App 与 `pkg` payload 内的 App，覆盖两种安装资产的启动路径。
- 启动冒烟失败时会输出 quarantine、codesign、Gatekeeper、进程列表和最近崩溃报告路径，便于区分系统拦截、签名问题和真实运行时崩溃。

### v1.2.25 优化

- 添加/编辑模块时新增“发布为独立模块”开关，可以将“包含在总模块中”和“是否生成独立订阅文件”分开控制。
- 旧配置和新建模块默认继续发布独立模块，避免升级后意外删除既有稳定地址；关闭后，发布预览会列出需要清理的旧独立模块文件。
- Web 管理端同步支持该开关，并且发布资产会只保留仍被总模块或独立模块引用的转换脚本资源。

### v1.2.24 优化

- Release 验证脚本的 `--launch-smoke-test` 不再先结束所有正在运行的 Surge Relay，而是记录已有进程、启动 Release 包中的新实例，并只检查和关闭新实例。
- 本地或线上发布资产现在可以在用户已有 App 正在运行时执行启动冒烟验证，降低验证流程打断当前工作的风险。
- 启动冒烟失败时会明确报告“未启动新实例”或“新实例提前退出”，方便区分启动被系统阻止和启动后崩溃。

### v1.2.23 优化

- Release 打包脚本不再硬编码默认版本号，改为从 `project.yml` 读取 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，减少发布时漏改脚本版本的风险。
- 打包前会校验传入的 `VERSION`/`BUILD` 与项目版本一致，并确认 Xcode 工程中的版本号已同步；CI 或本地 tag 填错会在构建前失败。
- Release 校验调用会显式传入版本号与构建号，避免 `.app.zip`、`.pkg` 和项目元数据之间出现隐性漂移。

### v1.2.22 优化

- App 内 GitHub Release 更新面板新增“安装建议”，会明确提示更新已有安装优先使用 `pkg`，安装器会清除隔离属性，后续无需手动运行 `xattr -cr`。
- 更新面板会区分首次安装可用的 `app.zip` 与更新用的 `pkg`，当 Release 缺少 `pkg` 时会给出注意提示。
- 更新面板补充当前发布资产的信任状态说明：App 为 ad-hoc 签名、`pkg` 未签名且未做 Developer ID 公证，减少下载安装前的信息落差。

### v1.2.21 优化

- 钥匙串主动访问检查新增 `OSStatus` 错误码与修复建议，方便区分钥匙串未解锁、交互被系统禁止、签名权限不匹配或旧项目损坏等情况。
- 设置页“钥匙串”会在检查失败时显示错误码和下一步处理建议，减少排查 GitHub Token 或 Web 管理令牌保存失败时的来回猜测。
- 诊断报告同步导出钥匙串错误码与修复建议，仍不会导出任何 GitHub Token 或 Web 管理令牌内容。

### v1.2.20 优化

- 设置页“钥匙串”新增主动访问检查，会写入、读取并清理一个临时诊断项，用于确认 GitHub Token 与 Web 管理令牌所需的系统钥匙串读写能力。
- 诊断报告新增钥匙串访问检查状态、结果说明和检查时间，仍不会导出任何 GitHub Token 或 Web 管理令牌内容。
- 修正钥匙串状态标签颜色，只有真正保存到系统钥匙串时显示为绿色；内存临时令牌或钥匙串不可用会显示为需要关注。

### v1.2.19 优化

- pkg 更新包新增 `preinstall`，安装前会请求正在运行的 Surge Relay 退出，短暂等待后仍未退出时再兜底结束进程，降低运行中替换 App bundle 导致更新不完整的风险。
- Release 验证会检查 pkg `preinstall` 是否存在、是否可执行，并确认包含退出旧 App 的逻辑。
- `postinstall` 仍负责清理隔离属性，更新已有安装继续无需手动执行 `xattr -cr`。

### v1.2.18 优化

- 新增 `script/verify_github_release_assets.sh`，可校验 GitHub Release 线上资产列表、下载后的 sha256 sidecar、GitHub API digest 和包内结构。
- GitHub Actions 打包工作流上传 Release 资产后会自动运行线上校验，减少漏传、上传损坏或 digest 不一致的问题。
- 线上校验会复用本地 Release 验证，继续覆盖 App 版本号、构建号、签名清单、动态库依赖、pkg payload 和 postinstall。

### v1.2.17 优化

- App 内 GitHub Release 更新检查会下载 `.pkg.sha256` 与 `.app.zip.sha256` 小文件，并与 GitHub API 返回的资产 digest 比对。
- 更新面板的资产完整性状态会区分 sha256 匹配、不匹配、缺少 digest、缺少 sha256 或无法读取。
- 补充 sha256 匹配和不匹配两类 Release API 回归测试。

### v1.2.16 优化

- App 内 GitHub Release 更新面板新增资产完整性区域，显示 `.pkg` 与 `.app.zip` 的文件大小、GitHub digest 和对应 `.sha256` 文件状态。
- 更新面板会提示安装资产是否缺少 sha256 校验文件，下载安装前更容易发现 Release 资产不完整。
- GitHub Release API 解码测试补充 `digest` 与 `.sha256` 配对覆盖。

### v1.2.15 优化

- Release 验证会读取主程序的 `LC_RPATH` 与 `otool -L`，确认 `@rpath` 依赖能解析到 App bundle 内或系统库路径。
- 发布包会检查 `@executable_path/../Frameworks` 运行时搜索路径，覆盖 Sparkle framework 缺失或路径错误导致的启动即闪退风险。
- `.app.zip` 和 `.pkg` payload 都会执行同一套动态链接前置验证。

### v1.2.14 优化

- Release 验证会检查 App、Sparkle framework、Updater 与 XPC 服务的签名清单，确保发布包里不会混入不同 Team ID 的嵌入代码。
- `.pkg` 的 postinstall 会按 installer 目标卷清理 `Surge Relay.app` 的隔离属性；发布验证会在临时安装根中实际执行脚本，确认更新安装后无需手动 `xattr -cr`。
- `verify_release_assets.sh` 支持 `--launch-smoke-test`，可在本地发布前从 `.app.zip` 解包并启动 App，确认 Release 构建不会启动即退出。

### v1.2.13 优化

- GitHub 发布在远端分支刚好被其他客户端更新时，会重新读取仓库 tree 并自动重试一次，减少非快进引用更新导致的发布失败。
- 发布历史和状态栏会标记已处理远端更新，便于确认本次发布是否经历过重试。
- 设置页本地模式新增根目录诊断，可查看目录是否存在、是否可写、已发现文件夹数量和 `.sgmodule` 数量；导出的诊断报告也会包含这些信息。

### v1.2.12 优化

- “查看更新…”改为 App 内 GitHub Release 检查面板，显示当前版本、最新版本、发布说明和可安装资产。
- 更新面板会优先提供 `.pkg` 下载入口，用于更新已有安装并自动清除隔离属性；同时保留 `.app.zip` 与 Release 页面入口。
- 新增 Release 版本比较与 GitHub Release API 解码测试，避免多位版本号比较错误。

### v1.2.11 优化

- 设置页 Web 管理区域新增服务状态、访问范围与令牌存储状态，可直接看到端口是否运行、是否开放局域网访问以及令牌是否保存在系统钥匙串。
- Web 管理地址展示改为不含访问令牌；“打开”“拷贝访问链接”和二维码仍使用含令牌访问链接，方便访问但减少截图或诊断泄露风险。
- 诊断报告新增 Web 服务运行状态、访问模式、无令牌管理地址和 Web 令牌存储状态，继续保证不会导出令牌内容。

### v1.2.10 优化

- 菜单栏和应用菜单中的“查看更新…”改为直接打开 GitHub Releases 最新版本页，避免旧 Sparkle appcast 显示过期版本。
- App 启动时不再启动 Sparkle updater；在完成可签名 appcast 前，更新路径统一收敛到 GitHub Release 中的 `.pkg` 安装包。
- 文档同步说明当前更新策略：首次安装可用 `.app.zip`，更新已有安装优先使用 `.pkg`，无需重复手动执行 `xattr -cr`。

### v1.2.9 优化

- 汇总模块详情新增 GitHub 发布预览，可在上传前查看新增/更新文件和将删除的旧文件。
- 自动 GitHub 发布如果检测到需要删除旧文件，会暂停并等待用户确认，避免误删移动或改名后的历史路径。
- 本地模式写入新模块时不再静默删除旧路径；如需清理旧文件，会在汇总模块详情显示待确认清理预览。
- “扫描本地模块”的导入预览新增“已跳过”列表，显示空文件、总模块文件、已纳入管理路径、重复来源等跳过原因。

### v1.2.8 优化

- 设置页新增“安装与权限”诊断，可查看 App 路径、签名状态、Gatekeeper 评估、隔离属性、Sparkle 自动检查状态和推荐更新方式。
- 设置页新增“钥匙串”诊断，明确 GitHub Token 与 Web 管理令牌只保存到 macOS 系统钥匙串，诊断报告不会导出令牌内容。
- 诊断导出新增安装环境和钥匙串状态，方便排查首次安装打不开、更新后启动异常、钥匙串不可用等问题。
- Sparkle 自动检查更新默认关闭；在最新 appcast 签名链路完成前，更新已有安装请优先使用 Release 中的 `.pkg`。

### v1.2.7 优化

- 本地模式的存放文件夹菜单改为递归读取本地模块根目录，可直接选择多级文件夹，例如 `Ads/Video`。
- “扫描本地模块”的导入预览支持在导入前编辑模块名称、Surge `category` 标签和目标存放文件夹。
- 导入本地模块时会按最终目标文件夹检查输出路径冲突；如果多个候选项最终落到同一路径，会自动给后导入项添加序号后缀。
- 新增本地递归文件夹发现回归测试。

### v1.2.6 优化

- GitHub 存放文件夹菜单改为读取仓库递归 tree，可发现模块根目录下的多级文件夹，例如 `Ads/Video`。
- GitHub 发布改为先获取仓库递归 tree 快照，再按 Git blob SHA 对比需要上传或删除的文件，减少大量模块发布时的 Contents API 请求。
- 如果 GitHub 返回的递归 tree 被截断，发布流程会自动回退到逐文件查询，避免超大仓库下误判文件状态。
- 递归文件夹发现会忽略 Surge Relay 生成脚本使用的内部 `assets` 目录，避免污染模块存放菜单。

### v1.2.5 优化

- 添加模块和编辑模块时可直接新建“存放文件夹”；本地模式会在根目录下创建目录，GitHub 模式会先保存为空路径选项，发布模块时自动创建对应路径。
- 本地模块扫描改为后台扫描并先预览候选列表，显示模块名称、相对路径、分类与目标文件夹，确认勾选后再导入。
- 自定义文件夹会写入配置，重启后仍会出现在存放文件夹菜单中。

### v1.2.4 优化

- Release 构建脚本会自动校验 `.app.zip`、`.pkg`、sha256、App 版本号、构建号、通用架构、ad-hoc 签名、pkg payload 与 postinstall 隔离属性清理脚本。
- GitHub Actions 发布打包流程复用同一套 Release 脚本，可生成 `.app.zip`、`.pkg` 与 sha256；配置 `SPARKLE_ED_KEY` Secret 后可同时生成 Sparkle 签名元数据。
- 本地 Release 构建会预检 Sparkle 私钥来源，私钥缺失时快速给出处理方式；如只需生成手动安装预览包，可显式跳过 Sparkle 签名校验。
- 新增 `script/verify_release_assets.sh`，可在更新 appcast 后用 `--appcast appcast.xml` 继续校验 Sparkle 条目的包大小和 EdDSA 签名。

### v1.2.3 优化

- Web 管理新增访问令牌，所有接口与实时状态事件都需要令牌验证。
- Web 管理默认仅允许本机访问；如需手机或局域网设备访问，需要在设置中显式开启“允许局域网访问”。
- 设置页提供带令牌的访问链接、二维码、拷贝按钮与“重置令牌”操作，令牌保存在 macOS 系统钥匙串。

### v1.2.2 优化

- GitHub Token 改为保存到 macOS 系统钥匙串，不再写入 iCloud 同步配置文件。
- 从旧版本升级时会自动迁移 `settings.json` 中已有的 GitHub Token；迁移成功后同步配置中的旧字段会被清空。
- 如果钥匙串暂时不可用，App 会暂时沿用旧配置中的 Token，避免升级后丢失凭据。

### v1.2.1 优化

- 模块页新增“扫描本地模块”，可递归扫描本地模块根目录下已有的 `.sgmodule`，保留所在文件夹与 `#!category` 后纳入 Surge Relay 管理。
- 本地文件模块支持 `file://` 来源，后续可以和远程模块一样参与启用、排序、编辑、汇总和发布。
- Release 增加 `.pkg` 更新包；无 Apple 开发者账号场景下，更新安装会自动清除 `/Applications/Surge Relay.app` 的隔离属性，避免每次更新后手动执行 `xattr -cr`。
- 1.2.1 起内置新的 Sparkle EdDSA 公钥，用于后续版本的 App 内更新签名。

### v1.2.0 优化

- 本地与 GitHub 发布会记录上次输出清单，模块改名、删除或移动文件夹后自动清理旧文件。
- Web 管理端复用文件夹缓存，减少对 GitHub Contents API 的重复请求。
- fork 构建的 Sparkle 更新源已指向本仓库。

完整变更见 [CHANGELOG.md](CHANGELOG.md)。

## 安装

在 [Releases](https://github.com/junchan0412/SurgeRelay-macOS/releases) 下载最新版本。

- 首次安装：下载 `Surge-Relay-*.app.zip`，解压后将 `Surge Relay.app` 拖入“应用程序”文件夹。由于没有 Apple Developer ID 公证，首次打开如遇到 macOS 安全提示，可按下方“App 已损坏”说明处理一次隔离属性。
- 更新已有安装：优先下载 `Surge-Relay-*.pkg` 并运行安装器。安装脚本会替换 `/Applications/Surge Relay.app` 并清除隔离属性，后续更新不需要手动执行 `xattr -cr`。

当前 fork 的安装包为 ad-hoc 签名，尚未使用 Developer ID 公证。`.pkg` 更新包同样未公证，如 macOS 拦截安装器，可在 Finder 中右键打开。1.2.10 起，App 菜单和菜单栏的“查看更新…”会打开 GitHub Releases 最新版本页；在完成可签名 appcast 前，请以 Release 中的 `.pkg` 作为更新路径。1.2.8 起可在 App 的“设置”>“安装与权限”中查看签名、Gatekeeper 和隔离属性状态。

## 扫描本地已有模块

在“设置”中确认本地模块根目录后，回到“模块”页点击工具栏的“扫描本地模块”。Surge Relay 会递归查找根目录下的 `.sgmodule` 文件，跳过当前汇总模块和已经纳入管理的文件，并按原路径生成“存放文件夹”。

扫描导入会读取模块头部的 `#!name` 与 `#!category`，并在导入前展示可编辑预览。你可以先修改模块名称、标签和目标存放文件夹，再确认导入。1.2.9 起，扫描预览还会显示被跳过文件及原因，例如空文件、当前总模块文件、已纳入管理的发布路径或重复来源。导入后的模块来源会显示为本地 `file://` 地址，可以像远程模块一样启用、排序、编辑、汇总到总模块，并发布到本地目录或 GitHub。

## GitHub Token 存储

从 1.2.2 起，GitHub Token 保存到 macOS 系统钥匙串。旧版本写入同步配置的 Token 会在首次启动时自动迁移；迁移成功后，`settings.json` 中不再保留明文 Token。1.2.8 起可在“设置”>“钥匙串”查看 GitHub Token 与 Web 管理令牌的存储状态，诊断报告不会包含令牌内容。1.2.21 起，钥匙串主动检查失败时会显示 `OSStatus` 错误码和修复建议，便于判断是钥匙串未解锁、系统禁止交互、签名权限问题还是旧项目损坏。

## 预览

<p align="center">
  <img width="760" alt="Surge Relay Preview" src="https://github.com/user-attachments/assets/aee0f362-146d-4bbf-9069-b6fda1f8f886" />
</p>

## 特性

### 1. 集中化模块管理

在传统流程中，如果上游作者修改了仓库地址、文件路径或目录结构，用户通常需要重新打开 Script-Hub，重新转换模块，再重新安装到 Surge。

对于拥有多台设备的用户来说，这个过程需要在每台设备上重复操作。即便通过 iCloud 同步，也依然需要多次点击安装，维护成本很高。

Surge Relay 将这些流程集中到一台 Mac 上完成。你只需要在 App 中维护上游地址、备用地址和转换规则，Surge 设备端无需关心原始模块来源。

<p align="center">
  <img width="375" alt="Surge Relay Module Editor" src="https://github.com/user-attachments/assets/444cbc3d-d4b8-4047-a569-607692123503" />
  <img width="375" alt="Surge Relay Remote Management" src="https://github.com/user-attachments/assets/83509a1d-e505-4c28-b1c1-cdf6e9d80870" />
</p>

### 2. 稳定的模块分发地址

Surge Relay 会将处理后的 Surge `.sgmodule` 文件发布到稳定的 GitHub 仓库地址 (私有仓库需配合 Cloudflare，否则 Surge 设备端无法推送私有仓库地址)，或保存到本地 iCloud Drive 目录。所有 iPhone、iPad、Apple TV 和 Mac 上的 Surge App 只需要订阅这些固定 URL。

即使上游模块地址发生变化，你也只需要在 Surge Relay 中修改一次。设备端的订阅地址保持不变，不需要重新安装模块，也不需要逐台修改配置。

<p align="center">
  <img width="375" alt="image" src="https://github.com/user-attachments/assets/66c7c16a-f82c-4a55-b640-c5fcefb3cf99" />
  <img width="375" alt="image" src="https://github.com/user-attachments/assets/6bb34ca7-c4c3-43b3-9b48-284eeeda8f65" />
</p>


### 3. 本地转换与自动发布

Surge Relay 运行在你的 Mac 上，负责拉取上游模块、调用 Script-Hub 的本地转换逻辑、应用自定义规则，并生成最终可用的 Surge 模块。

生成后的模块可以自动发布到 GitHub (如果你选择上传到 GitHub，则务必选择私有仓库并搭配 Cloudflare，否则 Surge 设备端无法推送私有仓库地址。如果你选择公开仓库，请确保已得到所有模块制作者同意)，或保存到 iCloud Drive (✅最推荐)。Mac 只负责构建和发布，用户设备读取的是已经发布好的稳定文件。因此，即使 Mac 关机或暂时无法连接，已经发布的模块仍然可以正常使用。

### 4. 可视化编辑与规则控制

Surge Relay 提供图形化界面，用于查看和编辑模块内容。

你可以集中管理模块地址、删除不需要的模块、屏蔽指定 MITM hostname、禁用部分 Script 或 Rewrite 规则，并对模块参数进行可视化调整。

相比手动编辑 `.sgmodule` 文件，Surge Relay 更适合长期维护大量模块。

<p align="center">
  <img width="375" alt="Surge Relay Module Editor" src="https://github.com/user-attachments/assets/236a7812-5c2e-48d2-8f49-cb12464cdf12" />
  <img width="375" alt="Surge Relay Remote Management" src="https://github.com/user-attachments/assets/3d56e0c6-690c-4d09-9362-7bdab7c2b2fe" />
</p>

### 5. Web 端远程管理

除了 macOS 原生 App，Surge Relay 也支持 Web 端远程管理。你可以通过浏览器查看模块状态、检查同步结果、调试转换问题，或远程修改模块配置。

从 1.2.3 起，Web 管理默认仅允许本机访问，并要求访问令牌。若要从手机、平板或其他局域网设备访问，需要在设置中开启“允许局域网访问”，并使用设置页提供的链接或二维码。

配合 Surge Ponte 功能，即使不在 Mac 旁边，也可以从你的任意一台设备访问 Surge Relay，完成状态查看、调试和编辑等操作。

<p align="center">
  <img width="62%" alt="image" src="https://github.com/user-attachments/assets/294ea6e5-4791-48bb-9e78-b0a2527eee32" />
  <img width="24%" alt="image" src="https://github.com/user-attachments/assets/b0e782bb-984d-43ec-9af3-6820f4308b21" />
</p>

### 6. 多设备自动同步

所有设备只需要订阅 Surge Relay 发布后的固定模块地址。后续模块更新、上游地址修复、MITM 调整、规则禁用等操作，都可以在 Surge Relay 中统一完成。

当新的模块文件发布后，设备端会随着 Surge 的模块更新机制自动同步，避免重复配置和手动迁移。

<p align="center">
  <img width="62%" alt="Surge Relay Landscape Preview" src="https://github.com/user-attachments/assets/7dcee1b6-e2cf-4cee-9a20-293b075bf67b" />
  <img width="24%" alt="Surge Relay Portrait Preview" src="https://github.com/user-attachments/assets/b7e8040a-7dfa-4dd0-bbba-89446e933ea1" />
</p>

## 如果首次安装遇到“App 已损坏，无法打开，你应将其移到废纸篓”
此提示并不代表 App 真的损坏。只是因为没有经过 Apple 付费公证，macOS 自动加上了“隔离”标记。首次安装可以处理一次；后续更新请使用 Release 中的 `.pkg` 安装包，避免重复手动执行此命令。

请按照以下提示操作：

1.打开“终端”(“访达”>“应用程序”>“实用工具”>“终端”)。

2.拷贝并粘贴至终端如下命令后按 Return (回车) 键：

```bash
  sudo xattr -rd com.apple.quarantine /Applications/Surge\ Relay.app
```

3.输入 Mac 的开机密码 (输入时不会显示任何字符) 后按 Return (回车) 键。

4.重新打开 Surge Relay，即可正常使用。

## 声明

本项目展示页面中的模块、模块名称、作者名称及相关来源，仅用于说明 Surge Relay 的模块管理、转换、汇总和分发能力，不代表本项目对任何模块内容、使用方式、适用场景或安全性的推荐、背书、指导或保证。

示例中展示的模块来源可能包括但不限于：Surge Relay、@小白脸、@xream、@keywos、@ckyb、Ethan、[RuCu6](https://github.com/RuCu6)、[Maasea](https://github.com/Maasea)、[fmz200](https://github.com/fmz200)、[kelv1n1n](https://github.com/kelv1n1n)、[可莉🅥](https://github.com/luestr/ProxyResource/blob/main/README.md)、[zmqcherish](https://github.com/zmqcherish)、[VirgilClyne](https://github.com/VirgilClyne)、[zirawell](https://github.com/zirawell)、wish、奶思等。

所有模块的版权、署名、许可协议和使用限制均归原作者或原项目所有。Surge Relay 仅提供本地化的模块管理、转换、编辑和发布工具能力。用户在使用、转换、编辑、分发或订阅相关模块前，应自行确认对应模块的来源、许可、用途、风险和合规性。

## 反馈

如果你有任何问题，请在 Github 提交 Issue。
