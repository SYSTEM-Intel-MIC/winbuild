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
   `SetupComplete.cmd` + `C:\FirstBoot\{Activate.cmd, Cleanup.ps1, FirstBoot.ps1}` → 提交卸载
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
| `updates` | 开关 | **false** | 集成最新累积更新（UUP dump 下载更新包）。**默认关**：LCU/Enablement/SSU/NetFx/SetupDU/SafeOSDU 会让镜像涨 1~2 GB |
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
| `oem_provider` | 文本 | **`SYSTEM-Intel-MIC的B站个人主页`** | `SupportProvider`：「获取帮助」按钮上显示的支持提供方名称（Win11 用它覆盖 System Manufacturer） |
| `oem_url` | 文本 | **`https://space.bilibili.com/1978487514`** | `SupportURL`：「获取帮助」跳转链接；缺协议头会自动补 `https://` |
| `oem_manufacturer` | 文本 | **`SYSTEM-Intel-MIC`** | `Manufacturer`（已弃用，只写注册表，Win11「设置→关于」不再显示） |
| `oem_logo` | 文本 | *（空）* | `Logo` 路径；留空且仓库有 `OEM/logo.bmp` 时自动用 `C:\Windows\System32\oemlogo.bmp` 并把文件塞进 `install.wim` |
| `oem_phone` | 文本 | *（空）* | `SupportPhone`（已弃用） |
| `deep_debloat` | 开关 | **true** | 离线精简 `install.wim`：Appx 白名单+强删名单 + Capability 模糊匹配 + 可选功能移除 + 组件清理 + 注册表 + 服务 + 删更新类计划任务 |
| `office_offline` | 开关 | **true** | 离线集成 Office 365（Word/Excel/PowerPoint），ODT + 离线包在 Action 下载，首登录自动安装 |
| `mas_activate` | 开关 | **true** | SYSTEM 后台等 Office 装完 + 等联网后，无人值守跑 MAS `/HWID` + `/Ohook` |
| `perf_tweaks` | 开关 | **true** | 见下方「四个精简开关的门控关系」 |

共 **24 个输入**，全部默认值就是当前线上跑通的组合。

> 脚本 `Get-UupIso.ps1` 还支持 `-LocalUser` / `-LocalPassword` / `-OemModel`，
> 但 workflow **没有暴露成输入**，所以现在恒为空 = 不预建账户（OOBE 里手动建）、不写 `Model`。

### 四个精简开关的门控关系（重要）

```
任一开关为真 ──┐
  deep_debloat ─┼──> 进入 Invoke-OfflineCustomization（挂载 install.wim 做下面 ①~⑧b 全部动作）
  office_offline ┘
  mas_activate
  perf_tweaks
```

- **`deep_debloat` 单独关掉是不够的**：只要 `office_offline` / `mas_activate` / `perf_tweaks`
  还开着，脚本照样会进离线定制，①~⑧b 的精简动作（Appx / Capability / 可选功能 / 组件清理 /
  服务 / 注册表 / DEFAULT hive / 计划任务）**也会一并执行**——这几步在函数内部没有再按
  `deep_debloat` 二次判断。
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
| `windowsPE` | **无条件**执行 3 条 `RunSynchronous`：往 PE 注册表写 `AU\NoAutoUpdate=1` / `AUOptions=2` / `AutoInstallMinorUpdates=0`（拦住**安装会话内**的检查更新） | 无开关（恒定执行） |
| `oobeSystem` | `OOBE`：`HideEULAPage` / `HideOEMRegistrationScreen` / `HideOnlineAccountScreens` / `HideWirelessSetupInOOBE` / `ProtectYourPC=3`；`OEMInformation`、`RegisteredOrganization`、`TimeZone=China Standard Time` | `skip_oobe` / `oem_*` |

> **每条 `RunSynchronous` 都被包成了 `cmd /c "…" & exit 0`，原因见下面「行为边界」第 3 条。**
>
> **编码：`autounattend.xml` 用 `Set-Content -Encoding utf8BOM` 写出**（UTF-8 带 BOM），
> 与文件头的 `<?xml version="1.0" encoding="utf-8"?>` 严格一致。文件里有中文
> （`OemProvider` = `SYSTEM-Intel-MIC的B站个人主页`），**不带 BOM 的 UTF-8** 会被
> Setup 按当前 ANSI 代码页去解：轻则「获取帮助」里那行字变成乱码，重则整份应答文件
> 解析不出无人值守设置（装完系统发现 OOBE 没跳过、OEM 信息没写上）。

