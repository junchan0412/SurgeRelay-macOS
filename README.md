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

此 fork 基于原项目的 Apache License 2.0 许可进行修改，保留原许可证与第三方声明。当前 fork 增加了本地/GitHub 模块根目录、每个模块的 Surge `category` 标签、按根目录子文件夹保存独立转换模块、扫描本地根目录已有 `.sgmodule` 纳入统一管理、将 GitHub Token 存入系统钥匙串，以及 Web 管理访问控制能力。

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

当前 fork 的安装包为 ad-hoc 签名，尚未使用 Developer ID 公证。`.pkg` 更新包同样未公证，如 macOS 拦截安装器，可在 Finder 中右键打开。

## 扫描本地已有模块

在“设置”中确认本地模块根目录后，回到“模块”页点击工具栏的“扫描本地模块”。Surge Relay 会递归查找根目录下的 `.sgmodule` 文件，跳过当前汇总模块和已经纳入管理的文件，并按原路径生成“存放文件夹”。

扫描导入会读取模块头部的 `#!name` 与 `#!category`。导入后的模块来源会显示为本地 `file://` 地址，可以像远程模块一样启用、排序、编辑、汇总到总模块，并发布到本地目录或 GitHub。

## GitHub Token 存储

从 1.2.2 起，GitHub Token 保存到 macOS 系统钥匙串。旧版本写入同步配置的 Token 会在首次启动时自动迁移；迁移成功后，`settings.json` 中不再保留明文 Token。

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
