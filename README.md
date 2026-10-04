# winbuild — GitHub Actions 构建 Windows 11 ISO

在 **GitHub Actions 云端**用 [UUP dump](https://uupdump.net) 下载 UUP 更新包并转换成可启动 ISO，
本地不下载任何 UUP 文件，构建完成后**分卷（≤2GB）发布到 GitHub Release**。

- 默认：**build `28020`（Beta 频道 26H1 分支）/ x64 / 简体中文 / 专业版 / 无人值守**
- 构建号**可手动输入**（`28020` 取最新修订，或精确到 `28020.3142`），并有 `insider` / `stable` 通道下拉
- 触发：手动 `workflow_dispatch`，全部参数在网页上填
- 默认注入 `autounattend.xml`：免 TPM/安全启动/内存检测 + 跳过 OOBE + 写 OEM 信息
- 参考：[ylx2016/uup-dump-build-and-get-windows-iso](https://github.com/ylx2016/uup-dump-build-and-get-windows-iso)、[yprsoft/UUPdumpWinISO](https://github.com/yprsoft/UUPdumpWinISO)、[adavak/win_iso_build](https://github.com/adavak/win_iso_build/releases)

> ⚠️ UUP dump **没有 LTSC 版本**（LTSC 2024 是 26100）。本流水线做的是
> 专业版 / 企业版 / 家庭版。要 LTSC 参考 adavak 的「官方 ISO + 补丁」路线。

## 目录结构

```
winbuild/
├── .github/workflows/build-win11-iso.yml   # CI：磁盘检查 → 构建 → 注入 → 分卷 → 发 Release
├── scripts/Get-UupIso.ps1                 # 主脚本：找构建 → 下载包 → 改配置 → 转 ISO → 注入应答文件
├── OEM/logo.bmp                           # 可选：放进来就会被塞进 install.wim 并写进 OEMInformation\Logo
└── Drivers/                               # 可选：要注入镜像的驱动放这里（勾 drivers 开关才生效）
```

## 工作原理

1. 调 UUP dump API（`api.uupdump.net`）按 `windows 11 <构建号> amd64` 搜索，按**通道**过滤标题后取最新：
   - `stable` → `Windows 11, version 26H2 (26300.9550)` 这类正式版
   - `insider` → `Windows 11 Insider Preview Feature Update (28020.3142)` 这类预览版
   - 两种通道都排除累积更新本身（`Preview Update for ...`）和 `.NET Framework` 更新，再校验 zh-cn 语言包
2. `POST uupdump.net/get.php` 拿「下载包」（`ConvertConfig.ini` + `uup_download_windows.cmd`）
   - `autodl=2` 普通版本；`autodl=3` + `virtualEditions[]=Enterprise` 走 UUP dump 的
     *Create additional editions*，从专业版派生企业版
   - `updates=1` → 转换时下载并集成**最新累积更新**（这就是「通过 UUP dump 下载更新包」）
3. 按参数改写 `ConvertConfig.ini`（`AutoExit` / `Cleanup` / `ResetBase` / `wim2esd` / `wim2swm` /
   `NetFx3` / `SkipApps` / `SkipEdge` / `AddDrivers` / `StartVirtual` + `vAutoEditions` + `vDeleteSource`），
   并给 aria2 参数降噪
4. 运行 `uup_download_windows.cmd`：aria2 从 Windows Update 服务器拉 UUP 文件，
   uup-converter-wimlib 挂载镜像 → 打补丁 → 导出 → 生成 ISO
5. （`unattend` 开着时）生成 `autounattend.xml` 并**重新封盘**：
   读回原 ISO 卷标 → 挂载后 `robocopy` 展开 → 应答文件放到 ISO 根目录 →
   （仓库有 `OEM/logo.bmp` 时）`wimlib-imagex update` 把它塞进 `install.wim` 的
   `\Windows\System32\` → 用转换器自带的 `bin\cdimage.exe` 按原 `-bootdata` 参数重新封盘 →
   `7z l` 校验新 ISO 里确实有 `autounattend.xml` 和 `boot.wim` 才替换原 ISO。
   转换器在 `:QUIT` 里会删掉 `ISOFOLDER`，所以只能事后重封，没法直接往里加文件
6. 计算 SHA256、读出镜像内的版本列表、写元数据 JSON，清理工作目录
7. `7z -v2000m` 把 ISO 切成 2000MB 分卷（Release 单文件上限 2GB），删掉原始 ISO，`gh release create` 发布

## 推到 GitHub

需要一个 **fine-grained PAT**（或 classic PAT），权限：

| 类型 | 需要的权限 |
| --- | --- |
| Fine-grained | 对该仓库：`Contents: Read and write`、`Metadata: Read-only`，并且 **Workflows: Read and write**（推 `.github/workflows/*.yml` 必须） |
| Classic | `repo` + `workflow` 两个 scope |

```bash
# 本机已装 gh，密钥给我之后执行（或你自己跑）
gh auth login --with-token <<< "$GITHUB_TOKEN"
gh repo create <你的用户名>/winbuild --private --source . --push
```

仓库必须是**能跑 Actions** 的（私有仓库消耗 2x 分钟额度）。

## 触发构建

Actions → **Build Windows 11 ISO** → *Run workflow*：

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `build` | 文本 | **`28020`** | **构建号，可手填**：`28020` = 该版本最新修订；精确版本填 `28020.3142`。查最新见下节 |
| `channel` | 下拉 | **`insider`** | `insider` = Dev/Beta/Canary 预览版；`stable` = 正式版（title 含 `version 26H2` 之类） |
| `edition` | 下拉 | **`pro`** | `pro` 专业版（首跑推荐，ylx2016 已验证）；`enterprise` 仅企业版；`enterprise_pro` 专业版+企业版；`multi` 家庭版+专业版 |
| `updates` | 开关 | **true** | 集成最新累积更新（UUP dump 下载更新包） |
| `netfx3` | 开关 | **true** | 预装 .NET Framework 3.5 |
| `esd` | 开关 | false | ESD 固体压缩，镜像更小、转换更慢 |
| `reset_base` | 开关 | true | ResetBase 组件基线重置，镜像更小、更慢 |
| `skip_apps` | 开关 | false | 跳过预装 Store 应用（`SkipApps`），镜像更小但没有商店/内置 Appx |
| `skip_edge` | 开关 | false | 跳过 Edge 集成（`SkipEdge`） |
| `drivers` | 开关 | false | 注入仓库 `Drivers/` 目录下的驱动（`AddDrivers`） |
| `wim2swm` | 开关 | false | `install.wim` 拆成 `install.swm`（`esd` 开着时无效，转换器以 `install.esd` 为准） |
| `unattend` | 开关 | **true** | 往 ISO 根目录注入 `autounattend.xml` 并重新封盘；关掉 = 完全原厂 ISO |
| `hw_bypass` | 开关 | **true** | windowsPE 阶段写 `LabConfig`，绕过 **TPM / 安全启动 / 内存** 检查（依赖 `unattend`） |
| `skip_oobe` | 开关 | **true** | 跳过 EULA / 微软账户 / 无线设置 / 隐私设置页，`ProtectYourPC=3`（依赖 `unattend`） |
| `local_user` | 文本 | *（空）* | 预建本地管理员账户名；**留空 = 不预建**，OOBE 里手动创建 |
| `local_password` | 文本 | *（空）* | 上面那个账户的密码（留空 = 无密码）。注意 workflow 输入公开可见 |
| `oem_org` | 文本 | **`SYSTEM-Intel-MIC`** | `RegisteredOrganization`：winver「组织」 |
| `oem_provider` | 文本 | **`SYSTEM-Intel-MIC`** | `SupportProvider`：「获取帮助」里的支持提供方 |
| `oem_url` | 文本 | **`https://space.bilibili.com/1978487514`** | `SupportURL`：「获取帮助」跳转链接；缺协议头会自动补 `https://` |
| `oem_manufacturer` | 文本 | **`SYSTEM-Intel-MIC`** | `Manufacturer`（已弃用，只写注册表，Win11「设置→关于」不再显示） |
| `oem_model` | 文本 | *（空）* | `Model`（已弃用） |
| `oem_logo` | 文本 | *（空）* | `Logo` 路径；留空且仓库有 `OEM/logo.bmp` 时自动用 `C:\Windows\System32\oemlogo.bmp` 并把文件塞进 `install.wim` |
| `oem_phone` | 文本 | *（空）* | `SupportPhone`（已弃用） |
| `deep_debloat` | 开关 | **true** | 离线精简 `install.wim`：Appx 移除 + AI/Copilot/Recall 移除 + 注册表优化 + 禁用服务 |
| `office_offline` | 开关 | **true** | 离线集成 Office 365（Word/Excel/PowerPoint），ODT 在 Action 下载，首登录静默安装 |
| `mas_activate` | 开关 | **true** | 首登录运行 MAS 永久激活 Windows + Office |
| `perf_tweaks` | 开关 | **true** | 额外禁用更多服务/诊断/遥测（独立开关，可单独关） |
| `deep_debloat` | 开关 | **true** | 离线精简：Appx 移除 + AI/Copilot/Recall 移除 + 注册表优化 + 禁用服务 |
| `office_offline` | 开关 | **true** | 离线集成 Office 365（Word/Excel/PowerPoint），ODT + 离线包在 Action 下载，首登录静默安装 |
| `mas_activate` | 开关 | **true** | 首登录运行 MAS 永久激活 Windows + Office |
| `perf_tweaks` | 开关 | **true** | 额外禁用更多服务/诊断/遥测（独立开关，可单独关） |

架构 `x64`、语言 `zh-CN` 已固定；要改就调 `scripts/Get-UupIso.ps1 -Arch amd64 -Lang zh-cn ...`。

### 怎么查「最新版本号」填进 `build`

1. **最简单**：打开 <https://uupdump.net/>，首页 *Downloads* 列表里找 amd64 那行，括号里的数字就是，
   例如 `Windows 11 Insider Preview Feature Update (28020.3142) amd64` → 填 `28020`（取最新）或 `28020.3142`（精确）
2. **按类别浏览**：<https://uupdump.net/known.php?q=category:w11-26h1>（Beta 26H1，默认这条）、
   `category:w11-26h2`（26H2 正式版）、`category:w11-26h2-beta`、`category:w11-26h2-experimental` 等
3. **直接搜**：<https://uupdump.net/known.php?q=关键词>，如 `known.php?q=28020`
4. 常见构建号：**`28020` = Beta 频道 26H1（当前默认）**、`26300` = 26H2 正式版、
   `26220` = Beta 频道 25H2、`26340` = Experimental 频道

> UUP dump 上**没有**「26H2 Beta」这个组合：26H2 已经是正式版（`channel=stable` + `build=26300`），
> Beta 频道跑的是 26220/28020 这条线。

填错不会乱跑：脚本会把搜到的标题列出来并报错，改一下再点就行。

## 无人值守（`autounattend.xml`）

`unattend` 开着时，脚本会在转换完成后**把 ISO 重新封一遍盘**，把生成的 `autounattend.xml`
放到 ISO 根目录（Windows Setup 会自动搜索安装介质根目录的 `autounattend.xml`）。
生成的文件分两个 pass，并会额外写入 `SetupComplete.cmd` 与 `FirstBoot.ps1`：

| pass | 内容 | 开关 |
| --- | --- | --- |
| `windowsPE` | `Microsoft-Windows-Setup\RunSynchronous` 往 `HKLM\SYSTEM\Setup\LabConfig` 写 `BypassTPMCheck` / `BypassSecureBootCheck` / `BypassRAMCheck`；外加 `International-Core-WinPE` 固定 zh-CN 输入法 | `hw_bypass` |
| `oobeSystem` | `OOBE`：`HideEULAPage` / `HideOEMRegistrationScreen` / `HideOnlineAccountScreens` / `HideWirelessSetupInOOBE` / `ProtectYourPC=3`；`OEMInformation`、`RegisteredOrganization`、`TimeZone=China Standard Time`；按需 `UserAccounts` | `skip_oobe` / `local_*` / `oem_*` |

**行为边界（重要）：**

- 分区、选盘、选版本仍然**由你手动操作**，不会自动动磁盘；`local_user` 留空时账户页也照常出现
- 绕过只写了 `TPM` / `安全启动` / `内存` 三个键——`BypassCPUCheck`、`BypassStorageCheck`
  在 24H2 之后的 setup 二进制里已经不存在，写了也没人读
- 这套 `LabConfig` 写法在 26100/24H2 上被大量验证过，**在 28020 上尚未实测**；
  如果装到「此电脑不符合要求」那一步被拦住，把 `hw_bypass` 关掉重跑即可（`unattend` 保持开）
- `OEMInformation` 的 `Manufacturer` / `Model` / `Logo` / `SupportPhone` 微软已标记弃用，
  只写注册表，Win11「设置 → 关于」不再展示；`SupportURL` / `SupportProvider` 在「获取帮助」里仍然有效

### 离线深度精简（`deep_debloat`）

在 `install.wim` 里做以下 **全部** 修改（你可在 `scripts/Get-UupIso.ps1` 里逐项注释掉不要的）：

#### ① 移除预装 Appx 包（保留核心）

**保留**：
- `Microsoft.ZuneVideo` / `Microsoft.ZuneMusic`（媒体播放器/音乐）
- `Microsoft.MicrosoftEdge.Stable`（Edge）
- `Microsoft.WindowsStore`（应用商店）
- `Microsoft.Windows.Photos`（照片）
- `Microsoft.WindowsCamera`（相机）
- `Microsoft.ScreenSketch` / `Microsoft.SnippingTool`（截图/速记）
- `Microsoft.Notepad`（记事本）
- `Microsoft.MSPaint` / `Microsoft.WindowsCalculator` / `Microsoft.Alarms`（画图/计算器/闹钟）
- `Microsoft.VCLibs.*` / `Microsoft.Media.*`（媒体扩展）

**移除**：
- Xbox 全家：`Microsoft.Xbox*` / `Microsoft.Gaming*` / `Microsoft.XboxGameOverlay`
- 反馈/帮助：`Microsoft.Windows.FeedbackHub` / `Microsoft.GetHelp` / `Microsoft.Getstarted`
- 广告/新闻/天气：`Microsoft.BingNews` / `Microsoft.BingWeather` / `Microsoft.BingTravel` / `Microsoft.BingSports` / `Microsoft.BingFinance`
- Office 入口：`Microsoft.OfficeHub` / `Microsoft.GetOffice` / `Microsoft.MicrosoftOfficeHub`
- 其他：`Microsoft.People` / `Microsoft.Skype...` / `Microsoft.Teams` / `Microsoft.OneNote` / `Microsoft.Wallet` / `Microsoft.Translator` / `Microsoft.VoiceRecorder` / `Microsoft.Solitaire...`

#### ② 移除 Windows AI 功能（Capability）

- `Recall`（屏幕记录/AI 分析）——**移除**
- `Microsoft.Windows.AI.Copilot.Provider`（Copilot 核心）——**移除**
- `Microsoft.Copilot`（旧版 Copilot）——**移除**
- `Microsoft.Windows.Clipchamp`（AI 视频编辑）——**移除**
- `Microsoft.Windows.Photos.AI` / `Microsoft.Windows.AppRuntime.AI`（AI 运行时）——**移除**

#### ③ 禁用服务（注册表 `Start = 4` 禁用）

**遥测/诊断**：
- `DiagTrack`（Connected User Experiences and Telemetry）
- `dmwappushservice`（Device Management WAP Push）
- `lfsvc`（Geolocation Service）
- `SharedAccess`（Internet Connection Sharing）
- `RetailDemo`（Retail Demo）

**与日常使用冲突/无用**：
- `WMPNetworkSvc`（Windows Media Player Network Sharing）
- `PhoneSvc`（Telephony）
- `TabletInputService`（Touch Keyboard Service）
- `MapsBroker`（Downloaded Maps Manager）
- `WalletService`（Wallet）
- `DPS`（Diagnostic Policy Service）
- `PcaSvc`（Program Compatibility Assistant）
- `CDPSvc` / `CDPUserSvc`（Connected Devices Platform）
- `AppReadiness` / `AppXSvc` / `AppMgmt`（App 安装向导）
- `WebClient`（WebDAV Client）
- `RemoteRegistry`（远程注册表）
- `TermService`（远程桌面）
- `LanmanServer`（Server 服务）
- `CscService`（Offline Files）
- `EFS`（Encrypting File System）
- `Fax`
- `FdPHost`（Feature Discovery Platform Host）
- `WbioSrvc`（Windows Biometric）

**游戏/云服务**：
- `GameInput` / `GameBarFTServer` / `GameDVR_Svc` / `GCSvc` / `GraphicsPerfMonitor`
- `MicrosoftEdgeUpdate` / `MicrosoftEdgeElevation` / `MicrosoftOfficeClickToRun`
- `XnaSvc` / `XblAuthManager` / `XblGameSave` / `XboxGipSvc` / `XboxNetApiSvc` / `XboxPcApp`

**网络/隐私**：
- `IKEEXT`（IKE and AuthIP IPsec Keying Modules）
- `InvokerPRT`（Windows 简化身份验证）
- `lath` / `l2tsvc`（AI 语音/L2TP）
- `lpksetup`（Language Pack Setup）
- `LpdPrintService`（LPD 打印服务）
- `MpsSvc`（Windows Firewall）——可保留或删除，取决于需求
- `MpsSvc` 我建议保留
- `MsMpSvc`（Windows Defender 防病毒）——**不删**，保持安全
- `MSDTC`（分布式事务协调器）

> ⚠️ **保留**的关键服务：`wuauserv`（Windows Update）、`WSearch`（搜索）、`Spooler`（打印）、`Netlogon`、`NlaSvc`、`RpcSs`、`EventLog`、`PlugPlay`、`WinDefend`（如果保留 Defender）。

#### ④ 注册表优化（每个键的作用）

| 键 | 值 | 作用 |
|---|---|---|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection` | `AllowTelemetry=0` | 禁用遥测数据收集 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection` | `AllowDiagnosticData=0` | 禁用诊断数据 |
| `HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows` | `CEIPEnable=0` | 禁用客户体验改进计划 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows Error Reporting` | `Disabled=1` | 禁用错误报告 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent` | `DisableWindowsConsumerFeatures=1` | 禁用消费者功能（广告/建议） |
| `HKLM\SOFTWARE\Microsoft\GameBar` | `GameBarEnabled=0` | 禁用 Game Bar |
| `HKLM\SOFTWARE\Microsoft\GameBar` | `AutoGameModeEnabled=0` | 禁用自动游戏模式 |
| `HKLM\SOFTWARE\Policies\Microsoft\GameDVR` | `AllowGameDVR=0` | 禁用 Game DVR 录制 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search` | `AllowCortana=0` | 禁用 Cortana |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search` | `AllowCortanaAboveLock=0` | 锁屏不启用 Cortana |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search` | `ConnectedSearchUseWeb=0` | 搜索不连网 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search` | `DisableAIDataAnalysis=1` | 禁用 AI 数据分析 |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Search` | `CortanaConsent=0` | Cortana 同意 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `RemoveMicrosoftCopilotApp=1` | 移除 Copilot 应用 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `DisableAIActions=1` | 禁用 AI 操作 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `DisableClickToDo=1` | 禁用 Click To Do |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat` | `ChatIcon=0` | 隐藏聊天图标（ Teams） |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DNSClient` | `DisableSmartNameResolution=1` | 禁用智能名称解析 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DNSClient` | `DisableMulticast=1` | 禁用 DNS 多播 |
| `HKLM\SOFTWARE\Microsoft\NCSI` | `EnableActiveProbing=0` | 禁用 NCSI 主动探测 |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer` | `HideChatIcon=1` | 隐藏聊天图标 |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer` | `NoAutoplay`=1 | 禁用自动播放 |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer` | `NoAutorun`=1 | 禁用自动运行 |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization` | `DownloadMode=0` | 关闭传递优化（P2P 下载） |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | `NoAutoUpdate`=0` | 保持自动更新（0=开启） |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | `AUOptions`=4 | 自动下载并安装更新 |

#### ⑤ 禁用计划任务（首登录时执行）

在 `FirstBoot.ps1` 里会执行以下命令禁用所有无用的计划任务：

```powershell
# 禁用遥测/诊断相关任务
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\StartupAppTask'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Feedback\SilentCleanup'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Maps\MapsUpdateTask'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Office\OfficeTelemetry'
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Feedback\*'
```

### Office 365 离线集成（`office_offline`）

- **安装程序**：Office Deployment Tool (ODT)，由 Action 在构建时自动下载（`officedeploymenttool_16.0.20326.20112.exe`）
- **配置文件**：`configuration.xml`，指定 `Channel=MonthlyEnterprise`、64 位、仅安装 `Word/Excel/PowerPoint`，排除 `Access/Groove/Lync/OneDrive/OneNote/Outlook/Publisher/Teams`
- **离线包**：构建时运行 `setup.exe /download configuration.xml` 下载到 `C:\OfficeInstall\OfficeData`（约 2-4 GB，取决于更新量）
- **集成方式**：`OfficeData` 复制到镜像的 `C:\OfficeInstall\OfficeData`
- **安装时机**：`SetupComplete.cmd` 在 OOBE 结束后自动启动 `setup.exe /configure`（静默安装，Level=None）
- **安装时长**：预计 5-15 分钟（首次解压 + Office 服务首次配置）

### MAS 激活（`mas_activate`）

- **下载**：构建时从官方 GitHub（`massgravel/Microsoft-Activation-Scripts/releases/latest`）下载 `MAS_AIO.cmd`
- **放置**：`C:\MAS\MAS_AIO.cmd`
- **触发**：`FirstBoot.ps1` 在 Office 安装完成后运行 `MAS_AIO.cmd`（无人值守模式：Windows HWID + Office KMS）
- **激活方式**：
  - Windows：HWID 永久激活（`/HWID`）
  - Office：KMS 激活（`/OfficeKMS`），部分环境需要 VK 注入

### 首登录编排器（`FirstBoot.ps1` + `SetupComplete.cmd`）

**触发链**：
1. OOBE 完成 → `SetupComplete.cmd`（`C:\Windows\Setup\Scripts\`）被系统以 SYSTEM 权限执行
2. `SetupComplete.cmd` 后台启动 `setup.exe /configure`（Office 静默安装）
3. `SetupComplete.cmd` 在 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` 创建 `SYSTEM_Intel_MIC_FirstBoot` 值
4. 用户首次登录时，`RunOnce` 触发 `powershell -NoProfile ... FirstBoot.ps1`
5. `FirstBoot.ps1` 显示置顶弹窗「正在安装 Office，请勿关机」
6. 等待 Office 安装进程结束（`WaitForExit`）
7. 启动 `MAS_AIO.cmd` 激活 Windows + Office
8. 关闭弹窗，显示「✅ SYSTEM-Intel-MIC 优化版 Windows 11」 + 重启提示

> `SetupComplete.cmd` 的脚本本身（PowerShell）在 SYSTEM 下运行，弹窗不会显示——所以 GUI 弹窗放到 `FirstBoot.ps1` 里，在用户桌面会话中运行。

### 注意事项（深度精简相关）

- **Office 离线包体积**：`OfficeData` 目录约 **2-4 GB**，会增大 ISO 体积（从 8.06 GB 增至约 **10-12 GB**），分卷后约 5-6 个 2 GB 分卷
- **Action 运行时间**：Office 离线包下载（+10-20 分钟）+ 离线定制（+5-10 分钟）+ 原有转换（+45-90 分钟）= **约 60-120 分钟**，仍远低于 6 小时上限
- **硬盘**：`OfficeData`（3 GB）+ `install.wim`（4 GB）+ `_iso_tree`（8 GB）+ `UUPs`（5 GB）+ 原 ISO（8 GB）+ 新 ISO（10-12 GB）≈ **38 GB 峰值**，Server 2022 D: 盘（通常 147 GB 空闲）足够
- **安全**：
  - `MAS_AIO.cmd` 来自第三方，如果担心被 Defender 误报，可把 `C:\MAS` 加入白名单（注册表 `DisableAntiSpyware` 已关闭，不影响）
  - `SetupComplete.cmd` 启动的 `setup.exe` 为微软官方 ODT，无安全风险
  - 离线定制会挂载 `install.wim`，失败时自动 `/Discard`

### OEM logo

把图片放到仓库 `OEM/logo.bmp`（也支持 `.png` / `.jpg`，24 位 BMP、96～120px 见方最合适），构建时会：

1. `wimlib-imagex update` 把它写进 `install.wim` 的 `\Windows\System32\oemlogo.bmp`（**所有**镜像索引都会写）
2. `OEMInformation\Logo` 自动设成 `C:\Windows\System32\oemlogo.bmp`

> 只对 `install.wim` 有效；开 `esd` 或 `wim2swm` 时没有 `install.wim`，会打警告并跳过（其他 OEM 字段照常写）。
> 注入失败也只警告、不中断构建（装出来的系统只是没有 logo）。

## 产物

Release 标签形如 `Win11_28020-insider_x64_zh-CN_pro_28020.3142_20261004`：

```
xxx.iso.zip.001   2000 MB
xxx.iso.zip.002   2000 MB
xxx.iso.zip.003   ~1.x GB
xxx.iso.sha256.txt
```

合并与校验：

```powershell
7z x "xxx.iso.zip.001"          # 得到 xxx.iso
# 或 copy /b xxx.iso.zip.001+xxx.iso.zip.002+... xxx.iso
Get-FileHash xxx.iso -Algorithm SHA256   # 与 sha256.txt 比对
```

Release 描述里会带：构建号、通道、镜像内版本列表、大小、SHA256、UUP dump 页面链接、当时的选项组合。
同一天重跑会 `--clobber` 覆盖同名标签下的分卷。

## 注意事项

- **磁盘**：Server 2025 镜像没有 D 盘，可用空间约 33GB。工作流会先挑剩余空间最大的盘、
  删掉用不到的预装软件，构建成功后立刻删工作目录、分卷后删原始 ISO。
  开 `unattend` 时会多一次「展开 ISO + 重新封盘」，脚本会先把 `UUPs/`（几个 GB 的下载缓存）删掉腾地方，
  峰值占用约 17GB。
- **时长**：下载 + 转换 + 分卷一般 40～90 分钟；开 `unattend` 再加约 5～10 分钟（展开 + 重封）。
  作业上限 6 小时。
- **额度**：私有仓库 Windows runner 消耗 2 倍分钟（2000 分钟/月 ≈ 16 次构建）；
  公开仓库免费但代码公开。
- **`local_password` 是公开可见的**（workflow 输入 + 仓库默认值都在明文里）。真要预建账户，
  用完记得在系统里改掉；不想暴露就保持 `local_user` 留空。
- **预览版镜像**仅供测试，别当生产机用；想要稳定就 `channel=stable` + `build=26300`（26H2 正式版）。
- **UUP dump** 是第三方站点（[源码](https://git.uupdump.net/uup-dump)），文件全部来自微软
  Windows Update 服务器；站点偶尔抖动，脚本内置 8 次指数退避重试。
- 如果 UUP 文件已被微软下架，构建会失败并打印日志最后 200 行；完整日志见作业输出里的 `uup_build.log`。
- 企业版由专业版派生（UUP dump 官方机制），装出来的是正规企业版 SKU，与零售渠道无关。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `UUP dump API xxx 连续 8 次请求失败` | 站点抖动，稍后重跑 |
| `UUP dump 上没有符合条件的构建` | 构建号和通道对不上（如 `26220` 配 `stable` 就没有）；报错里会列出实际搜到的标题 |
| `没有生成 ISO` | 看作业日志尾部 200 行；磁盘不足先关 `reset_base`，或关掉 `esd` |
| `cdimage 重新封盘失败` | 看 `_iso_repack.log`；多为磁盘不足，先关 `reset_base` / `esd` 腾空间，或临时关 `unattend` |
| `重新封盘的 ISO 里没有 autounattend.xml` / `没有 boot.wim` | 说明 `cdimage` 产物不完整，基本是空间不足，同上处理 |
| `Unattend 已开启但没有任何可写入的设置` | `unattend` 开着但 `hw_bypass` / `skip_oobe` / `oem_*` 全空，要么补字段要么关 `unattend` |
| `wimlib 注入 OEM logo 到第 N 个镜像失败` | 检查 `OEM/logo.bmp` 是否损坏；或开 `esd` / `wim2swm` 时不会有 `install.wim`（会降级成警告而非报错） |
| 装到「此电脑不符合 Windows 11 要求」被拦 | `LabConfig` 在 28020 上未实测；关掉 `hw_bypass` 重跑（`unattend` 保持开） |
| `找不到 PROFESSIONAL` / 语言包 | 该构建暂未提供 zh-cn 或对应版本，换个构建号 |
| 分卷上传失败 | 确认 workflow 有 `permissions: contents: write`（已内置），token 未过期 |