`LabConfig` 三个键的写法（实际执行的是 `cmd /c "reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f & exit 0"`）：

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
- **⚠ `windowsPE` 阶段的 `RunSynchronous` 只要有一条返回非 0，整个安装就会中止**，
  报「Windows 安装遇到错误。错误代码: `0x80070002 - 0x40030`」（`0x80070002` = 找不到文件，
  `0x40030` = 卡在「应用 WinPE 应答文件」这一步）。实测踩过的坑：以前这里有一条
  `sc config wuauserv start= disabled`，而 **WinPE 里根本没有 `sc.exe`**，Setup 用
  CreateProcess 去找 `sc.exe` → `ERROR_FILE_NOT_FOUND` → 安装直接失败（只能用 DISM++
  暴力装机）。修法两条：① 删掉这条；② 每条命令都套上 `cmd /c "… & exit 0"`，
  保证就算 `reg add` 因为意外返回非 0 也不会拖垮安装——反正 WinPE 的注册表是内存盘，
  重启就丢，命令成不成功都影响不到成品。
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
foreach ($k in $keep)       { if ($app -like "*$k*") { $shouldKeep = $true;  break } }  # 白名单：命中就留
foreach ($f in $forceRemove){ if ($app -like "*$f*") { $shouldKeep = $false; break } }  # 强删名单：命中就删（优先级更高）
if ($shouldKeep) { Write-Host "[keep] $app"; continue }   # 保留
dism /Remove-ProvisionedAppxPackage /PackageName:$app      # 其余全部移除
```

- `$keep` 是**纯保留白名单**，匹配方式是**包含匹配**（`*关键词*`），不是精确匹配；
  **没命中的一律删除**。
- `$forceRemove` 是**强删名单，优先级高于 `$keep`**：哪怕包名恰好撞上保留关键词，
  只要命中强删名单就一定删，用来堵死「该删没删」的漏洞。
- 日志里每个包都会打印一行 `[keep]`（保留）或 `[fail]`（移除失败 + 退出码），
  **要看镜像里到底 provision 了哪些包，直接翻日志的 `[keep]` 列表**，不用猜。

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
**`$forceRemove` 强删名单（命中必删，优先级高于 `$keep`）：**

| 分组 | 关键词 | 你为什么点名要删 |
| --- | --- | --- |
| 装机实测还留着的 | `Xbox` `GamingApp` `MicrosoftSolitaireCollection` `BingNews` `YourPhone` `GetHelp` | Xbox 全家 / 纸牌 / 微软资讯 / 手机连接 / 获取帮助 |
| 通讯 / 网盘 | `MSTeams` `Teams` `OutlookForWindows` `Outlook` `OneDrive` | Teams、新版 Outlook、OneDrive |
| 反馈 / 推广 | `WindowsFeedbackHub` `MicrosoftOfficeHub` `Getstarted` `BingWeather` `CrossDevice` | 反馈中心、Office 推广、入门、天气、跨设备协同 |
| 预装垃圾 | `StickyNotes` `Todos` `Clipchamp` `SoundRecorder` `MicrosoftFamily` `QuickAssist` `WebExperience` `People` `Print3D` `3DViewer` `MixedReality` `Cortana` `WindowsMaps` `Maps` `WindowsWallet` `Wallet` `WindowsCommunicationsApps` | 便笺 / 待办 / AI 剪辑 / 录音机 / 家庭 / 快速助手 / 小组件前端 / 人脉 / 3D / 混合现实 / 小娜 / 地图 / 钱包 / 旧版邮件日历 |
| 点名卸载的系统应用 | `WindowsBackup` `Backup` `SecHealthUI` | Windows 备份 / Windows 安全中心（离线删不掉，见下） |

> **⚠ `Getstarted`（入门）/ `WindowsBackup`（Windows 备份）/ `SecHealthUI`（安全中心）
> 在离线的 provisioned 列表里根本不存在**（构建日志 grep 计数 = 0），上面这行强删
> 属于「碰到了就删」的兜底，**真正把它们卸掉的是装机后的 `Cleanup.ps1`** ——
> 装完系统系统跑起来之后，以 SYSTEM 身份在线 `Get-AppxPackage -AllUsers` + 
> `Get-AppxProvisionedPackage -Online` 删。详见「装机后在线清理」一节。

**①b OneDrive 是系统级的，不走 Appx（离线做一遍，装机后再在线兜底一遍）：**

| 动作 | 路径 | 为什么 |
| --- | --- | --- |
| 删安装器 | `Windows\System32\OneDriveSetup.exe`、`Windows\SysWOW64\OneDriveSetup.exe` | Win11 首次登录会自动跑它把 OneDrive 装回来 |
| 删已解包目录 | `Program Files\Microsoft OneDrive`、`Program Files (x86)\Microsoft OneDrive` | 镜像里通常还没有，存在才删 |
| 删 `Run` 启动项 | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup` 与 `Wow6432Node` 下同名值 | 注册表里 `Type = 'Delete'` 走 `reg delete` |
| **删默认用户 `Run` 启动项**（见 ⑧a） | `C:\Users\Default\NTUSER.DAT` 里的 `HKCU\...\Run\OneDriveSetup` / `OneDrive` | **每个新账户的 HKCU 都是从默认用户拷出来的**，这才是首次登录自动装 OneDrive 的真正触发点 |

> **为什么还要在线兜底**：构建日志里「已删除注册表值」= 0 条、也没有任何 OneDrive 相关行，
> 说明离线这两步很可能**一条都没命中**（HKLM `Run` 里没有 `OneDriveSetup`）。所以
> `Cleanup.ps1` 装机后再跑一遍：`OneDriveSetup.exe /uninstall` + 扫 HKLM `Run` / `WOW6432Node\Run`
> 含 `OneDrive` 的值 + `takeown`/`icacls` 后清 `C:\Users\*\AppData\Local\Microsoft OneDrive` 等残留。

> **修复记录（装机实测）：** 上一版把 `Xbox` `Solitaire` `BingNews` `YourPhone` `GetHelp`
> `FeedbackHub` `OfficeHub` `StickyNotes` `Todos` `Clipchamp` `MSTeams` `Outlook` 等**垃圾关键词
> 写进了 `$keep`**，包含匹配把它们全保住了 —— 装机后 Xbox/纸牌/资讯/手机连接/获取帮助全都还在，
> 日志 116 行 `[keep]` 却只删掉 6 个包。现在 `$keep` 只留必要项，并用 `$forceRemove` 兜底。
> 删掉的都能从应用商店装回来，不影响系统功能。

### ② 移除 AI / Copilot / Recall（Capability）

**实现方式：先 `/Get-Capabilities` 打出镜像内**全部** capability（日志逐条 `[cap] xxx`），
再按关键词**模糊匹配**移除。**

> **为什么从「写死名字」改成「模糊匹配」**：上一版是精确写死 6 个名字，结果 build 28020 上
> `Recall` **根本没被删掉**（名字对得上但列表里漏了），AI 平台的其它子项也全留着。
> 模糊匹配 + 打印全表，日志里能直接核对删了什么、还剩什么。

| 匹配关键词 | 删掉的东西 |
| --- | --- |
| `Recall` | 屏幕记录 + AI 回溯（隐私争议最大） |
| `Copilot` | Copilot 全部能力（`Microsoft.Copilot`、`Microsoft.Windows.AI.Copilot.Provider` 一并覆盖） |
| `Clipchamp` | AI 视频剪辑 |
| `Photos.AI` | 照片 AI 抠图/修饰 |
| `AppRuntime.AI` | AI 运行时分发 |
| `Microsoft.Windows.AI` / `Microsoft.Windows.Ai` | Windows AI 平台全家（`Ai.Clients` / `Ai.Foundation` / `Ai.Actions` …） |
| `SemanticIndex` | 语义索引（Recall / AI 搜索的后端） |
| `MathRecognizer` | 手写公式 AI 识别 |
| `AIFoundry` `AiFoundry` `WindowsAI` | Windows AI Foundry |
| `DevHome` | 开发者主页（预装无效应用） |

