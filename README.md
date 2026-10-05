# winbuild — GitHub Actions 构建 Windows 11 ISO

在 **GitHub Actions 云端**用 [UUP dump](https://uupdump.net) 下载 UUP 更新包并转换成可启动 ISO，
本地不下载任何 UUP 文件，构建完成后**分卷（≤2GB）发布到 GitHub Release**。

- 默认：**build `28020`（Beta 频道 26H1 分支）/ x64 / 简体中文 / 企业版 / 无人值守 / ESD 压缩**
- 构建号**可手动输入**（`28020` 取最新修订，或精确到 `28020.3142`），并有 `insider` / `stable` 通道下拉
- 触发：手动 `workflow_dispatch`，全部参数在网页上填
- 默认注入 `autounattend.xml`：免 TPM/安全启动/内存检测 + 跳过 OOBE + 写 OEM 信息
- 默认离线精简：移除可选功能、离线组件清理、精简服务/注册表/AI 能力
- 默认集成 **Office 365 企业版（Word/Excel/PowerPoint，简体中文，离线包进镜像）**，
  首次开机后台安装、装完自动删安装包，随后 **MAS 激活 Windows + Office**
- 参考：[ylx2016/uup-dump-build-and-get-windows-iso](https://github.com/ylx2016/uup-dump-build-and-get-windows-iso)、[yprsoft/UUPdumpWinISO](https://github.com/yprsoft/UUPdumpWinISO)、[adavak/win_iso_build](https://github.com/adavak/win_iso_build/releases)

> ⚠️ UUP dump **没有 LTSC 版本**（LTSC 2024 是 26100）。本流水线做的是
> 专业版 / 企业版 / 家庭版。要 LTSC 参考 adavak 的「官方 ISO + 补丁」路线。

## 目录结构

```
winbuild/
├── .github/workflows/build-win11-iso.yml   # CI：磁盘检查 → 构建 → 注入 → 分卷 → 发 Release
├── scripts/Get-UupIso.ps1                  # 主脚本：找构建 → 下载包 → 改配置 → 转 ISO → 离线定制 → 重封
├── scripts/Download-Office.ps1             # ODT + Office 离线包下载器（与 UUP 下载并行跑）
├── OEM/logo.bmp                            # 可选：放进来就会被塞进 install.wim 并写进 OEMInformation\Logo
└── Drivers/                                # 可选：要注入镜像的驱动放这里（勾 drivers 开关才生效）
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
4. **并行**启动 `Download-Office.ps1`（后台 `Start-Job`），然后运行 `uup_download_windows.cmd`：
   aria2 从 Windows Update 服务器拉 UUP 文件，uup-converter-wimlib 挂载镜像 → 打补丁 → 导出 → 生成 ISO
5. （`deep_debloat` / `office_offline` / `mas_activate` / `perf_tweaks` 任一开着时）**离线定制 `install.wim`**：
   挂载 → 移除 Appx/Capability/可选功能 → 离线组件清理 → 写服务与注册表 → 放入 Office 离线包、MAS、
   `SetupComplete.cmd`、`FirstBoot.ps1` → 提交卸载
6. （`unattend` 开着时）生成 `autounattend.xml` 并**重新封盘**：
   读回原 ISO 卷标 → 挂载后 `robocopy` 展开 → 应答文件放到 ISO 根目录 →
   （仓库有 `OEM/logo.bmp` 时）`wimlib-imagex update` 把它塞进 `install.wim` 的 `\Windows\System32\` →
   （`esd` 开着时）把 `install.wim` 导出成 solid 压缩的 `install.esd` →
   用转换器自带的 `bin\cdimage.exe` 按原 `-bootdata` 参数重新封盘（`-o -m -u2 -udfver102`）→
   `7z l` 校验新 ISO 里确实有 `autounattend.xml` 和 `boot.wim` 才替换原 ISO。
   转换器在 `:QUIT` 里会删掉 `ISOFOLDER`，所以只能事后重封，没法直接往里加文件
7. 计算 SHA256、读出镜像内的版本列表、写元数据 JSON，清理工作目录
8. `7z a -v2000m -mx=0` 把 ISO 切成 2000MB 分卷（Release 单文件上限 2GB，`-mx=0` 不压缩不耗时），
   删掉原始 ISO，`gh release create` 发布

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
| `edition` | 下拉 | **`enterprise`** | `enterprise` 仅企业版；`pro` 专业版；`enterprise_pro` 专业版+企业版；`multi` 家庭版+专业版 |
| `updates` | 开关 | **true** | 集成最新累积更新（UUP dump 下载更新包） |
| `netfx3` | 开关 | **true** | 预装 .NET Framework 3.5 |
| `esd` | 开关 | **true** | 重新封盘时把 `install.wim` 导出成 `install.esd`（solid 压缩），详见「体积优化」 |
| `reset_base` | 开关 | **true** | UUP 转换阶段 `ResetBase=1`，镜像更小、更慢 |
| `skip_apps` | 开关 | false | 跳过预装 Store 应用（`SkipApps`），**没有商店和内置 Appx**，日常用别开 |
| `skip_edge` | 开关 | false | 跳过 Edge 集成（`SkipEdge`） |
| `drivers` | 开关 | false | 注入仓库 `Drivers/` 目录下的驱动（`AddDrivers`） |
| `wim2swm` | 开关 | false | `install.wim` 拆成 `install.swm`。**产物不再是 `install.wim`，会连带跳过离线精简 / Office / MAS / OEM logo** |
| `unattend` | 开关 | **true** | 往 ISO 根目录注入 `autounattend.xml` 并重新封盘；关掉 = 完全原厂 ISO |
| `hw_bypass` | 开关 | **true** | windowsPE 阶段写 `LabConfig`，绕过 **TPM / 安全启动 / 内存** 检查（依赖 `unattend`） |
| `skip_oobe` | 开关 | **true** | 跳过 EULA / 微软账户 / 无线设置 / 隐私设置页，`ProtectYourPC=3`（依赖 `unattend`） |
| `oem_org` | 文本 | **`SYSTEM-Intel-MIC`** | `RegisteredOrganization`：winver「组织」 |
| `oem_provider` | 文本 | **`SYSTEM-Intel-MIC`** | `SupportProvider`：「获取帮助」里的支持提供方 |
| `oem_url` | 文本 | **`https://space.bilibili.com/1978487514`** | `SupportURL`：「获取帮助」跳转链接；缺协议头会自动补 `https://` |
| `oem_manufacturer` | 文本 | **`SYSTEM-Intel-MIC`** | `Manufacturer`（已弃用，只写注册表，Win11「设置→关于」不再显示） |
| `oem_logo` | 文本 | *（空）* | `Logo` 路径；留空且仓库有 `OEM/logo.bmp` 时自动用 `C:\Windows\System32\oemlogo.bmp` 并把文件塞进 `install.wim` |
| `oem_phone` | 文本 | *（空）* | `SupportPhone`（已弃用） |
| `deep_debloat` | 开关 | **true** | 离线精简 `install.wim`：Appx + Capability + 可选功能移除 + 组件清理 + 注册表 + 服务 |
| `office_offline` | 开关 | **true** | 离线集成 Office 365（Word/Excel/PowerPoint），ODT + 离线包在 Action 下载，首登录自动安装 |
| `mas_activate` | 开关 | **true** | 首登录运行 MAS 永久激活 Windows + Office |
| `perf_tweaks` | 开关 | **true** | 见下方「四个精简开关的门控关系」 |

共 **24 个输入**，全部默认值就是当前线上跑通的组合。

> 脚本 `Get-UupIso.ps1` 还支持 `-LocalUser` / `-LocalPassword` / `-OemModel`，
> 但 workflow **没有暴露成输入**，所以现在恒为空 = 不预建账户（OOBE 里手动建）、不写 `Model`。

### 四个精简开关的门控关系（重要）

```
任一开关为真 ──┐
  deep_debloat ─┼──> 进入 Invoke-OfflineCustomization（挂载 install.wim 做下面 ①~⑦ 全部动作）
  office_offline ┘
  mas_activate
  perf_tweaks
```

- **`deep_debloat` 单独关掉是不够的**：只要 `office_offline` / `mas_activate` / `perf_tweaks`
  还开着，脚本照样会进离线定制，①~④ 的精简动作（Appx / Capability / 可选功能 / 组件清理 /
  服务 / 注册表）**也会一并执行**——这几步在函数内部没有再按 `deep_debloat` 二次判断。
- 想要「只要 Office，不要任何精简」：把 `deep_debloat` 和 `perf_tweaks` 都关掉，只留 `office_offline`。
  （当前实现做不到，需要改代码；见 `Get-UupIso.ps1` 的 `Invoke-OfflineCustomization`。）
- `perf_tweaks` 目前**没有独立的额外动作**，它只是四个门控开关之一（`$regPaths`、服务清单
  都是无条件执行的）。保留这个输入是为了以后把「更激进的优化」单独挂上去。

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
| `oobeSystem` | `OOBE`：`HideEULAPage` / `HideOEMRegistrationScreen` / `HideOnlineAccountScreens` / `HideWirelessSetupInOOBE` / `ProtectYourPC=3`；`OEMInformation`、`RegisteredOrganization`、`TimeZone=China Standard Time` | `skip_oobe` / `oem_*` |

`LabConfig` 三个键的写法（`reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f`）：

| 键 | 作用 |
| --- | --- |
| `BypassTPMCheck=1` | 跳过 TPM 2.0 检查（无 TPM 2.0 的机器也能装） |
| `BypassSecureBootCheck=1` | 跳过安全启动（BIOS 里关了 Secure Boot 也能装） |
| `BypassRAMCheck=1` | 跳过内存容量检查（低于 4GB 也放行） |

**行为边界（重要）：**

- 分区、选盘、选版本仍然**由你手动操作**，不会自动动磁盘；workflow 没暴露 `local_user`，
  所以账户页照常出现
- 绕过只写了 `TPM` / `安全启动` / `内存` 三个键——`BypassCPUCheck`、`BypassStorageCheck`
  在 24H2 之后的 setup 二进制里已经不存在，写了也没人读
- 这套 `LabConfig` 写法在 26100/24H2 上被大量验证过，**在 28020 上尚未实测**；
  如果装到「此电脑不符合要求」那一步被拦住，把 `hw_bypass` 关掉重跑即可（`unattend` 保持开）
- `OEMInformation` 的 `Manufacturer` / `Model` / `Logo` / `SupportPhone` 微软已标记弃用，
  只写注册表，Win11「设置 → 关于」不再展示；`SupportURL` / `SupportProvider` 在「获取帮助」里仍然有效

## 离线深度精简（`Invoke-OfflineCustomization`）

按**执行顺序**列全，每一步都标注了「为什么」。所有操作都作用在挂载的 `install.wim` 上
（`dism /Mount-Wim /Index:1`），失败会 `/Unmount-Wim /Discard` 丢弃，绝不留下半成品。

### ① 移除预装 Appx 包（`$keep` 保留白名单）

**实现方式（先看懂这个，下面的名单才说得通）：**

```powershell
foreach ($k in $keep) { if ($app -like "*$k*") { $shouldKeep = $true; break } }
if ($shouldKeep) { Write-Host "[keep] $app"; continue }   # 命中白名单 → 保留
dism /Remove-ProvisionedAppxPackage /PackageName:$app      # 没命中 → 移除
```

- `$keep` 是**保留白名单**，匹配方式是**包含匹配**（`*关键词*`），不是精确匹配。
- 日志里每个包都会打印一行 `[keep]`（保留）或 `[fail]`（移除失败 + 退出码），
  **要看镜像里到底 provision 了哪些包，直接翻日志的 `[keep]` 列表**，不用猜。
- **白名单同时是「需求清单」**：下面是按用途归类的实际内容（`Get-UupIso.ps1` 441–487 行）。

| 类别 | 关键词（节选） | 为什么留 |
| --- | --- | --- |
| 用户点名要的 | `Notepad` `WindowsNotepad` `Paint` `MSPaint` `WindowsCalculator` `Alarms` `ScreenSketch` `SnippingTool` | 记事本 / 画图 / 计算器 / 闹钟 / 截图 |
| 终端 | `WindowsNotepad` `WindowsTerminal` | Windows Terminal；PowerShell 是系统组件、不走 Appx 移除，天然保留 |
| 浏览器 / 商店 | `MicrosoftEdge` `WindowsStore` `StorePurchaseApp` `DesktopAppInstaller` | Edge、应用商店、winget |
| 照片 / 相机 | `Windows.Photos` `Photos` `WindowsCamera` `Camera` `PhotosLegacy` `PhotosEditor` | 照片、相机 |
| 媒体播放器 | `ZuneVideo` `ZuneMusic` `MediaPlayer` `Music` | 媒体播放器 / 电影和电视 / Groove |
| **编解码器** | `Codec` `WebMediaExtensions` `VP9VideoExtensions` `HEIFImageExtension` `AV1VideoExtensions` `MPEG2VideoExtensions` `HEVCVideoExtensions` `AVCEncoderVideoExtension` `RawImageExtension` `WebpImageExtension` | 用户点名保留；缺了 WebP/HEIF/AV1/HEVC 视频和图片打不开 |
| **运行库** | `WindowsAppRuntime` `WindowsAppSDK` `VCLibs` `VCLibs.140.00` `NET.Native` `UI.Xaml` `WebView` | WindowsAppRuntime 是大量应用的依赖，**删了会连带废掉一批 App** |
| 桌面应用桥 | `Widgets` `PowerAutomateDesktop` `StartExperiencesApp` `ApplicationCompatibilityEnhancements` | 组件运行时 / 开始菜单体验 |
| 通讯 | `MSTeams` `Teams` `Outlook` `OneDrive` `Skype` `YourPhone` | 保留以免用户装完发现聊天/邮件/网盘没了 |

> **已知问题（保守导致的「不够干净」）：** 白名单里还混着一批看起来像垃圾的关键词——
> `Xbox` `Gaming` `BingNews` `BingWeather` `BingTravel` `BingSports` `BingFinance` `FeedbackHub`
> `GetHelp` `Getstarted` `OfficeHub` `GetOffice` `People` `Maps` `Solitaire` `Wallet` `Translator`
> `VoiceRecorder` `OneNote` `Todos` `Tips` `Cortana` `Print3D` `3DViewer` `MixedReality` …
> 在**包含匹配**下，这些关键词会把同名包**保住**，等于「该删的没删」。
> 实测在 build 28020 上这些包大多**根本没被 provision**，把白名单瘦身后只省 **28 MB**，
> 所以现在**优先保证不误删**。要更激进：把对应关键词从 `$keep` 里删掉即可，
> 下次构建日志的 `[keep]` 列表会立刻告诉你删对了没。

### ② 移除 AI / Copilot / Recall（Capability）

| Capability | 作用 |
| --- | --- |
| `Recall` | 屏幕记录 + AI 回溯，隐私争议最大，删 |
| `Microsoft.Windows.AI.Copilot.Provider` | Copilot 核心提供程序，删 |
| `Microsoft.Copilot` | 旧版 Copilot，删 |
| `Microsoft.Windows.Clipchamp` | AI 视频剪辑，删 |
| `Microsoft.Windows.Photos.AI` | 照片 AI 抠图/修饰，删 |
| `Microsoft.Windows.AppRuntime.AI` | AI 运行时，删 |

### ③ 体积诊断（清理前）

`Get-DirSizeMb` 递归统计下面 5 个大头，打印 `[size:清理前]`：

`Windows\WinSxS`、`Windows\System32\DriverStore\FileRepository`、`Program Files`、
`Program Files (x86)`、`Windows\servicing\Packages`

> 目的：**清理前后各测一次，差值 = 这一轮的净收益**，下次决定还要不要继续砍，
> 靠日志数据而不是拍脑袋。两次全量扫描约 6 分钟，值得。

### ④ 移除可选功能（`/Get-Features` + `/Disable-Feature /Remove`）

- 先 `dism /Get-Features /English` 拉全量清单并**逐个打印**（`[feature] xxx`），
  `/English` 是必须的：镜像是 zh-CN，不强制英文解析不出 `Feature Name :` 那一行。
- 再对**安全清单**做包含匹配，命中才删，匹配不到直接跳过（零风险）。
- 用 `/Remove` 而不是只 `/Disable`：只禁用不删文件，**一点空间都省不下来**。

| 匹配关键词 | 删掉的东西 | 为什么敢删 |
| --- | --- | --- |
| `XPS` | XPS 查看器 + XPS 打印 | **PDF 打印是独立服务**，不受影响；没人用 XPS |
| `WorkFolders` | 工作文件夹同步 | 企业域同步场景，家用用不到 |
| `Fax` | 传真 | 家用/办公都不传真了 |
| `SMB1Protocol` | SMB1 协议 | 废弃协议，WannaCry 就是靠它，删了更安全 |
| `TelnetClient` `SimpleTCP` `ClientForNFS` | Telnet / 简易 TCP / NFS 客户端 | 明文或冷门协议 |
| `RasCMAK` `LPD` `LPRPortMonitor` `TFTP` | 拨号管理器 / LPD 打印 / TFTP | 老式网络服务 |
| `SNMP` | SNMP 客户端 | 网络管理场景，家用用不到 |
| `PowerShellV2` | PowerShell **v2** 旧引擎 | 5.1 和 7 完全不受影响（v2 是 2009 年的引擎） |
| `Rsat` `DirectoryServices` `IPAM` `DataCenterBridging` | 服务器管理工具 | 客户端系统用不到 |

**铁律：下面这些绝不出现在清单里** —— 媒体播放器 / `MediaFoundation` / 编解码器 /
`.NET 3.5` / IE 模式（Edge 依赖）/ 搜索 / 远程桌面 / `OpenSSH.Client` / 打印与 PDF。
清单里的关键词**匹配不到就跳过**，不会报错。

### ⑤ 离线组件清理（`/Cleanup-Image /StartComponentCleanup /ResetBase`）

- 打 LCU（累积更新）后，WinSxS 里会留下**被新版本替代的旧组件**，`ResetBase` 才能真删掉它们。
- 这一步是**无损的**：删的都是「已被替代、永远不会被用到」的旧文件，微软官方支持在挂载镜像上做。
- 耗时 10~20 分钟，日志打印 `离线组件清理完成（N 分钟）`；失败只 `Write-Warning`，
  **不影响构建**，只是少省点空间。
- 跟 UUP 转换阶段那次 `ResetBase=1` **不重复**：那次是在打补丁前，这次是在
  LCU 集成 + Office/MAS/注册表改动之后，抓的是它的增量。

### ⑥ 体积诊断（清理后）

再测一次同样的 5 个目录，打印 `[size:清理后] ... (+/- N MB)`，和 ③ 相减就是净收益。

### ⑦ 禁用服务（离线 SYSTEM hive）

**写法**：加载镜像的 `Windows\System32\config\SYSTEM` 到 `HKLM\WWINBLDG_SYSTEM`，
对每个服务写 `HKLM\WWINBLDG_SYSTEM\ControlSet001\Services\<名>\Start = 4`（REG_DWORD）。

- 离线镜像**没有 `CurrentControlSet`**，所以只能改 `ControlSet001`（挂载后系统会同步）。
- 每个服务先 `reg query` 探一下，**镜像里不存在就跳过**，不报错。
- `Start` 含义：`2`=自动 `3`=手动 `4`=禁用。这里统一写 `4`。
- 用 `reg.exe add` 而不是 PowerShell 注册表提供程序：避免 PS 持有句柄导致 hive 卸不掉
  （卸不掉 → DISM 提交报 Error 32 文件占用）。

**实际禁用的清单（按类别，`Get-UupIso.ps1` 670–689 行）：**

| 类别 | 服务 | 为什么禁 |
| --- | --- | --- |
| 遥测 / 诊断 / 错误报告 | `DiagTrack` `dmwappushservice` `DPS` `WerSvc` `PcaSvc` `WdiServiceHost` `WdiSystemHost` `Wecsvc` | 上报使用数据、错误转储、兼容性助手，纯后台开销 |
| 位置 / 演示 / 家长控制 / 钱包 / 地图 | `lfsvc` `RetailDemo` `WPCSvc` `WalletService` `MapsBroker` | 商店演示机、离线地图下载，桌面机用不到 |
| 媒体网络共享 / WebDAV / BranchCache / P2P | `WMPNetworkSvc` `WebClient` `PeerDistSvc` `PeerNetUdp` | 局域网媒体共享、WebDAV 映射、P2P 分发；**不影响正常上网** |
| 传感器 / 智能卡 / 生物识别 | `SensrSvc` `SCardSvr` `WbioSrvc` | 台式机基本没有这些硬件 |
| 电话 / 传真 / 打印通知 | `PhoneSvc` `Fax` `PrintNotify` `PrintScanBrokerService` | **真正的打印 `Spooler` 保留**，禁的只是通知与扫描代理 |
| Xbox / Game Bar 社交后台 | `XblAuthManager` `XblGameSave` `XboxNetApiSvc` `XboxGipSvc` `XboxAccessoryManagementService` `GameBarFTServer` `GameDVR_Svc` | Xbox 账号联机与录制后台 |
| 设备元数据 / 推送安装 / 远程注册表 / 嵌入式 | `DevicesAnalytics` `PushToInstall` `RemoteRegistry` `EmbeddedMode` | 远程注册表是安全隐患，推送安装是商店静默装 |
| 远程桌面 USB 重定向 | `UmRdpService` | 只禁 USB 重定向，**`TermService` 保留，远程桌面照样能用** |

**刻意保留（改了会把系统搞坏或砍掉基础功能）：**

`Spooler`(打印) · `WinDefend` `SecurityHealthService` `WdNisSvc`(安全中心) ·
`wuauserv`(Windows 更新) · `TrustedInstaller` `AppXSvc` `StateRepository` `AppReadiness`(装应用) ·
`Themes`(主题) · `MpsSvc`(防火墙) · `LanmanServer` `LanmanWorkstation`(局域网共享) ·
`TermService`(远程桌面，`UmRdpService` 只禁 USB 重定向不影响连机) · `Netlogon` `KeyIso` `EventSystem`(账户/事件) ·
`msiserver`(MSI 安装) · `RasMan` `RasAuto`(VPN) · `WSearch` `SearchIndexer`(搜索) ·
`CDPUserSvc` `CDPSvc`(投屏/剪贴板同步) · `TabletInputService`(触摸键盘) · `SharedAccess`(移动热点) ·
`LSM` `RpcSs` `DcomLaunch`(系统核心) · `BrokerInfrastructure` `SystemEventsBroker`(后台任务)

> **历史包袱说明**：脚本里那个 700+ 项的巨型 `$servicesToDisable`（含 `LSASS` `EventLog`
> `PlugPlay` `SearchIndexer` 等**绝不能禁**的名字）是**死代码**——被后面这份正式清单整个覆盖掉了，
> 从未执行过。已经删掉，现在只剩上面这份安全清单。

### ⑧ 注册表优化（离线 SOFTWARE hive）

**写法**：加载 `Windows\System32\config\SOFTWARE` 到 `HKLM\WWINBLDG_SOFTWARE`，
代码里 `$hiveLabel\...` 拼出来的路径，**落盘就是 `HKLM\SOFTWARE\...`**（前缀 `WWINBLDG_SOFTWARE`
就是 SOFTWARE 根）。同样用 `reg.exe add` 写，写完 `reg.exe unload`，GC + 延时避免句柄残留。

下表路径省略公共前缀 `HKLM\SOFTWARE\`。

#### 遥测 / 诊断 / 隐私

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\Policies\DataCollection` | `AllowTelemetry=0` | 遥测只发安全数据（0 = Security） |
| `Microsoft\Windows\CurrentVersion\Policies\DataCollection` | `AllowDiagnosticData=0` | 禁用可选诊断数据 |
| `Policies\Microsoft\Windows\DataCollection` | `AllowTelemetry=0` | 同上，策略视图（GPO 读的是这个） |
| `Policies\Microsoft\Windows\DataCollection` | `AllowDiagnosticData=0` | 同上 |
| `Policies\Microsoft\SQMClient\Windows` | `CEIPEnable=0` | 关掉客户体验改进计划（后台采样） |
| `Policies\Microsoft\Windows Error Reporting` | `Disabled=1` | 关闭错误报告上传 |
| `Microsoft\Windows\Windows Error Reporting` | `Disabled=1` | 同上，应用视图 |
| `Policies\Microsoft\Windows\CloudContent` | `DisableWindowsConsumerFeatures=1` | 禁用「消费者功能」= 开始菜单推荐/广告应用 |
| `Microsoft\Windows\CurrentVersion\Policies\CloudContent` | `DisableWindowsConsumerFeatures=1` | 同上，非策略视图 |
| `Microsoft\Windows\CurrentVersion\DeliveryOptimization` | `DeviceUniqueId=""` | 清掉传递优化的设备唯一标识 |
| `Microsoft\Windows\CurrentVersion\DeliveryOptimization` | `CacheMemorySizeInBytes=0` | 不给 P2P 缓存分内存 |

#### 安全 / 防护

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\Policies\System` | `EnableLUA=1` | **保持 UAC 开**，不禁提权提示 |
| `Microsoft\Windows\CurrentVersion\Policies\System` | `EnableSmartScreen=0` | 关 SmartScreen 应用信誉云检查（少弹窗、断网不卡）；**要更强防护就改回 1** |
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableRealtimeMonitoring=0` | **保持 Defender 实时防护开**（0 = 不禁用） |
| `Microsoft\Windows\CurrentVersion\Policies\System` | `EnableTaskScheduler=1` | 保证计划任务调度器可用（很多功能依赖） |

#### 游戏 / 录制

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\GameBar` | `GameBarEnabled=0` | 关 Xbox Game Bar 覆盖层 |
| `Microsoft\GameBar` | `AutoGameModeEnabled=0` / `AllowAutoGameMode=0` | 不自动开游戏模式 |
| `Microsoft\GameBar` | `UseNexusForGameBarEnabled=0` | 关 Game Bar 的 Nexus 后端 |
| `Microsoft\Windows\CurrentVersion\GameConfigStore` | `GameDVR_Enabled=0` | 关后台录制（吃 CPU/磁盘） |
| `Policies\Microsoft\GameDVR` | `AllowGameDVR=0` | 策略层再关一次录制 |

#### 搜索 / Cortana / AI

| 键 | 值 | 原因 |
|---|---|---|
| `Policies\Microsoft\Windows\Windows Search` | `AllowCortana=0` | 关 Cortana |
| `Policies\Microsoft\Windows\Windows Search` | `AllowCortanaAboveLock=0` | 锁屏上也不起 Cortana |
| `Policies\Microsoft\Windows\Windows Search` | `ConnectedSearchUseWeb=0` | 本地搜索不联网（更快、不泄漏关键词） |
| `Policies\Microsoft\Windows\Windows Search` | `ConnectedSearchUseWebOverMeteredConnections=0` | 计费网络下更不联网 |
| `Policies\Microsoft\Windows\Windows Search` | `DisableAIDataAnalysis=1` | 禁用搜索内容的 AI 分析 |
| `Microsoft\Windows\CurrentVersion\Search` | `CortanaConsent=0` | 不征用 Cortana |
| `Microsoft\Windows\CurrentVersion\Search` | `SearchBoxTaskbarMode=1` | 用**经典搜索框**（2 = 纯图标，搜索框更大更卡） |
| `Microsoft\Windows\CurrentVersion\Search\Flighting` | `HyperPersonalization=0` | 关搜索个性化画像 |
| `Microsoft\Windows\CurrentVersion\Search\Flighting` | `ImmersiveSearch=0` | 关沉浸式（大）搜索面板 |
| `Policies\Microsoft\Windows\WindowsAI` | `RemoveMicrosoftCopilotApp=1` | 移除 Copilot 应用 |
| `Policies\Microsoft\Windows\WindowsAI` | `DisableAIActions=1` | 禁用 AI 操作（右键 AI 建议） |
| `Policies\Microsoft\Windows\WindowsAI` | `DisableClickToDo=1` | 禁用「即点即选」 |
| `Microsoft\Windows\CurrentVersion\WindowsAI` | `RemoveMicrosoftCopilotApp` / `DisableAIActions` / `DisableClickToDo` | 同上三项的非策略视图 |

#### 任务栏 / 外观 / 聊天

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarAl=0` | 任务栏**左对齐**（默认居中） |
| `Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowTaskViewButton=0` | 隐藏任务视图按钮 |
| `Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarAI=0` | 隐藏任务栏 AI 按钮 |
| `Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `DisableAIAnalytics=1` | 关任务栏 AI 使用分析 |
| `Microsoft\Windows\CurrentVersion\Policies\Explorer` | `HideChatIcon=1` | 隐藏聊天（Teams）图标 |
| `Policies\Microsoft\Windows\Windows Chat` | `ChatIcon=0` | 策略层再隐藏一次 |

#### 自动播放 / 自动运行

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\Policies\Explorer` | `NoAutoplayfornon-volume devices=1` | 非卷设备（手机/相机）不自动播放 |
| `Microsoft\Windows\CurrentVersion\Policies\Explorer` | `NoDriveTypeAutoRun=255` | 所有盘符类型禁 AutoRun |
| `Microsoft\Windows\CurrentVersion\Policies\Explorer` | `NoAutorun=1` | 禁 AutoRun（防 U 盘自动执行） |

#### 网络

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\NCSI` | `EnableActiveProbing=0` | 关 NCSI 主动探测（避免断网误判/频繁外联） |
| `Policies\Microsoft\Windows\DNSClient` | `DisableSmartNameResolution=1` | 不把未知域名交给 DNS 智能解析 |
| `Policies\Microsoft\Windows\DNSClient` | `DisableMulticast=1` | 关 DNS 多播（SSDP/网络发现噪音） |
| `Policies\Microsoft\Windows\DeliveryOptimization` | `DownloadMode=0` | 更新下载**只走 HTTP**，不做 P2P 上传 |

#### Windows 更新

| 键 | 值 | 原因 |
|---|---|---|
| `Policies\Microsoft\Windows\WindowsUpdate\AU` | `NoAutoUpdate=0` | **保持自动更新开**（0 = 不禁止） |
| `Policies\Microsoft\Windows\WindowsUpdate\AU` | `AUOptions=4` | 自动下载并自动安装 |
| `Policies\Microsoft\Windows\WindowsUpdate` | `DeferFeatureUpdatesPeriodInDays=0` | 不推迟功能更新 |
| `Policies\Microsoft\Windows\WindowsUpdate` | `DeferQualityUpdatesPeriodInDays=0` | 不推迟质量更新 |

#### 仅 Server SKU 会读的键（客户端上无效果，留着无害）

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\Server\ServerManager\Tasks\Startup` | `WindowsManagementInstrumentation=0` | 关服务器管理器启动任务 |

#### `skip_oobe` 打开时才写的三个键

| 键 | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\OOBE` | `BypassNRO=1` | OOBE **不再强制联网 + 登录微软账户**：断网时直接给「我没有互联网连接 → 创建本地账户」入口 |
| `Policies\Microsoft\Windows\OOBE` | `DisablePrivacyExperience=1` | 整页跳过隐私设置（位置/诊断/广告 ID…） |
| `Microsoft\Windows\CurrentVersion\Policies\System` | `EnableFirstLogonAnimation=0` | 去掉首登录转圈动画，进桌面更快 |

> 代码里有几对键被**写了两遍**（值相同，例如 `CacheMemorySizeInBytes`、`EnableSmartScreen`、
> `AllowCortana`）。`reg add /f` 是幂等的，重复写无副作用，只是日志里会出现两行。

## Office 365 离线集成（`office_offline`）

- **安装程序**：Office Deployment Tool (ODT)，官方直链，Action 构建时下载
  `https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20326-20112.exe`
- **版本**：`O365ProPlusRetail` = **Microsoft 365 企业版（Apps for enterprise）**，64 位，`Channel=MonthlyEnterprise`
- **语言写死 `zh-cn`**：不能用 `MatchOS`——它是「按运行 `setup.exe` 的那台机器的语言」在
  **下载阶段**就解析掉，GitHub runner 是 en-US，会下成英文包，装到 zh-CN 目标机上 ODT
  就得联网补语言，离线集成就废了
- **只装三件套**：`ExcludeApp` 掉 `Access` `Groove` `Lync` `OneDrive` `OneNote` `Outlook` `Publisher` `Teams`
- **剔除 arm64 交叉部件**：ODT 会顺带下 `stream.x64.x-none.arm64x.dat`(+`.cat`)，
  那是给 ARM64 设备用的。**断网 A/B 实测删掉后 `setup /configure` 仍然 exit=0、三件套齐全、
  反而更快（130s vs 140s）**，净省 **451.4 MB**
- **下载时机**：`Start-Job` 在 **UUP 下载/转换之前**就启动，与转换**并行**；主流程一边转换一边
  `Receive-Job` 把输出打进日志，最多等 120 分钟。没跑成就本地补跑一次（可续传）。
- **数据目录布局**：实测 16.0.20326 的 ODT 写的是 `<SourcePath>\Office\Data\<版本>\`
  （不是旧文档说的 `OfficeData\`）；脚本两种布局都认，统一归一成 `Office\Data\`，
  这样镜像内配置里的 `SourcePath="C:\OfficeInstall"` 永远对得上
- **集成方式**：把 `setup.exe` + `configuration.xml` + `Office\Data\<版本>` 拷进镜像根的
  `C:\OfficeInstall`，实测约 **3174 MB**
- **安装时机**：`SetupComplete.cmd`（OOBE 结束后、SYSTEM 权限）后台启动
  `setup.exe /configure`，`FirstBoot.ps1` 首次登录时轮询等待（上限 60 分钟）
- **装完自动清理**：确认 `C:\Program Files\Microsoft Office\root\Office16\` 下
  `WINWORD.EXE` / `EXCEL.EXE` / `POWERPNT.EXE` 三个都在 → 删掉 `C:\OfficeInstall`
  （释放约 3.6 GB，先等 20 秒让 Click-To-Run 放掉文件句柄，失败重试 3 次）；
  **装失败就保留**，那是唯一的离线安装源，删了就补不回来
- **任何失败都只 `Write-Warning`，绝不拖垮已经跑了一个多小时的镜像构建**

## MAS 激活（`mas_activate`）

- **下载**：构建时从官方仓库原始文件下载
  `https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/All-In-One-Version-KL/MAS_AIO.cmd`
- **放置**：镜像根的 `\MAS\MAS_AIO.cmd` → 装完就是 `C:\MAS\MAS_AIO.cmd`
- **触发**：`FirstBoot.ps1` 在**等 Office 装完 + 清理安装包之后**运行
  （`cmd /c C:\MAS\MAS_AIO.cmd`，`-Wait` 阻塞到脚本结束）
- **激活方式**：Windows 走 HWID 永久激活，Office 走 KMS（由 MAS 自己选参数）
- **风险提示**：`MAS_AIO.cmd` 是第三方脚本，Defender 可能报「hacktool」，
  这是误报性质的提示，介意就关掉 `mas_activate` 开关

## 首登录编排器（`SetupComplete.cmd` + `FirstBoot.ps1`）

**触发链：**

1. OOBE 完成 → `C:\Windows\Setup\Scripts\SetupComplete.cmd` 被系统以 **SYSTEM** 权限执行
2. `SetupComplete.cmd`：`start "" /MIN C:\OfficeInstall\setup.exe /configure ...`（Office **后台最小化**静默安装）
3. `SetupComplete.cmd`：写 `HKLM\...\RunOnce\SYSTEM_Intel_MIC_FirstBoot` →
   `powershell -NoProfile -ExecutionPolicy Bypass -File C:\FirstBoot\FirstBoot.ps1`
4. 用户首次登录 → `RunOnce` 触发 `FirstBoot.ps1`（用户桌面会话）
5. `FirstBoot.ps1` 先**自删** `RunOnce`（只跑一次），弹出**置顶、不可关闭**的窗口：
   标题 `SYSTEM-Intel-MIC 优化版 Windows 11`，正文显示构建信息与 B 站主页
   `https://space.bilibili.com/1978487514`
6. 轮询 `setup.exe`（按 `ExecutablePath -like 'C:\OfficeInstall\*'` 判断，15 秒一次，上限 60 分钟），
   状态栏持续显示 **「正在安装 Office 365 (Word/Excel/PowerPoint)，请勿关机或断电...」**
   —— 如果 `SetupComplete` 那边没起来，这里会**补启动一次**
7. 安装结束 → 校验三件套 → **清理 `C:\OfficeInstall`（释放约 3.6 GB）** → 状态栏显示「已清理安装包」
8. 运行 `MAS_AIO.cmd` 激活 Windows + Office
9. 状态栏显示「✅ 全部完成！Windows + Office 已激活，Office 已安装」→ 3 秒后自动关窗

> 为什么弹窗放在 `FirstBoot.ps1` 而不是 `SetupComplete.cmd`：后者跑在 SYSTEM 会话里，
> **桌面用户看不见它的 GUI**；`FirstBoot.ps1` 跑在用户会话里，弹窗才有效。

## 体积优化（实测数据）

目标：**分卷 ≤ 2 GB、总体积尽量靠近 8 GB，且不砍功能。**

| 手段 | 节省 | 状态 |
|---|---|---|
| ESD 重打包（`wimlib-imagex export` → solid LZMS） | **−1717 MB**（10445 → 8728 MB，耗时 4413 秒） | ✅ 实测 |
| 剔除 arm64 交叉部件（Office 包内） | **−451 MB** | ✅ 实测 |
| `ResetBase`（UUP 转换阶段） | 基线的一部分 | ✅ 开着 |
| Appx 白名单瘦身 | −28 MB（28020 上多数目标包本就没 provision） | ✅ 实测 |
| 离线 `StartComponentCleanup /ResetBase` | 预期几百 MB | 🔄 待本轮实测 |
| 可选功能移除（XPS/传真/SMB1/…） | 预期 200~500 MB | 🔄 待本轮实测 |
| **合计（前三项）** | 基线 11895 MB → **9755 MB**，省 **2140 MB（18%）** | ✅ |

**ESD 的实现位置与保护：**

- 在 `Invoke-IsoReseal` 里、**autounattend 注入与 OEM logo 注入之后**、`cdimage` 封盘**之前**执行，
  所以精简 / Office / MAS / logo 这些功能**一个都不会失效**
- 用 `wimlib-imagex export` 单镜像导出，`Start-Process` + `WaitForExit`，
  **上限 90 分钟**；超时或失败 → **自动回退成 wim 封盘**，构建不中断
- **不做 `/CheckIntegrity`**：对 9 GB 源全量校验要多花几十分钟，纯浪费
- UUP dump 阶段**不开 `wim2esd`**（转换阶段开会让镜像先压一遍、精简时又得挂载 wim，白折腾）
- `cdimage` 参数 `-o -m -u2 -udfver102`：`-m` = LZMA 压缩，`-u2` = exact snapshot，`-udfver102`

## 产物

Release 标签形如 `Win11_28020-insider_x64_zh-CN_enterprise_28020.3142_20261005`：

```
xxx.iso.zip.001   2000 MB
xxx.iso.zip.002   2000 MB
xxx.iso.zip.003   2000 MB
xxx.iso.zip.004   2000 MB
xxx.iso.zip.005   ~1.7 GB      ← 实测 9755 MB / 5 卷
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

- **磁盘**：Server 2025 镜像没有 D 盘，可用空间约 33 GB。工作流会先挑剩余空间最大的盘、
  删掉用不到的预装软件，构建成功后立刻删工作目录、分卷后删原始 ISO。
  开 `unattend` 时会先把 `UUPs/`（几个 GB 下载缓存）删掉腾地方。
- **时长（实测）**：UUP 下载 + 转换约 50 分钟，离线定制 + Office 集成约 15 分钟，
  ESD 重打包约 74 分钟，封盘 + 校验 + 分卷约 20 分钟 → **总计约 144 分钟**；
  加上离线组件清理（10~20 分钟）与两次体积扫描（约 6 分钟）约 **165 分钟**。
  作业上限 6 小时。
- **额度**：私有仓库 Windows runner 消耗 2 倍分钟；公开仓库免费但代码公开。
- **预览版镜像**仅供测试，别当生产机用；想要稳定就 `channel=stable` + `build=26300`（26H2 正式版）。
- **UUP dump** 是第三方站点（[源码](https://git.uupdump.net/uup-dump)），文件全部来自微软
  Windows Update 服务器；站点偶尔抖动，脚本内置 8 次指数退避重试。
- 如果 UUP 文件已被微软下架，构建会失败并打印日志最后 200 行；完整日志见作业输出里的 `uup_build.log`。
- 企业版由专业版派生（UUP dump 官方机制），装出来的是正规企业版 SKU，与零售渠道无关。
- **计划任务没有被禁用**：早期文档写过 `FirstBoot.ps1` 会 `Disable-ScheduledTask`，
  **实际从未实现**（`FirstBoot.ps1` 只做 Office 等待/清理 + 激活 + 弹窗）。要禁得自己加。
- **`skip_apps` 别开**：它会让镜像**没有商店、没有内置 Appx**，与「保留 Edge/商店/照片」直接冲突。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `UUP dump API xxx 连续 8 次请求失败` | 站点抖动，稍后重跑 |
| `UUP dump 上没有符合条件的构建` | 构建号和通道对不上（如 `26220` 配 `stable` 就没有）；报错里会列出实际搜到的标题 |
| `没有生成 ISO` | 看作业日志尾部 200 行；磁盘不足先关 `reset_base`，或关掉 `esd` |
| `cdimage 重新封盘失败` | 看 `_iso_repack.log`；多为磁盘不足，先关 `reset_base` / `esd` 腾空间，或临时关 `unattend` |
| `重新封盘的 ISO 里没有 autounattend.xml` / `没有 boot.wim` | 说明 `cdimage` 产物不完整，基本是空间不足，同上处理 |
| ESD 重打包卡住很久 | 单镜像导出上限 90 分钟，超时会**自动回退 wim**；日志看 `ESD 重打包完成` 或回退警告 |
| `Unattend 已开启但没有任何可写入的设置` | `unattend` 开着但 `hw_bypass` / `skip_oobe` / `oem_*` 全空，要么补字段要么关 `unattend` |
| `wimlib 注入 OEM logo 到第 N 个镜像失败` | 检查 `OEM/logo.bmp` 是否损坏；或开 `esd` / `wim2swm` 时不会有 `install.wim`（会降级成警告而非报错） |
| 装到「此电脑不符合 Windows 11 要求」被拦 | `LabConfig` 在 28020 上未实测；关掉 `hw_bypass` 重跑（`unattend` 保持开） |
| 首次开机没弹 Office 安装窗口 | 看 `C:\OfficeInstall` 是否存在；三件套不全时脚本会保留安装包供手动 `setup /configure` |
| 想知道某个包/服务/功能为什么还在 | 日志里搜 `[keep]`（Appx 保留判定）、`[feature]`（可选功能全表）、`[size:清理前]`（体积分布） |
| `找不到 PROFESSIONAL` / 语言包 | 该构建暂未提供 zh-cn 或对应版本，换个构建号 |
| 分卷上传失败 | 确认 workflow 有 `permissions: contents: write`（已内置），token 未过期 |