> 匹配不到**不会报错**；解析不出 capability 列表时会 `Write-Warning` 提示「AI 组件可能没删干净」。
> 解析用的是宽松的 `Identity : (.+)`，防 DISM 字段名随版本变动导致一条都匹配不上。
> **不在清单里**：`Language.OCR` / `Language.Handwriting` / TTS 这类**输入法与辅助功能**能力，
> 删了会废掉截图工具的「文本提取」、语音输入和讲述人，所以保留。

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
| `ServicesForNFS` `NFS-Administration` | NFS 客户端/管理 | NFS 是局域网 Unix 共享，家用基本不用 |
| **`IIS-`** | **IIS Web 服务器全套（28020 上有 51 个 `IIS-*`）** | 桌面机不会架站；体积大头之一 |
| **`WAS-`** | IIS 进程激活服务（`WAS-ConfigurationAPI` `WAS-ProcessModel` `WAS-WindowsActivationService`） | 随 IIS 走 |
| **`MSMQ-`** | 消息队列 7 项 | 企业中间件，桌面用不到 |
| **`WCF-`** | WCF 服务/激活 6 项 | 同上，WCF 自承载场景 |
| **`Client-`** | 嵌入式锁定设备 7 项（Kiosk / 键盘过滤 / UWF / Embedded 登录…） | 只有售货机、展台设备用 |
| **`MultiPoint`** | MultiPoint 多点服务 3 项 | 教室一拖多场景 |
| **`Sysmon`** `Sysmon-Service` | 系统监视器 | 需要时可单独装回 |
| `HostGuardian` | 主机守护服务（HGS） | 虚拟化安全隔离，家用用不到 |
| `AppServerClient` | 远程应用（RemoteApp）客户端 | 很少用；`MSRDC` 远程桌面客户端**保留** |
| `NetFx4-AdvSrvs` `NetFx4Extended-ASPNET45` | .NET 高级服务 / ASP.NET 4.5 扩展 | 服务端扩展，桌面用不到 |
| `SmbDirect` | RDMA 网卡直连 | 需要万兆 RDMA 网卡才用得上 |
| `InternetPrinting` | 互联网打印（IPP 服务器） | **本地打印与「另存为 PDF」是另外两个 feature，不受影响** |
| `Recall` | AI 回溯功能位 | AI 组件，必须删 |

**反向白名单 `$featuresKeep`（即使命中上面的关键词也绝不删）：**

`DirectPlay` `LegacyComponents`（老游戏）· `MediaPlayback` `WindowsMediaPlayer`（**用户点名**）·
`SearchEngine`（开始菜单搜索）· `Windows-Defender` · `Printing-Foundation-Features` `PrintToPDF` ·
`MSRDC`（远程桌面客户端）· `TIFFIFilter`（TIFF 预览）· `Containers` `Hyper-V` `HypervisorPlatform`
`VirtualMachinePlatform` `Subsystem-Linux`（Docker / WSL / 虚拟机）· `Camera`

**铁律：下面这些绝不出现在删除清单里** —— 媒体播放器 / `MediaFoundation` / 编解码器 /
`.NET 3.5` / IE 模式（Edge 依赖）/ 搜索 / 远程桌面 / `OpenSSH.Client` / 打印与 PDF /
Hyper-V 与 WSL。清单里的关键词**匹配不到就跳过**，不会报错。

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

**实际禁用的清单（按类别）：**

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
| Windows Insider / 扫描仪 | `wisvc` `stisvc` | Insider 注册服务（已经是预览版，不必再上报通道）；WIA 扫描仪服务（没有扫描仪）。**`Spooler` 保留，打印不受影响** |
| **Windows 安全中心 / Defender** | `WinDefend` `WdNisSvc` `SecurityHealthService` `Sense` | 用户点名「禁用 Windows 安全中心（最好直接卸载）」。`WinDefend`＝Defender 主服务（实时防护），`WdNisSvc`＝网络检测，`SecurityHealthService`＝「Windows 安全中心」UI 的后端（托盘图标靠它），`Sense`＝Defender for Endpoint 云端连接。四个全禁 + 下面的策略键 → 安全中心打不开、托盘不再弹提醒；**真正的「卸载」（删 `SecHealthUI` 应用包）在装完机后由 `Cleanup.ps1` 在线做**，离线 `/Remove-ProvisionedAppxPackage` 会报 `0x80073CFA`（退出码 15610） |

**刻意保留（改了会把系统搞坏或砍掉基础功能）：**

`Spooler`(打印) ·
`wuauserv`(Windows 更新) · `TrustedInstaller` `AppXSvc` `StateRepository` `AppReadiness`(装应用) ·
`Themes`(主题) · `MpsSvc`(防火墙) · `LanmanServer` `LanmanWorkstation`(局域网共享) ·
`TermService`(远程桌面，`UmRdpService` 只禁 USB 重定向不影响连机) · `Netlogon` `KeyIso` `EventSystem`(账户/事件) ·
`msiserver`(MSI 安装) · `RasMan` `RasAuto`(VPN) · `WSearch` `SearchIndexer`(搜索) ·
`CDPUserSvc` `CDPSvc`(投屏/剪贴板同步) · `TabletInputService`(触摸键盘) · `SharedAccess`(移动热点) ·
`LSM` `RpcSs` `DcomLaunch`(系统核心) · `BrokerInfrastructure` `SystemEventsBroker`(后台任务)

> **注意**：`WinDefend` / `SecurityHealthService` / `WdNisSvc` 以前在「刻意保留」名单里，
> 现在已按用户要求移到禁用名单（见上表最后一行）。

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
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableRealtimeMonitoring=1` | **关掉 Defender 实时防护**（用户点名禁用/卸载安全中心；上一版写的是 `0`＝保持开启，已翻转） |
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableBehaviorMonitoring=1` | 关掉行为防护（同上，关掉 Defender 的一整套实时能力） |
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableOnAccessProtection=1` | 关掉「打开文件时扫描」 |
| `Policies\Microsoft\Windows Defender\Real-Time Protection` | `DisableScanOnRealtimeEnable=1` | 关掉实时扫描 |
| `Policies\Microsoft\Windows Defender` | `DisableAntiSpyware=1` `DisableAntiVirus=1` | 组策略级总开关；Win11 仍会读这两个键，配合服务禁用把 Defender 彻底钉死 |
| `Policies\Microsoft\Windows Defender` | `DisableRoutinelyTakingAction=1` | 不让 Defender 自作主张做「定期处理」（隔离/修复） |
| `Policies\Microsoft\Windows Defender\Signature Update` | `DisableUpdateOnStartupWithoutEngine=1` | 没有引擎就不去拉签名更新 |
| `Policies\Microsoft\Windows Defender Security Center\Systray` | `DisableNotifications=1` | 「Windows 安全中心」托盘不再弹任何提醒 |
| `Policies\Microsoft\Windows Defender Security Center` | `DisableUI=1` | 策略层禁用安全中心界面 |
| `Microsoft\Windows Defender\Features` | `TamperProtection=0` | **关掉「篡改保护」**——不先关它，上面这些策略键在线会被 Defender 自己改回去，`SecHealthUI` 也删不掉 |
| `Microsoft\Windows Defender` | `DisableAntiSpyware=1` | 非策略视图再写一次（老键，部分组件读这个） |
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

#### Windows 更新（**硬需求：不允许自动更新，OOBE 也不更新；手动检查更新保留**）

| 键 | 值 | 原因 |
|---|---|---|
| `Policies\Microsoft\Windows\WindowsUpdate\AU` | `NoAutoUpdate=1` | **关掉自动检查/下载/安装**；设置里手动「检查更新」仍然可用 |
| `Policies\Microsoft\Windows\WindowsUpdate\AU` | `AUOptions=2` | 兜底：就算策略被绕过，也只「通知下载并通知安装」 |
| `Policies\Microsoft\Windows\WindowsUpdate\AU` | `AutoInstallMinorUpdates=0` | 连小更新都不许悄悄装 |
| `Policies\Microsoft\Windows\WindowsUpdate` | `DeferFeatureUpdatesPeriodInDays=400` | 功能更新推迟 400 天（约等于永不来） |
| `Policies\Microsoft\Windows\WindowsUpdate` | `DeferQualityUpdatesPeriodInDays=400` | 质量更新同上 |
| `Policies\Microsoft\Windows\WindowsUpdate` | `NoAutoRebootWithLoggedOnUsers=1` | 就算有更新也不许自动重启 |
| `Policies\Microsoft\Windows\WindowsUpdate` | `ExcludeWUDriversInQualityUpdate=1` | Windows Update 不自动装驱动（要驱动用 `drivers` 开关离线注入） |
| `Policies\Microsoft\WindowsStore` | `DisableAutoUpdate=1` | **商店也不许自己更新**，否则被删的预装 Appx 可能被推回来 |

> 三条防线合起来：**① 离线注册表（上表）**、**② 应答文件 `windowsPE` 关掉 PE 的 `wuauserv`
> + 写 AU 策略**（拦安装期的 Setup DU 和 OOBE 检查）、**③ 删掉会自己跑更新的计划任务**（见 ⑧b）。
> `wuauserv` 与 `WaaSMedicSvc` **刻意不禁用** —— 禁了手动更新就废了，你要的是「不自动」不是「不能」。

#### 广告 / 推广 / 预留空间 / 活动历史

| 键 | 值 | 原因 |
|---|---|---|
| `Policies\Microsoft\Windows\CloudContent` | `DisableWindowsSpotlightFeatures=1` | 关锁屏「Windows 聚焦」壁纸轮播（省网络与后台） |
| `Policies\Microsoft\Windows\CloudContent` | `DisableWindowsSpotlightOnSettings=1` / `DisableWindowsSpotlightOnActionCenter=1` | 设置页与操作中心不再推聚焦图 |
| `Policies\Microsoft\Windows\CloudContent` | `DisableSoftLanding=1` | 开始菜单不再推「提示和建议」 |
| `Policies\Microsoft\Windows\CloudContent` | `DisableThirdPartySuggestions=1` | 不推第三方应用建议 |
| `Policies\Microsoft\Windows\CloudContent` | `DisableTailoredExperiencesWithDiagnosticData=1` | 不用诊断数据做个性化推荐 |
| `Policies\Microsoft\Windows\AdvertisingInfo` | `DisabledByGroupPolicy=1` | 关广告 ID（个性化广告） |
| `Policies\Microsoft\Windows\System` | `EnableActivityFeed=0` `PublishUserActivities=0` `UploadUserActivities=0` | 关活动历史记录（时间线 + 云端同步用户操作） |
| `Microsoft\Windows\CurrentVersion\ReserveManager` | `ShippedWithReserves=0` | 关掉 C 盘**约 7 GB 的「更新预留空间」** |
| `Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SilentInstalledAppsEnabled=0` `PreInstalledAppsEnabled=0` `OemPreInstalledAppsEnabled=0` | HKLM 版静默装应用开关（与 ⑧a 的 HKCU 版双保险） |
| `Microsoft\Windows\CurrentVersion\Run` | `OneDriveSetup` **删值**（`Type='Delete'`，`Wow6432Node` 下同样删） | 阻止首次登录自动装 OneDrive |

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

#### ⑧a DEFAULT 用户 hive（**新用户首次登录的 `HKCU` 默认值**）

Windows 新建账户时会拷贝 `C:\Users\Default\NTUSER.DAT` 当模板，所以写进这里的值
**对之后创建的每个账户都生效**。上面那张 HKLM 表里有一半优化（任务栏、资源管理器、
静默装应用、广告 ID）其实落在 `HKCU`，只写 HKLM 是**白写**的，这一节补上。

**写法**：`reg load HKLM\WWINBLDG_DEFAULT <镜像>\Users\Default\NTUSER.DAT`
→ 写 `HKLM\WWINBLDG_DEFAULT\Software\...`（**落盘就是 `HKCU\Software\...`**）→ `reg unload`。
load 失败只 `Write-Warning` 跳过，不影响构建。

| 键（`HKCU\Software\` 下） | 值 | 原因 |
|---|---|---|
| `Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SilentInstalledAppsEnabled=0` `PreInstalledAppsEnabled=0` `OemPreInstalledAppsEnabled=0` | **不静默给新账户塞应用**（「装完自己又冒出一堆 Appx」的元凶） |
| 同上 | `SystemPaneSuggestionsEnabled=0` `SubscribedContent-338388Enabled=0` `SubscribedContent-338389Enabled=0` `SubscribedContent-338393Enabled=0` | 开始菜单「推荐的项目」与应用推广 |
| 同上 | `RotatingLockScreenOverlayEnabled=0` | 锁屏不叠加聚焦内容 |
| `Microsoft\Windows\CurrentVersion\AdvertisingInfo` | `Enabled=0` | 关广告 ID |
| `Microsoft\Windows\CurrentVersion\Privacy` | `TailoredExperiencesWithDiagnosticDataEnabled=0` | 关诊断数据个性化 |
| `Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarDa=0` | 隐藏任务栏**小组件按钮**（`WebExperience` 已移除，留着是死按钮） |
| 同上 | `ShowTaskViewButton=0` | 隐藏任务视图（与 HKLM 那条一致） |
| 同上 | `HideFileExt=0` | **显示文件扩展名**（防 `.jpg.exe` 钓鱼） |
| 同上 | `LaunchTo=1` | 资源管理器打开时直接进「此电脑」而不是「快速访问」 |
| `Microsoft\Windows\CurrentVersion\Search` | `SearchboxTaskbarMode=2` | 搜索框只留图标，省一段常驻 UI |
| `Microsoft\Windows\CurrentVersion\Themes\Personalize` | `EnableTransparency=0` | **关透明特效**，少一层合成（性能） |
| `Microsoft\Windows\CurrentVersion\Explorer\Serialize` | `StartupDelayInMSec=0` | 启动项不强制延迟 1 秒，开机后图标更快就位 |
| `Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location` | `Value=Deny` | 关位置服务（设置 → 隐私里可再开） |
| `Microsoft\Windows\CurrentVersion\Run` | **删除** `OneDriveSetup` / `OneDrive` | **拦住 OneDrive 在每个新账户首次登录时自动装回来**。用 `Type='Delete'` 走 `reg delete … /f`：HKLM 的 `Run` 键里压根没有 `OneDriveSetup`（离线日志「已删除注册表值」= 0 条是证据），真正的触发点是**默认用户档案的 HKCU `Run`**，每个新账户都是从 `C:\Users\Default\NTUSER.DAT` 拷出来的 |

#### ⑧b 删掉会自己跑更新/遥测的计划任务

策略只管 Windows Update 主程序，**计划任务是另一条触发路径**。直接删
`Windows\System32\Tasks\Microsoft\Windows\` 下的任务文件即可（离线状态最省事），
只删更新与遥测类，**不碰**磁盘整理、系统诊断、Defender 扫描这些正经任务：

| 任务文件 | 作用 |
|---|---|
| `WindowsUpdate\Scheduled Start` | ⭐ **例行 Windows 更新**，会自动下载安装 |
| `WindowsUpdate\Orchestrator\USO_UxBroker` `WindowsUpdate\Orchestrator\UpdateOrchestrator` | 更新编排器 |
| `Automatic App Update` | 商店应用自动更新 |
| `Maps\MapsToastTask` `Maps\MapsUpdateTask` | 离线地图更新 |
| `Customer Experience Improvement Program\Consolidator` `Customer Experience Improvement Program\UsbCeip` | 客户体验改进（采样） |
| `Application Experience\Microsoft Compatibility Appraiser` `Application Experience\ProgramDataUpdater` | 兼容性评估 |
| `DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector` | 磁盘诊断数据收集 |

文件不存在就跳过；删除失败只 `Write-Warning`。

> **⚠ 这一步在 `updates=false` 时实际是空转的**：离线挂载的镜像里
> `Windows\System32\Tasks` 目录是**空的**（计划任务要等系统首次启动时才生成），
> 所以构建日志里一条「已删除计划任务」都不会出现，属预期。真正生效的是装机后的
> `Cleanup.ps1` —— 它以 SYSTEM 身份用 `schtasks /Delete /TN … /F` 把同一张清单
> **在线**删一遍（见下一节「装机后在线清理」）。

## 装机后在线清理（`C:\FirstBoot\Cleanup.ps1`）

离线挂载镜像时删不掉、或压根枚举不到的东西，全部挪到**装完系统、系统跑起来之后**
以 SYSTEM 身份在线删。脚本镜像内的路径是 `C:\FirstBoot\Cleanup.ps1`。

**唯一属主 = 计划任务 `SYSTEM_Intel_MIC_Cleanup`（`ONLOGON` / SYSTEM / `RL HIGHEST`）：**

| 触发 | 时机 | 做什么 |
|---|---|---|
| `SetupComplete.cmd` 里 `schtasks /Create` + **`schtasks /Run`**（失败才降级 `start /B`） | OOBE 结束、第一次登录**之前** | 先做与登录无关的三件事（关 Defender、卸 OneDrive、删更新/遥测计划任务），然后**原地等待第一次交互式登录**（最多 45 分钟，每 10 秒刷新一次实例锁） |
| `ONLOGON` 触发器（同一任务） | 第一个用户真正登录时 | 上面那个实例还在等 → 拿不到 15 分钟内的实例锁 → 直接让路；如果 `SetupComplete` 那次 `schtasks /Run` 压根没成功，这次就是兜底 |
| 登录被检测到之后 | `explorer` 起来 + 60 秒宽限 | 删点名要删的 Appx，并**最多再补刀 10 分钟**（每 60 秒重查一次，直到目标包全部消失） |
| 结束 | 见下 | 写 `C:\FirstBoot\CLEANUP_DONE` → **`schtasks /Delete` 自我删除任务**；日志 `C:\FirstBoot\cleanup.log` |

> **为什么非要等登录**：`Getstarted` / `WindowsBackup` / `SecHealthUI` 在离线 provisioned
> 列表里**一条都 grep 不到**（构建日志计数 0），它们是**随首登才注册的 staged 包** ——
> 没登录之前系统里根本没有它们。所以 `CLEANUP_DONE` **只有在「确认见过交互式登录」之后
> 才写**，否则就会变成「装机时什么都没看见 → 打个勾 → 之后再也不会重跑」，正是这次实机
> 反馈 ④⑤⑥⑦ 一直删不掉的成因。
> 判据用「真实用户配置文件 + `explorer.exe 已启动」，**不用** Win32_LogonSession ——
> 欢迎界面阶段也会有 `LogonType=2` 会话，会把「还没输密码」误判成「已登录」。

| # | 动作 | 为什么必须在线 |
|---|---|---|
| 1 | `Stop-Service` + `Set-Service -StartupType Disabled`：`SecurityHealthService` `WdNisSvc` `WinDefend` `Sense`；写 `TamperProtection=0`、`DisableAntiSpyware=1`、`DisableAntiVirus=1`、`DisableRealtimeMonitoring=1` | 篡改保护（Tamper Protection）在线会挡住策略写入并把服务拉回来，必须先在运行时关掉。这步**不等登录**，任务一启动就做 |
| 2 | 跑 `OneDriveSetup.exe /uninstall`（System32 + SysWOW64），`Stop-Process` 掉 `OneDrive`/`OneDriveStandaloneUpdater`/`OneDriveSetup`，扫 `HKLM\...\Run` 和 `WOW6432Node\...\Run` 里所有含 `OneDrive` 的值删掉，`takeown` + `icacls` 后 `Remove-Item` 清残留目录（含 `C:\Users\*\AppData\Local\Microsoft OneDrive`） | 离线删 HKLM `Run` 两个键时日志「已删除注册表值」= 0 条（说明**真正的触发点不在 HKLM**），跑起来才能看到并清掉所有残留；OneDrive 是可执行程序（`OneDriveSetup.exe`），不是 Appx，只能跑它的官方卸载器。同样**不等登录** |
| 3 | `schtasks /Delete /F` ⑧b 那张更新/遥测任务清单（12 个） | 同 ⑧b 的说明：离线 `System32\Tasks` 是空的，只能在线删。同样**不等登录** |
| 4 | **等第一次交互式登录**（最多 45 分钟）→ `Get-AppxProvisionedPackage -Online` + `Get-AppxPackage -AllUsers` 里删 **`Getstarted`（入门）/ `WindowsBackup`（Windows 备份）/ `SecHealthUI`（Windows 安全中心）/ `OneDriveSync`**，外加 `GetHelp` `MSTeams` `OutlookForWindows` `BingNews` 兜底 → 最多再补刀 10 分钟 | 这四个在离线的 provisioned 列表里 **grep 计数 = 0**（根本没注册成预置包），离线 `/Remove-ProvisionedAppxPackage` 无从下手；`SecHealthUI` 就算能匹配到，离线删也报 `0x80073CFA`（退出码 15610，日志里唯一的 `[fail]`）——它是系统应用，只能系统跑起来后以 SYSTEM 身份在线删，而且**必须等到首登之后** |

**实例锁 `C:\FirstBoot\cleanup.lock`**：`SetupComplete` 的 `/Run` 与 `ONLOGON` 触发可能撞车。
- 拿不到锁且锁文件时间戳在 15 分钟内 → 直接退出，让正在跑的那个做完；
- 等待登录期间每 10 秒刷新一次锁文件时间戳，**不会**被别人误判成死锁；
- 锁超过 15 分钟（上一个实例崩了）→ 判定失效，接管重跑。

**默认用户 hive 里额外删掉的 OneDrive 触发值**（离线做，见 ⑧a）：
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的 `OneDriveSetup` / `OneDrive`。
每个新账户的 HKCU 都是从 `C:\Users\Default\NTUSER.DAT` 拷出来的，所以删默认账户这一个
就等于拦住了所有新账户首次登录自动装回 OneDrive。

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
- **安装时机**：`C:\FirstBoot\Activate.cmd`（计划任务 `SYSTEM_Intel_MIC_Activate`，SYSTEM 权限，
  首启 + 每次开机）按「先看 `WINWORD.EXE` 装没装 → 没装且 `setup.exe` 空闲就拉起」的节奏启动
  `setup.exe /configure`，上限 90 分钟；**重启后会自动接着装**
- **装完自动清理**：`Activate.cmd` 确认 `C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE`
  存在（`OFFICE=OK`）→ 等 20 秒让 Click-To-Run 放掉文件句柄 → `rmdir /s /q C:\OfficeInstall`
  （释放约 3.6 GB），成败都写进 `activation.log`；
  **装失败就保留**，那是唯一的离线安装源，删了就补不回来
- **任何失败都只 `Write-Warning`，绝不拖垮已经跑了一个多小时的镜像构建**

## MAS 激活（`mas_activate`）

- **下载**：构建时从官方仓库原始文件下载
  `https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/All-In-One-Version-KL/MAS_AIO.cmd`
- **放置**：镜像根的 `\MAS\MAS_AIO.cmd` → 装完就是 `C:\MAS\MAS_AIO.cmd`

**跑在哪：`C:\FirstBoot\Activate.cmd`（由计划任务 `SYSTEM_Intel_MIC_Activate` 以 SYSTEM 身份、
`/SC ONSTART` 拉起，首启 `schtasks /Run` 立刻跑一次），不是 `FirstBoot.ps1`。**

> **为什么改**：上一版是 `FirstBoot.ps1` 里 `cmd /c MAS_AIO.cmd`，三个坑全踩了 ——
> ① 没带参数 → MAS 弹**交互菜单**，没人按键就一直卡住；
> ② 跑在**普通用户会话** → 没权限、可能弹 UAC；
> ③ 没等联网 → 26100+ 的 HWID/TSforge **必须联网**才成功。
> 现在交给 SYSTEM 后台进程，前台 `FirstBoot.ps1` 只负责**显示结果**。

**执行顺序（`Activate.cmd`）：**

> 在线清理**不归它管** —— 那是计划任务 `SYSTEM_Intel_MIC_Cleanup`（ONLOGON）的活，
> 见上一节「装机后在线清理」。激活器只负责 Office + 联网 + MAS，两件事并行不打架。

0. 已有 `C:\FirstBoot\ACTIVATION_RESULT.txt` → 直接 `schtasks /Delete` 自删任务并退出（幂等）
1. **装 Office**：先看 `WINWORD.EXE` 在不在 → 不在且 `setup.exe` 空闲就拉起（最多试 5 次），
   每 15 秒一轮、上限 90 分钟；**不依赖任何别的进程写标记，重启后自动续装**
2. **等联网**（`ping 223.5.5.5` / `114.114.114.114`），上限 30 分钟
3. 分两次调用 MAS（**分开跑，免得只有一个方法被执行**）：
   - 联网时：`call MAS_AIO.cmd /HWID /S` → Windows 数字许可证永久激活
   - 始终执行：`call MAS_AIO.cmd /Ohook /S` → Office 永久激活（离线也能成）
   - **任意 switch 就进 unattended 模式**，不出菜单、不等按键（来源 massgrave.dev 官方开关文档）；
     必须用 `call` 才能跑完返回继续写结果
4. 用 WMI 复核**真实授权状态**：`Get-CimInstance SoftwareLicensingProduct -Filter
   'PartialProductKey IS NOT NULL AND LicenseStatus = 1'`（不出任何弹窗）
5. `OFFICE=OK` 才删 `C:\OfficeInstall`
6. 结果写 `C:\FirstBoot\ACTIVATION_RESULT.txt`（`NETWORK=` `OFFICE=` `HWID_EXIT=` `OHOOK_EXIT=`
   `WIN_LICENSE=` `DONE`）+ `OFFICE_DONE`，完整输出留在 `C:\FirstBoot\activation.log`，
   最后 `schtasks /Delete /TN SYSTEM_Intel_MIC_Activate` **自我删除**

**前台显示**：`FirstBoot.ps1` 轮询结果文件（上限 60 分钟），然后按「真实授权状态优先、
退出码兜底」给出 ✅/⚠，并附日志尾部；失败时提示手动双击 `C:\MAS\MAS_AIO.cmd` 重试。

- **风险提示**：`MAS_AIO.cmd` 是第三方脚本，Defender 可能报「hacktool」，属于误报性质，
  介意就关掉 `mas_activate` 开关（关掉后 `FirstBoot.ps1` 只会显示未等到结果的提示）

## 首登录编排器（`SetupComplete.cmd` + 计划任务 + `FirstBoot.ps1`）

**触发链（单一属主 + 重启可续跑）：**

```
SetupComplete.cmd（SYSTEM，OOBE 结束后）
  ├─ schtasks /Create SYSTEM_Intel_MIC_Cleanup  /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
  │    └─ schtasks /Run  … → 立刻开跑（先做关 Defender / 卸 OneDrive / 删计划任务，
  │                           然后在后台等第一次交互式登录，登录后再删 入门/备份/安全中心）
  │                           /Run 失败才降级成 start /B
  ├─ schtasks /Create SYSTEM_Intel_MIC_Activate /SC ONSTART /RU SYSTEM /RL HIGHEST /F
  │    └─ schtasks /Run  … → 立刻跑一次（创建失败才降级成 start /B）
  └─ reg add HKLM\...\RunOnce\SYSTEM_Intel_MIC_FirstBoot   → 首次登录拉起 FirstBoot.ps1

SYSTEM_Intel_MIC_Cleanup 计划任务（SYSTEM，ONLOGON；写完 CLEANUP_DONE 自我删除）
  └─ C:\FirstBoot\Cleanup.ps1
       ├─ 0) 有 CLEANUP_DONE → 直接退出
       ├─ 1) 抢实例锁（拿不到且锁 <15 分钟 → 让路退出）
       ├─ 2) 关 Defender 四个服务 + 篡改保护/策略键（不等登录）
       ├─ 3) OneDriveSetup /uninstall + 清 HKLM Run + 删残留目录（不等登录）
       ├─ 4) schtasks /Delete 更新·遥测计划任务 12 个（不等登录）
       ├─ 5) 等第一次交互式登录（最多 45 分钟，每 10 秒刷新锁）
       │      判据 = 真实用户配置文件 + explorer.exe 已启动
       ├─ 6) 宽限 60 秒 → 删 Getstarted/WindowsBackup/SecHealthUI/… → 最多补刀 10 分钟
       └─ 7) 确认见过登录才写 CLEANUP_DONE + schtasks /Delete 自删任务
              没见过登录 → 不写标记、任务留着，下次登录的 ONLOGON 触发会再来一遍

SYSTEM_Intel_MIC_Activate 计划任务（SYSTEM，ONSTART；跑完自我删除）
  └─ C:\FirstBoot\Activate.cmd
       ├─ 0) 已有 ACTIVATION_RESULT.txt → 直接 schtasks /Delete 自删，退出
       ├─ 1) Office：先看 WINWORD.EXE 装没装 → 没装且 setup.exe 空闲就拉起
       │      （最多试 5 次 / 等 90 分钟；**重启后会自动接着装**）
       ├─ 2) 等联网（ping 223.5.5.5 / 114.114.114.114，上限 30 分钟）
       ├─ 3) MAS：联网才跑 /HWID（Windows），/Ohook 常跑（Office）
       ├─ 4) 调 SoftwareLicensingProduct 拿真实 WIN_LICENSE（0/1）
       ├─ 5) Office 装成了才 rmdir /s /q C:\OfficeInstall（约 3.6 GB）
       └─ 6) 写 ACTIVATION_RESULT.txt（NETWORK / OFFICE / HWID_EXIT / OHOOK_EXIT / WIN_LICENSE / DONE）
            + OFFICE_DONE → schtasks /Delete 自删任务

FirstBoot.ps1（用户会话，RunOnce 触发）
  ├─ 自删 RunOnce（HKLM + HKCU 兜底，explorer 本来也会删）
  ├─ 后台 runspace 等 OFFICE_DONE（上限 90 分钟）→ 等 ACTIVATION_RESULT.txt（上限 60 分钟）
  ├─ UI 线程 ShowDialog + DispatcherTimer（500 ms 一次）把共享状态刷到窗口
  └─ 显示 ✅/⚠ 激活结果（附 activation.log 尾部）→ 30 秒后自动关窗；用户也可随时点 X 关掉
```

> **为什么改用计划任务（原来是 `start /B`）**：`start /B` 起的 `Activate.cmd` 是
> `SetupComplete.cmd` 的子进程，用户只要在激活完成前**重启一次**，进程就被杀掉，
> 而 `RunOnce` 值也已经消费掉了 —— 结果就是实机反馈的「装完系统 Win 和 Office 都没激活」。
> `schtasks /SC ONSTART /RU SYSTEM` 之后：首启手动 `/Run` 一次、中途重启下次开机自己再跑、
> Office 没装完会重新拉起 `setup.exe` 续装、全部成功后写结果标记并**自我删除**，不留常驻。
>
> **为什么 `FirstBoot.ps1` 要重写（原来是「弹个窗口就死机，只能重启」）**：上一版在
> `$win.Show()` 之后**在同一个 UI 线程上** `while + Start-Sleep` —— WPF 的消息泵根本没转，
> 窗口既画不出来也不响应鼠标。现在所有等待都搬进后台 runspace，UI 线程只跑
> `ShowDialog()`（本身就会持续泵消息）+ `DispatcherTimer` 刷新文本；窗口右上角的 X 也一直可用。
>
> **为什么激活不在 `FirstBoot.ps1` 里跑**：它是普通用户会话，没权限、不保证已联网、
> Office 也未必装完，而且 `C:\FirstBoot` 对普通用户只有读权限（写不了 `OFFICE_DONE`）。
> SYSTEM 后台任务一次解决三个问题，前台只负责「把结果显示给人看」。
> 反过来，弹窗必须放 `FirstBoot.ps1`：`SetupComplete.cmd` 跑在 SYSTEM 会话里，
> **桌面用户看不见它的 GUI**。

## 体积优化（实测数据）

目标：**分卷 ≤ 2 GB、总体积尽量靠近 8 GB，且不砍功能。**

| 手段 | 节省 | 状态 |
|---|---|---|
| ESD 重打包（`wimlib-imagex export` → solid LZMS） | **−1732.5 MB**（10447.3 → 8714.8 MB，耗时 3762 秒） | ✅ 实测 |
| 剔除 arm64 交叉部件（Office 包内） | **−451.4 MB** | ✅ 实测 |
| `ResetBase`（UUP 转换阶段） | 基线的一部分 | ✅ 开着 |
| Appx 白名单瘦身 | −28 MB（28020 上多数目标包本就没 provision；改成强删名单后主要收益是**干净度**而非体积） | ✅ 实测 |
| 离线 `StartComponentCleanup /ResetBase` | WinSxS 12823.1 → 12709.4 MB、servicing −1.5 MB，耗时 26 秒 | ✅ 实测 |
| 14 个可选功能移除 | 0 失败；与上一步合并后**净收益仅 −13.4 MB** → **无损空间已经挖尽** | ✅ 实测 |
| 可选功能移除**扩充**到 ~104 项（`IIS-` `MSMQ-` `WCF-` `Client-` `Sysmon` `Recall` …） | 待实测 | 🔄 本轮 |
| **禁止集成累积更新（`updates=false`）** | **−1~2 GB**（LCU/Enablement/SSU/NetFx/SetupDU/SafeOSDU 全部不进镜像） | 🔄 本轮 |
| **合计（前三项）** | 基线 11895 MB → **9755 MB**，省 **2140 MB（18%）** | ✅ |

> 无损方向（`ResetBase` / 功能移除）上一轮实测**只净省 13.4 MB**，说明已经到顶；
> 真正还能再砍的就是 `updates=false` 和这轮扩大的可选功能清单。

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
- **更新/遥测计划任务已在线删除**：早期文档写过 `FirstBoot.ps1` 会 `Disable-ScheduledTask`，
  **实际从未实现**。现在这张清单由 `C:\FirstBoot\Cleanup.ps1`（SYSTEM 身份）用
  `schtasks /Delete /TN … /F` 在线执行，见「装机后在线清理」一节。
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
| 官方安装程序报「Windows 安装遇到错误。错误代码: `0x80070002 - 0x40030`」 | `windowsPE` 阶段某条 `RunSynchronous` 失败（`0x80070002` = 找不到文件，`0x40030` = 应答文件 `RunSynchronous` 应用失败）。历史根因是 `sc config wuauserv`（WinPE 里没有 `sc.exe`），已修：删掉该命令 + 每条命令都套 `cmd /c "… & exit 0"`。若仍复现，关掉 `hw_bypass` 只留基础应答文件重跑 |
| 开机进桌面弹出进度窗口后**卡死**，只能重启 | 上一版 `FirstBoot.ps1` 在 UI 线程上 `Start-Sleep` 阻塞了 WPF 消息泵，已改成「后台 runspace + `ShowDialog` + `DispatcherTimer`」。装新 ISO 即可；旧镜像上可以任务管理器结束 `powershell` 进程，不影响激活 |
| 装完系统 **Win 和 Office 都没激活** | 激活器原来是 `SetupComplete` 的子进程，重启一次就被杀。现在改用计划任务 `SYSTEM_Intel_MIC_Activate`（`ONSTART` / SYSTEM，跑完自删）。装新 ISO；旧镜像可手动以管理员运行 `C:\FirstBoot\Activate.cmd`，或双击 `C:\MAS\MAS_AIO.cmd` |
| 「入门」「Windows 备份」「OneDrive」「Windows 安全中心」还在 | 离线镜像里这几个根本没注册成预置包（是**随首登才注册的 staged 包**），必须登录之后才删得掉。先看 `C:\FirstBoot\cleanup.log`：带 `no logon seen` 就说明它还没等到登录 → 注销再登录一次会由 `ONLOGON` 触发器重跑。若任务已自删但没删干净，先删 `C:\FirstBoot\CLEANUP_DONE`，再用管理员 PowerShell 跑 `powershell -NoProfile -ExecutionPolicy Bypass -File C:\FirstBoot\Cleanup.ps1` |
| 进度窗口显示 ⚠ 激活未完成 | 看 `C:\FirstBoot\activation.log`（`HWID_EXIT` / `OHOOK_EXIT` / `WIN_LICENSE`）。联网后重跑 `C:\FirstBoot\Activate.cmd`，或双击 `C:\MAS\MAS_AIO.cmd` 手动选方法 |
| 首次开机后 Office 没装上 | Office 是**静默安装**（`Display Level="None"`，SYSTEM 后台跑，不会弹窗）。看 `C:\FirstBoot\activation.log` 里的 `starting Office setup` / `Office installed`，以及 `C:\FirstBoot\OFFICE_DONE`；装失败会保留 `C:\OfficeInstall`（唯一离线安装源），可手动 `setup.exe /configure configuration.xml` |
| 想知道某个包/服务/功能为什么还在 | 日志里搜 `[keep]`（Appx 保留判定）、`[feature]`（可选功能全表）、`[size:清理前]`（体积分布） |
| `找不到 PROFESSIONAL` / 语言包 | 该构建暂未提供 zh-cn 或对应版本，换个构建号 |
| 分卷上传失败 | 确认 workflow 有 `permissions: contents: write`（已内置），token 未过期 |
