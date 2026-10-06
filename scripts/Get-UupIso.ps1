#!/usr/bin/env pwsh
<#
.SYNOPSIS
    从 UUP dump 构建 Windows ISO（全流程在 GitHub Actions 里跑，本地不下载任何 UUP 文件）。

.DESCRIPTION
    1. 调 UUP dump API 按「构建号 + 通道 + 架构」找到目标构建（默认 28020 / insider / amd64）
    2. 从 UUP dump 下载“下载包”（ConvertConfig.ini + uup_download_windows.cmd）
    3. 按参数改写 ConvertConfig.ini（累积更新 / ESD / 预装 .NET3.5 / 跳过应用 / 跳过 Edge /
       WIM 分卷 / 注入驱动 / 虚拟版本=企业版）
    4. 运行 uup_download_windows.cmd：aria2 从 Windows Update 服务器拉 UUP 文件，
       再用 uup-converter-wimlib 挂载、打补丁、导出并生成 ISO
    5. （可选）把 autounattend.xml 注入 ISO 根目录并用转换器自带的 cdimage.exe 重新封盘：
       windowsPE 阶段免 TPM/安全启动/内存检测、oobeSystem 阶段跳过 OOBE、写入 OEM 信息，
       必要时用 wimlib-imagex 往 install.wim 里塞 OEM logo

    参考实现：ylx2016/uup-dump-build-and-get-windows-iso
#>

[CmdletBinding()]
param(
    # 目标版本：pro=专业版（首跑默认）/ enterprise=仅企业版 / enterprise_pro=专业版+企业版 / multi=家庭版+专业版
    [ValidateSet('enterprise', 'enterprise_pro', 'pro', 'multi')]
    [string] $Edition = 'pro',

    # 输出目录（Windows runner 的 D: 盘空间最大）
    [string] $Destination = 'd:/output',

    # 构建号：28020 = Beta (26H1) 预览版；也可填精确版本 28020.3142
    [string] $Build = '28020',

    # 通道：insider=Dev/Beta/Canary 预览版；stable=正式版（title 含 version 26H2 之类）
    [ValidateSet('insider', 'stable')]
    [string] $Channel = 'insider',

    # 架构：目前只用 amd64 (x64)
    [ValidateSet('amd64')]
    [string] $Arch = 'amd64',

    # 语言
    [string] $Lang = 'zh-cn',

    # 不集成最新累积更新（默认集成）
    [switch] $NoUpdates,

    # 重新封盘前把 install.wim 重打包成 install.esd（LZMS solid，约省 1.3~1.8 GB；
    # 精简/Office/MAS/OEM logo 仍在 wim 上做完才转，所以这些功能一个都不会失效）
    [switch] $Esd,

    # 预装 .NET Framework 3.5
    [switch] $NetFx3,

    # 不做组件基线重置（ResetBase=1 更小但更慢）
    [switch] $NoResetBase,

    # 跳过预装 Store 应用（SkipApps，镜像更小但没有商店/内置 Appx）
    [switch] $SkipApps,

    # 跳过 Edge 集成（SkipEdge）
    [switch] $SkipEdge,

    # 注入仓库 Drivers/ 目录下的驱动（AddDrivers）
    [switch] $Drivers,

    # install.wim 拆分成 install.swm（wim2swm；开了它就找不到 install.wim，深度精简/Office/MAS/logo 都会跳过）
    [switch] $Wim2Swm,

    # ---- 无人值守：往 ISO 根目录注入 autounattend.xml 并重新封盘 ----
    [switch] $Unattend,

    # 免硬件检测：windowsPE 阶段写 LabConfig，绕过 TPM/安全启动/内存检查
    [switch] $HwBypass,

    # 跳过 OOBE 的 EULA / 微软账户 / 无线设置 / 隐私设置页
    [switch] $SkipOobe,

    # 预建本地管理员账户；用户名留空 = 不预建（OOBE 里手动创建）
    [string] $LocalUser = '',
    [string] $LocalPassword = '',

    # ---- OEM 信息（写入注册表 OEMInformation 与 winver 的 RegisteredOwner/Organization）----
    [string] $OemOwner = '',
    [string] $OemOrg = '',
    [string] $OemProvider = '',
    [string] $OemUrl = '',
    [string] $OemManufacturer = '',
    [string] $OemModel = '',
    [string] $OemLogo = '',
    [string] $OemPhone = '',

    # ---- 深度精简 / Office / MAS ----
    # 离线定制 install.wim：精简预装应用 + 移除 AI/Copilot/Recall + 优化注册表 + 禁用服务
    [switch] $DeepDebloat,

    # 离线集成 Office 365（Word/Excel/PowerPoint，ODT + 离线包直接在 Action 里下载）
    [switch] $OfficeOffline,

    # 首登录运行 MAS 永久激活 Windows + Office
    [switch] $MasActivate,

    # 额外禁用更多服务/诊断/遥测（与 DeepDebloat 独立）
    [switch] $PerfTweaks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ApiBase = 'https://api.uupdump.net'
$WebBase = 'https://uupdump.net'

# 支持三种写法：28020（取该构建最新修订）/ 28020.3142（精确版本）/ 自由搜索词
$major = $null
if ($Build -match '^(\d+)(\.\d+)?$') { $major = ($Build -split '\.')[0] }
$Search = if ($major) { "windows 11 $major $Arch" } else { $Build }

$repoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }

# ---------------------------------------------------------------------------
# OEM logo：仓库里放 OEM/logo.bmp（或 .png/.jpg）就会被塞进 install.wim 的 System32
# ---------------------------------------------------------------------------
$logoSource = $null
$oemLogoPath = ''
foreach ($n in @('logo.bmp', 'logo.png', 'logo.jpg', 'logo.jpeg')) {
    $cand = Join-Path (Join-Path $repoRoot 'OEM') $n
    if (Test-Path -LiteralPath $cand) { $logoSource = $cand; break }
}
if ($OemLogo) {
    $oemLogoPath = $OemLogo
} elseif ($logoSource) {
    $oemLogoPath = 'C:\Windows\System32\oemlogo' + [System.IO.Path]::GetExtension($logoSource)
}

# SupportURL 需要完整 URL，缺协议头就补一个 https
$oemUrlValue = $OemUrl.Trim()
if ($oemUrlValue -and $oemUrlValue -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://') { $oemUrlValue = "https://$oemUrlValue" }

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
function Write-Info([string] $Message) { Write-Host "==> $Message" }

function Test-IniKey([string] $Text, [string] $Key) {
    return $Text -match "(?m)^[ \t]*$([regex]::Escape($Key))[ \t]*="
}

function Set-IniValue([string] $Text, [string] $Key, [string] $Value) {
    if (-not (Test-IniKey $Text $Key)) {
        Write-Warning "ConvertConfig.ini 中找不到 $Key，跳过。"
        return $Text
    }
    $pattern = "(?m)^([ \t]*)$([regex]::Escape($Key))[ \t]*=[^\r\n]*(\r?)$"
    return [regex]::Replace($Text, $pattern, {
        param($m)
        $m.Groups[1].Value + $Key + '    =' + $Value + $m.Groups[2].Value
    })
}

function Invoke-UupApi([string] $Endpoint, [hashtable] $Query) {
    $qs = ''
    if ($Query) {
        $qs = '?' + (($Query.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))"
        }) -join '&')
    }
    $uri = "$ApiBase/$Endpoint$qs"
    for ($i = 1; $i -le 8; $i++) {
        try {
            return Invoke-RestMethod -Uri $uri -TimeoutSec 60 -Headers @{ 'User-Agent' = 'winbuild-uup/1.0' }
        } catch {
            Write-Warning "UUP dump API $Endpoint 第 $i/8 次请求失败: $_"
            if ($i -lt 8) { Start-Sleep -Seconds ([Math]::Min(60, 5 * $i)) }
        }
    }
    throw "UUP dump API $Endpoint 连续 8 次请求失败"
}

# UUP dump 的 builds 字段可能是数组、单对象、或按索引展开的对象
function Resolve-Builds($Builds) {
    if ($null -eq $Builds) { return @() }
    if ($Builds -isnot [System.Management.Automation.PSCustomObject]) { return @($Builds) }
    if ($Builds.PSObject.Properties.Name -contains 'uuid') { return @($Builds) }
    return @($Builds.PSObject.Properties | ForEach-Object { $_.Value })
}

function Get-ObjectKeys($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        return @($Value.PSObject.Properties.Name)
    }
    return @($Value | ForEach-Object { "$_" })
}

# 按通道筛选 UUP dump 的构建标题：
#   stable  -> "Windows 11, version 26H2 (26300.9550)" 这类正式版
#   insider -> "Windows 11 Insider Preview Feature Update (28020.3142)" 这类预览版
# 两种通道都要排除累积更新本身（"Preview Update for ..."）和 .NET Framework 更新
function Test-TrackTitle([string] $Title) {
    if ($Title -match '(?i)\.net framework|Preview Update for') { return $false }
    if ($Channel -eq 'stable') {
        return (($Title -match '(?i)\bversion\b') -and ($Title -notmatch '(?i)preview|prerelease'))
    }
    return ($Title -match '(?i)Insider Preview')
}

function Hide-Aria2Noise([string] $Path) {
    # aria2 的进度条会产生巨量日志，这里按需降噪；只在能安全还原编码时才改写文件
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $enc = $null
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = [System.Text.Encoding]::UTF8
    } elseif (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)) {
        $enc = [System.Text.Encoding]::ASCII
    }
    if ($null -eq $enc) {
        Write-Warning "无法确定 $Path 的编码，跳过 aria2 日志降噪。"
        return
    }

    $text = $enc.GetString($bytes)
    foreach ($re in @(
        '\s--console-log-level=\w+\b',
        '\s--summary-interval=\d+\b',
        '\s--download-result=\w+\b',
        '\s--enable-color=\w+\b',
        '\s--(quiet|q)(=\w+)?\b'
    )) {
        $text = [regex]::Replace($text, $re, '', 'IgnoreCase, CultureInvariant')
    }
    $inject = '--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false '
    $text = [regex]::Replace($text, '("%aria2%"\s+)', ('${1}' + $inject), 'IgnoreCase, CultureInvariant')
    [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($text))
}

function Escape-Xml([string] $Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function Test-XmlWellFormed([string] $Text) {
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($Text)
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# 5.1 读 ISO 卷标：cdimage -l 的值原样写在 ISO9660 主卷描述符（扇区 16）偏移 40 处
# ---------------------------------------------------------------------------
function Read-IsoPvdLabel([string] $Path) {
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        if ($fs.Length -lt 34816) { return $null }
        [void]$fs.Seek(32768, 'Begin')
        $buf = New-Object byte[] 2048
        $read = 0
        while ($read -lt 2048) {
            $n = $fs.Read($buf, $read, 2048 - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt 72) { return $null }
        if ($buf[0] -ne 1) { return $null }
        if ([System.Text.Encoding]::ASCII.GetString($buf, 1, 5) -ne 'CD001') { return $null }
        $label = [System.Text.Encoding]::ASCII.GetString($buf, 40, 32).Trim([char[]]@(' ', [char]0))
        if ($label -match '^[A-Za-z0-9][A-Za-z0-9 _\-]{0,31}$') { return $label }
        return $null
    } catch {
        return $null
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-IsoLabel([string] $Path, [string] $Fallback) {
    $label = Read-IsoPvdLabel $Path
    if ($label) { return $label }
    Write-Warning '从 ISO 主卷描述符读取卷标失败，改用挂载读取'
    try {
        $v = Mount-DiskImage -ImagePath $Path -PassThru | Get-Volume
        if ($v.FileSystemLabel) { return [string]$v.FileSystemLabel }
    } catch {
        Write-Warning "挂载读取卷标失败: $_"
    } finally {
        Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Warning "卷标读取全部失败，退回到推算值 $Fallback"
    return $Fallback
}

# ---------------------------------------------------------------------------
# 5.2 生成 autounattend.xml（没有要写的内容时返回 $null）
# ---------------------------------------------------------------------------
function New-UnattendXml {
    $loc = $null
    switch ($Lang.ToLowerInvariant()) {
        'zh-cn' { $loc = @{ input = '0804:00000804'; sys = 'zh-CN'; ui = 'zh-CN'; user = 'zh-CN'; tz = 'China Standard Time' } }
        'en-us' { $loc = @{ input = '0409:00000409'; sys = 'en-US'; ui = 'en-US'; user = 'en-US'; tz = 'UTC' } }
    }

    $hasHw   = [bool]$HwBypass
    # 无论其它开关怎么配，都必须拦住自动更新（安装期 + OOBE + 系统运行期都要），
    # 所以应答文件永远要生成，下面 return $null 的判断里也把它算进去。
    $blockUpdates = $true
    $hasOobe = [bool]$SkipOobe
    $hasAcct = -not [string]::IsNullOrWhiteSpace($LocalUser)
    $hasOem  = -not [string]::IsNullOrWhiteSpace($oemLogoPath) -or
               -not [string]::IsNullOrWhiteSpace($OemOwner) -or
               -not [string]::IsNullOrWhiteSpace($OemOrg) -or
               -not [string]::IsNullOrWhiteSpace($OemProvider) -or
               -not [string]::IsNullOrWhiteSpace($oemUrlValue) -or
               -not [string]::IsNullOrWhiteSpace($OemManufacturer) -or
               -not [string]::IsNullOrWhiteSpace($OemModel) -or
               -not [string]::IsNullOrWhiteSpace($OemPhone)

    if (-not ($hasHw -or $hasOobe -or $hasAcct -or $hasOem -or $blockUpdates)) { return $null }

    $cp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $x = @()
    $x += '<?xml version="1.0" encoding="utf-8"?>'
    $x += '<unattend xmlns="urn:schemas-microsoft-com:unattend"'
    $x += '          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $x += '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    $x += '  <!-- 自动生成的无人值守应答文件：免硬件检测 / 跳过 OOBE / OEM 信息 -->'

    # ---- windowsPE：先于硬件兼容性检查写 LabConfig；同时拦住安装期的自动更新 ----
    if ($hasHw -or $loc -or $blockUpdates) {
        $x += '  <settings pass="windowsPE">'
        if ($loc) {
            $x += '    <component name="Microsoft-Windows-International-Core-WinPE" ' + $cp + '>'
            $x += '      <SetupUILanguage>'
            $x += '        <UILanguage>' + $loc.ui + '</UILanguage>'
            $x += '      </SetupUILanguage>'
            $x += '      <InputLocale>' + $loc.input + '</InputLocale>'
            $x += '      <SystemLocale>' + $loc.sys + '</SystemLocale>'
            $x += '      <UILanguage>' + $loc.ui + '</UILanguage>'
            $x += '      <UserLocale>' + $loc.user + '</UserLocale>'
            $x += '    </component>'
        }
        if ($hasHw -or $blockUpdates) {
            $syncCmds = @()
            if ($hasHw) {
                foreach ($v in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck')) {
                    $syncCmds += @{ d = $v; p = "reg add HKLM\SYSTEM\Setup\LabConfig /v $v /t REG_DWORD /d 1 /f" }
                }
            }
            if ($blockUpdates) {
                # 装机期同样不许更新：
                # 1) WinPE 自己的 wuauserv 关掉 → 安装程序不会去 WU 拉"安装动态更新"(Setup DU)，
                #    既省时间又不会把更新塞回镜像（PE 注册表不进成品，只作用于安装过程）；
                # 2) 把 AU 策略写进 PE 注册表，拦住 OOBE 阶段的检查更新。
                $syncCmds += @{ d = 'DisableWUinPE'; p = 'sc config wuauserv start= disabled' }
                $syncCmds += @{ d = 'NoAutoUpdate'; p = 'reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v NoAutoUpdate /t REG_DWORD /d 1 /f' }
                $syncCmds += @{ d = 'AUOptions'; p = 'reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v AUOptions /t REG_DWORD /d 2 /f' }
                $syncCmds += @{ d = 'AutoInstallMinorUpdates'; p = 'reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v AutoInstallMinorUpdates /t REG_DWORD /d 0 /f' }
            }
            $x += '    <component name="Microsoft-Windows-Setup" ' + $cp + '>'
            $x += '      <RunSynchronous>'
            $n = 0
            foreach ($c in $syncCmds) {
                $n++
                $x += '        <RunSynchronousCommand wcm:action="add">'
                $x += '          <Order>' + $n + '</Order>'
                $x += '          <Path>' + (Escape-Xml $c.p) + '</Path>'
                $x += '          <Description>' + (Escape-Xml $c.d) + '</Description>'
                $x += '        </RunSynchronousCommand>'
            }
            $x += '      </RunSynchronous>'
            $x += '    </component>'
        }
        $x += '  </settings>'
    }

    # ---- oobeSystem：OOBE / 账户 / OEM 信息 / 时区 ----
    if ($hasOobe -or $hasAcct -or $hasOem -or $loc) {
        $x += '  <settings pass="oobeSystem">'
        $x += '    <component name="Microsoft-Windows-Shell-Setup" ' + $cp + '>'
        if ($OemOwner.Trim())  { $x += '      <RegisteredOwner>' + (Escape-Xml $OemOwner) + '</RegisteredOwner>' }
        if ($OemOrg.Trim())    { $x += '      <RegisteredOrganization>' + (Escape-Xml $OemOrg) + '</RegisteredOrganization>' }
        if ($loc)              { $x += '      <TimeZone>' + $loc.tz + '</TimeZone>' }
        if ($hasOem) {
            $x += '      <OEMInformation>'
            if ($oemLogoPath.Trim())       { $x += '        <Logo>' + (Escape-Xml $oemLogoPath) + '</Logo>' }
            if ($OemManufacturer.Trim())   { $x += '        <Manufacturer>' + (Escape-Xml $OemManufacturer) + '</Manufacturer>' }
            if ($OemModel.Trim())          { $x += '        <Model>' + (Escape-Xml $OemModel) + '</Model>' }
            if ($OemPhone.Trim())          { $x += '        <SupportPhone>' + (Escape-Xml $OemPhone) + '</SupportPhone>' }
            if ($OemProvider.Trim())       { $x += '        <SupportProvider>' + (Escape-Xml $OemProvider) + '</SupportProvider>' }
            if ($oemUrlValue.Trim())       { $x += '        <SupportURL>' + (Escape-Xml $oemUrlValue) + '</SupportURL>' }
            $x += '      </OEMInformation>'
        }
        if ($hasOobe) {
            $x += '      <OOBE>'
            $x += '        <HideEULAPage>true</HideEULAPage>'
            $x += '        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>'
            $x += '        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>'
            $x += '        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>'
            $x += '        <ProtectYourPC>3</ProtectYourPC>'
            $x += '      </OOBE>'
        }
        if ($hasAcct) {
            $x += '      <UserAccounts>'
            $x += '        <LocalAccounts>'
            $x += '          <LocalAccount wcm:action="add">'
            $x += '            <Name>' + (Escape-Xml $LocalUser) + '</Name>'
            $x += '            <DisplayName>' + (Escape-Xml $LocalUser) + '</DisplayName>'
            $x += '            <Group>Administrators</Group>'
            $x += '            <Password>'
            $x += '              <Value>' + (Escape-Xml $LocalPassword) + '</Value>'
            $x += '              <PlainText>true</PlainText>'
            $x += '            </Password>'
            $x += '          </LocalAccount>'
            $x += '        </LocalAccounts>'
            $x += '      </UserAccounts>'
        }
        $x += '    </component>'
        if ($loc) {
            $x += '    <component name="Microsoft-Windows-International-Core" ' + $cp + '>'
            $x += '      <InputLocale>' + $loc.input + '</InputLocale>'
            $x += '      <SystemLocale>' + $loc.sys + '</SystemLocale>'
            $x += '      <UILanguage>' + $loc.ui + '</UILanguage>'
            $x += '      <UserLocale>' + $loc.user + '</UserLocale>'
            $x += '    </component>'
        }
        $x += '  </settings>'
    }

    $x += '</unattend>'
    return ($x -join "`r`n")
}

# ---------------------------------------------------------------------------
# 5.2b 深度精简：离线挂载 install.wim，移除 Appx/Capability/注册表优化/禁用服务
# ---------------------------------------------------------------------------
function Invoke-OfflineCustomization([string] $Tree, [string] $BuildDir) {
    $wim = Get-ChildItem -LiteralPath (Join-Path $Tree 'sources') -File |
        Where-Object { $_.Name -ieq 'install.wim' } | Select-Object -First 1
    if (-not $wim) {
        Write-Warning "未找到 install.wim，跳过离线深度精简"
        return
    }

    $mnt = Join-Path $BuildDir '_offline_mount'
    if (Test-Path -LiteralPath $mnt) { Remove-Item -LiteralPath $mnt -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mnt | Out-Null
    Write-Info "离线挂载 install.wim 到 $mnt"

    $mounted = $true   # 提交/卸载成功后置为 $false，finally 里据此决定是否兜底 Discard
    try {
        # 挂载
        $null = dism.exe /Mount-Wim /WimFile:$($wim.FullName) /Index:1 /MountDir:$mnt
        if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Wim 失败，退出码 $LASTEXITCODE" }

        # ---- 1. 移除 Provisioned Appx 包（保留核心媒体/商店/照片/相机）----
        # ---- 1. 移除 Provisioned Appx 包 ----
        # $keep 是**保留白名单**，匹配方式是包含匹配（*关键词*）：命中就留，
        # 没命中的全部 /Remove-ProvisionedAppxPackage 删掉，日志逐包打印 [keep]/[fail]。
        #
        # 上一版把 Xbox / 纸牌 / 微软资讯 / 手机连接 / 获取帮助等垃圾也写进了白名单，
        # 于是全被保住（装机实测发现）。现在只留「用户点名要的 + 运行库/编解码器依赖」：
        #   记事本 / PowerShell终端 / 画图 / 计算器 / 截图 / 闹钟 / Edge / 商店 /
        #   照片 / 相机 / 媒体播放器，以及全部编解码器和运行库。
        # 被移除的都是 Store 里随时能装回来的，不涉及系统功能。
        $keep = @(
            # ---- 用户点名保留的日常应用 ----
            'Notepad', 'WindowsNotepad',                  # 记事本
            'WindowsTerminal',                            # Windows Terminal / PowerShell
            'MSPaint', 'Paint',                            # 画图
            'WindowsCalculator',                           # 计算器
            'ScreenSketch', 'SnippingTool',                # 截图
            'WindowsAlarms', 'Alarms',                     # 闹钟
            'MicrosoftEdge',                               # Edge
            'WindowsStore', 'StorePurchaseApp', 'MicrosoftStore',
            'Services.Store.Engagement',                   # 应用商店 + 购买/更新依赖
            'Windows.Photos', 'Photos',                    # 照片
            'WindowsCamera', 'Camera',                     # 相机
            'ZuneVideo', 'ZuneMusic', 'MediaPlayer',       # 媒体播放器 / 影视 / 音乐
            'DesktopAppInstaller',                         # winget

            # ---- 编解码器（缺了 WebP/HEIF/AV1/HEVC 的视频和图片就打不开）----
            'WebMediaExtensions', 'VP9VideoExtensions', 'HEIFImageExtension',
            'AV1VideoExtension', 'MPEG2VideoExtension', 'HEVCVideoExtension',
            'AVCEncoderVideoExtension', 'RawImageExtension', 'WebpImageExtension',
            'Codec',

            # ---- 运行库 / 依赖（删了会连带废掉一批应用，绝不能动）----
            'WindowsAppRuntime', 'WindowsAppSDK', 'VCLibs',
            'NET.Native', 'UI.Xaml', 'WebView',
            'WidgetsPlatformRuntime', 'PowerAutomateDesktop',
            'StartExperiencesApp', 'ApplicationCompatibilityEnhancements'
        )

        # 下面这些**故意不在白名单里**，会被移除（用户点名 + 预装垃圾）：
        #   Xbox 全家（Xbox.TCUI / GamingOverlay / IdentityProvider / SpeechToText / GamingApp）
        #   纸牌 MicrosoftSolitaireCollection、微软资讯 BingNews、天气 BingWeather
        #   手机连接 YourPhone、跨设备 CrossDevice、获取帮助 GetHelp、入门 Getstarted
        #   反馈中心 WindowsFeedbackHub、Office 推广 MicrosoftOfficeHub
        #   便笺 StickyNotes、待办 Todos、Clipchamp、录音机 SoundRecorder
        #   家庭 MicrosoftFamily、快速助手 QuickAssist、小组件前端 WebExperience
        #   Teams（MSTeams）、新版 Outlook（OutlookForWindows）、OneDrive
        # 需要哪个就把对应关键词加回上面的 $keep。
        #
        # $forceRemove 是**强删名单**，优先级高于 $keep：
        # 哪怕包名里恰好带上了保留关键词（比如 "...Teams..." 撞上别的词），
        # 只要命中下面任意一条就一律移除，杜绝"该删没删"。
        $forceRemove = @(
            'MSTeams', 'Teams',                 # Teams（聊天/会议，用不到就删）
            'OutlookForWindows', 'Outlook',     # 新版 Outlook（PWA）
            'OneDrive',                         # OneDrive 网盘
            'Xbox', 'GamingApp',                # Xbox 全家
            'MicrosoftSolitaireCollection',     # 纸牌
            'BingNews', 'BingWeather',          # 微软资讯 / 天气
            'YourPhone', 'CrossDevice',         # 手机连接 / 跨设备
            'GetHelp', 'Getstarted',            # 获取帮助 / 入门
            'WindowsFeedbackHub',               # 反馈中心
            'MicrosoftOfficeHub',               # Office 推广
            'StickyNotes', 'Todos',             # 便笺 / 待办
            'Clipchamp', 'SoundRecorder',       # AI 剪辑 / 录音机
            'MicrosoftFamily', 'QuickAssist',   # 家庭 / 快速助手
            'WebExperience',                    # 小组件前端（含资讯流）
            'WindowsCommunicationsApps',        # 邮件/日历（旧版）
            'People', 'Print3D', '3DViewer',    # 人脉 / 3D 打印 / 3D 查看器
            'MixedReality', 'Cortana',           # 混合现实 / 小娜
            'WindowsMaps', 'Maps',              # 地图
            'WindowsWallet', 'Wallet'           # 钱包
        )

        $allAppx = (dism.exe /Image:$mnt /Get-ProvisionedAppxPackages 2>&1) |
            Select-String 'PackageName : (.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($app in $allAppx) {
            $name = $app -replace '_.*$', ''  # 取包族名前缀，去版本号
            $shouldKeep = $false
            foreach ($k in $keep) {
                if ($app -like "*$k*") { $shouldKeep = $true; break }
            }
            # 强删名单优先级更高：命中就直接删，不再看 $keep
            foreach ($f in $forceRemove) {
                if ($app -like "*$f*") { $shouldKeep = $false; break }
            }
            # 全量打印判定结果：日志里能看到镜像到底 provision 了哪些包，
            # 下次判断"这个包该不该留、占多大"时不用再靠猜。
            if ($shouldKeep) { Write-Host "    [keep]    $app"; continue }
            dism.exe /Image:$mnt /Remove-ProvisionedAppxPackage /PackageName:$app 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Info "已移除 Appx: $name" }
            else { Write-Host "    [fail]    $app (退出码 $LASTEXITCODE)" }
        }

        # ---- 1b. 系统级移除 OneDrive ----
        # OneDrive 在 Win11 里不是 provisioned 包，而是 System32/SysWOW64 下的
        # OneDriveSetup.exe + 注册表 Run 键，首次登录会自动把它装回来。
        # 文件删除常因 ACL 被拒，**改为只删注册表 Run 值**（已在 SOFTWARE hive 段配合 Type='Delete' 处理），
        # 再尽力删 Program Files 下的已解包目录（通常不存在）。
        foreach ($odDir in @('Program Files\Microsoft OneDrive',
                             'Program Files (x86)\Microsoft OneDrive')) {
            $odFull = Join-Path $mnt $odDir
            if (Test-Path -LiteralPath $odFull) {
                try { Remove-Item -LiteralPath $odFull -Recurse -Force -ErrorAction Stop
                      Write-Info "已删除 $odDir" }
                catch { Write-Warning "删除 $odDir 失败: $_" }
            }
        }

        # ---- 2. 移除 Capability（AI/Copilot/Recall 等）----
        # 先 /Get-Capabilities 打出镜像里全部 capability，再按关键词**模糊匹配**移除。
        # 精确写死名字会随 build 变化漏项（28020 实测就漏了 Recall 和 AI 平台的其它子项），
        # 模糊匹配 + 打印全表，日志里能逐条核对删了什么、还剩什么。
        $capPatterns = @(
            'Recall',                      # 录屏 + AI 回溯（Windows 聚焦记忆）
            'Copilot',                     # Copilot 全部能力（含 AI.Copilot.Provider）
            'Clipchamp',                   # Clipchamp AI 视频剪辑
            'Photos.AI',                   # 照片 AI（老照片修复/背景消除）
            'AppRuntime.AI',               # Windows App Runtime 的 AI 分发
            'Microsoft.Windows.AI',        # Windows AI 平台全家（Ai.Clients / Ai.Foundation…）
            'Microsoft.Windows.Ai',
            'SemanticIndex',               # 语义索引（Recall / AI 搜索的索引后端）
            'MathRecognizer',              # 手写公式 AI 识别
            'AIFoundry', 'AiFoundry', 'WindowsAI',
            'DevHome'                      # 开发者主页（预装无效应用）
        )
        $capIds = @(dism.exe /Image:$mnt /Get-Capabilities /English 2>&1 |
            Select-String 'Identity : (.+)' |   # 宽松匹配，防 DISM 字段名变动导致一条都匹配不上
            ForEach-Object { $_.Matches[0].Groups[1].Value })
        if ($capIds.Count -eq 0) { Write-Warning "没能解析出 Capability 列表，AI 组件可能没删干净，请核对日志里 dism 的原始输出" }
        Write-Info "镜像内 Capability $($capIds.Count) 个，全部列出供核对："
        foreach ($c in $capIds) { Write-Host "    [cap] $c" }
        foreach ($cap in $capIds) {
            $hit = $false
            foreach ($pat in $capPatterns) { if ($cap -like "*$pat*") { $hit = $true; break } }
            if (-not $hit) { continue }
            dism.exe /Image:$mnt /Remove-Capability /CapabilityName:$cap 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Info "已移除 Capability: $cap" }
            else { Write-Host "    [cap-fail] $cap (退出码 $LASTEXITCODE)" }
        }

        # ---- 2b. 体积诊断（清理前）：看清空间都在哪，清理前后各测一次算净收益 ----
        function Get-DirSizeMb([string] $Root) {
            if (-not (Test-Path -LiteralPath $Root)) { return $null }
            $s = (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
            if ($null -eq $s) { return $null }
            return [math]::Round($s / 1MB, 1)
        }
        $sizeTargets = @('Windows\WinSxS', 'Windows\System32\DriverStore\FileRepository',
                         'Program Files', 'Program Files (x86)', 'Windows\servicing\Packages')
        $sizeBefore = @{}
        foreach ($t in $sizeTargets) {
            $v = Get-DirSizeMb (Join-Path $mnt $t)
            $sizeBefore[$t] = $v
            if ($null -ne $v) { Write-Host ("    [size:清理前] {0,-44} {1,9} MB" -f $t, $v) }
        }

        # ---- 2c. 移除可选功能（只删安全清单内匹配到的，匹配不到直接跳过，零风险）----
        # 铁律：不碰用户点名要的东西 —— 媒体播放器/MediaFoundation、编解码器、.NET 3.5、
        # IE 模式(Edge 依赖)、搜索、远程桌面、OpenSSH、打印/PDF 全部不在下面的清单里。
        $featuresToRemove = @(
            'XPS',                     # XPS 查看器 + XPS 打印（PDF 打印是独立服务，不受影响）
            'WorkFolders',             # 工作文件夹同步（企业场景，家用用不到）
            'Fax',                     # 传真
            'SMB1Protocol',            # 废弃且不安全的 SMB1
            'TelnetClient', 'SimpleTCP', 'ClientForNFS',   # 明文/老式协议
            'ServicesForNFS', 'NFS-Administration',        # NFS 客户端/管理（家用基本不用）
            'RasCMAK', 'LPD', 'LPRPortMonitor', 'TFTP',    # 老网络服务
            'SNMP',                    # 网络管理协议
            'PowerShellV2',            # PowerShell v2 旧引擎（5.1 和 7 完全不受影响）
            'Rsat', 'DirectoryServices', 'IPAM', 'DataCenterBridging',  # 服务器类工具
            # ---- 28020 全表比对后新增：客户端用不到的服务端/嵌入式组件 ----
            'IIS-',                    # IIS Web 服务器全套（28020 里有 51 个 IIS-*）
            'WAS-',                    # IIS 进程激活服务（WAS-* 3 个）
            'MSMQ-',                   # 消息队列（MSMQ-* 7 个）
            'WCF-',                    # WCF 服务/激活（WCF-* 6 个）
            'Client-',                 # 嵌入式锁定设备（Kiosk/键盘过滤/UWF 等 7 个）
            'MultiPoint',              # MultiPoint 多点服务（教室场景）
            'Sysmon',                  # 系统监视器（Sysmon、Sysmon-Service）
            'HostGuardian',            # 主机守护（HGS，虚拟化安全）
            'AppServerClient',         # 远程应用客户端（RemoteApp）
            'NetFx4-AdvSrvs',          # .NET 高级服务（WCF/ASP.NET 扩展）
            'NetFx4Extended-ASPNET45', # ASP.NET 4.5 扩展
            'SmbDirect',               # RDMA 网卡直连（家用网卡用不到）
            'InternetPrinting',        # 互联网打印（本地打印/存 PDF 不受影响）
            'Recall'                   # ⭐ AI 回溯：录屏 + 语义搜索（必须删）
        )
        # 反向白名单：即使命中上面的关键词也绝不删（用户点名 + 虚拟化/打印/搜索/安全基础）
        $featuresKeep = @(
            'DirectPlay', 'LegacyComponents',  # 旧版组件：老游戏（Age3/红警）要靠它
            'MediaPlayback', 'WindowsMediaPlayer',   # 用户点名保留的媒体播放器
            'SearchEngine',            # 开始菜单搜索
            'Windows-Defender',        # Defender 定义
            'Printing-Foundation-Features', 'PrintToPDF',  # 打印 / 另存为 PDF
            'MSRDC',                   # 远程桌面客户端
            'TIFFIFilter',             # TIFF 预览（照片看图）
            'Containers', 'Hyper-V', 'HypervisorPlatform', 'VirtualMachinePlatform',
            'Subsystem-Linux',         # Docker/WSL/虚拟机
            'Camera'                   # 相机
        )
        # /English：镜像是 zh-CN，不强制英文就解析不出 Feature Name
        $featList = @(dism.exe /Image:$mnt /Get-Features /English 2>&1 |
            Select-String 'Feature Name : (.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        Write-Info "镜像内可选功能 $($featList.Count) 个，全部列出供核对："
        foreach ($f in $featList) { Write-Host "    [feature] $f" }
        foreach ($f in $featList) {
            $hit = $false
            foreach ($pat in $featuresToRemove) { if ($f -like "*$pat*") { $hit = $true; break } }
            if (-not $hit) { continue }
            # 反向白名单优先：命中保留名单就不删（比如 XPS 关键词撞上打印组件时）
            foreach ($k in $featuresKeep) {
                if ($f -like "*$k*") { $hit = $false; Write-Host "    [feature-keep] $f"; break }
            }
            if (-not $hit) { continue }
            # 必须 /Remove：只 /Disable 不删文件，一点空间都省不下来
            dism.exe /Image:$mnt /Disable-Feature /FeatureName:$f /Remove /NoRestart 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Info "已移除可选功能: $f" }
            else { Write-Host "    [feature-fail] $f (退出码 $LASTEXITCODE)" }
        }

        # ---- 2d. 离线组件清理：清掉 LCU/更新集成后残留的 superseded 旧组件 ----
        # 这是无损的：删的都是"已被新版本替代、永远不会被用到"的旧文件，
        # 微软官方支持在挂载镜像上做。通常能再省几百 MB。
        Write-Info "离线组件清理 StartComponentCleanup /ResetBase（可能 10~20 分钟）..."
        $swClean = [System.Diagnostics.Stopwatch]::StartNew()
        dism.exe /Image:$mnt /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 |
            ForEach-Object { Write-Host $_ }
        $cleanCode = $LASTEXITCODE
        $swClean.Stop()
        if ($cleanCode -eq 0) {
            Write-Info ("离线组件清理完成（{0} 分钟）" -f [int]$swClean.Elapsed.TotalMinutes)
        } else {
            Write-Warning "离线组件清理失败（退出码 $cleanCode），不影响构建，只是少省点空间"
        }

        # ---- 2e. 体积诊断（清理后）：和清理前对比算出这一步的净收益 ----
        foreach ($t in $sizeTargets) {
            $v = Get-DirSizeMb (Join-Path $mnt $t)
            if ($null -ne $v -and $null -ne $sizeBefore[$t]) {
                $delta = [math]::Round($v - $sizeBefore[$t], 1)
                Write-Host ("    [size:清理后] {0,-44} {1,9} MB  ({2} MB)" -f $t, $v,
                    $(if ($delta -ge 0) { "+$delta" } else { "$delta" }))
            }
        }

        # ---- 3. 禁用服务 ----
        # 只禁用「纯后台/遥测/社交/没人用」的服务，且只在离线 hive 里真实存在时才改。
        # 刻意保留（改了会把系统搞坏或砍掉基础功能）：
        #   Spooler(打印) / WinDefend、SecurityHealthService、WdNisSvc(安全中心) /
        #   wuauserv(Windows 更新) / TrustedInstaller、AppXSvc、StateRepository、AppReadiness(装应用) /
        #   Themes(界面主题) / MpsSvc(防火墙) / LanmanServer、LanmanWorkstation(局域网共享) /
        #   TermService、UmRdpService(远程桌面) / Netlogon、KeyIso、EventSystem(账户/事件) /
        #   EFS / msiserver(MSI 安装) / RasMan、RasAuto(VPN) / WSearch、SearchIndexer(搜索) /
        #   CDPUserSvc、CDPSvc(投屏/剪贴板同步) / TabletInputService(触摸键盘) / SharedAccess(移动热点) /
        #   LSM、RpcSs、DcomLaunch(系统核心) / BrokerInfrastructure、SystemEventsBroker(后台任务)
        $servicesToDisable = @(
            # 遥测 / 诊断 / 错误报告
            'DiagTrack', 'dmwappushservice', 'DPS', 'WerSvc', 'PcaSvc',
            'WdiServiceHost', 'WdiSystemHost', 'Wecsvc',
            # 位置 / 商店演示 / 家长控制 / 钱包 / 地图
            'lfsvc', 'RetailDemo', 'WPCSvc', 'WalletService', 'MapsBroker',
            # 媒体网络共享、WebDAV、BranchCache、P2P 传输（都不影响正常上网）
            'WMPNetworkSvc', 'WebClient', 'PeerDistSvc', 'PeerNetUdp',
            # 传感器 / 智能卡 / 生物识别（台式机基本用不到）
            'SensrSvc', 'SCardSvr', 'WbioSrvc',
            # 电话/传真/打印通知（真正的打印 Spooler 保留）
            'PhoneSvc', 'Fax', 'PrintNotify', 'PrintScanBrokerService',
            # Xbox / Game Bar 后台社交
            'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
            'XboxAccessoryManagementService', 'GameBarFTServer', 'GameDVR_Svc',
            # 设备元数据 / 商店推送安装 / 远程注册表 / 嵌入式模式
            'DevicesAnalytics', 'PushToInstall', 'RemoteRegistry', 'EmbeddedMode',
            # 远程桌面 USB 重定向（TermService 保留，仍可远程桌面）
            'UmRdpService',
            # Windows Insider 服务 / 扫描仪 WIA（不用扫描仪，Spooler 保留）
            'wisvc', 'stisvc'
        ) | Select-Object -Unique

        $systemHive = Join-Path $mnt 'Windows\System32\config\SYSTEM'
        Write-Info "SYSTEM hive 路径: $systemHive"
        if (Test-Path -LiteralPath $systemHive) {
            $hiveLabel = 'HKLM\WWINBLDG_SYSTEM'
            $hivePSDrive = 'WWINBLDG_SYSTEM'
            $null = reg.exe load $hiveLabel $systemHive 2>&1
            Write-Info "SYSTEM hive load 结果: $LASTEXITCODE"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "SYSTEM hive load 失败，跳过服务优化"
            } else {
                # 离线镜像没有 CurrentControlSet，改用 ControlSet001，直接调 reg add 避免 PS 持有句柄
                # 注意：$hiveLabel 已含 HKLM\ 前缀，路径不能再拼一次 HKLM\
                foreach ($svc in $servicesToDisable) {
                    $svcKey = "$hiveLabel\ControlSet001\Services\$svc"
                    try {
                        reg.exe query $svcKey 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { continue }   # 镜像里没这个服务，跳过
                        $null = reg.exe add $svcKey /v Start /t REG_DWORD /d 4 /f 2>&1
                        if ($LASTEXITCODE -eq 0) { Write-Info "已禁用服务: $svc" }
                    } catch { <# ignore #> }
                }
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 200
                $null = reg.exe unload $hiveLabel 2>&1
                Write-Info "SYSTEM hive unload 结果: $LASTEXITCODE"
                Remove-PSDrive -Name $hivePSDrive -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warning "SYSTEM hive 不存在: $systemHive"
        }

        # ---- 4. 注册表优化（加载 SOFTWARE hive 注入）----
        $softwareHive = Join-Path $mnt 'Windows\System32\config\SOFTWARE'
        if (Test-Path -LiteralPath $softwareHive) {
            $hiveLabel = 'HKLM\WWINBLDG_SOFTWARE'
            $hivePSDrive = 'WWINBLDG_SOFTWARE'
            $null = reg.exe load $hiveLabel $softwareHive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $psDriveExists = Get-PSDrive $hivePSDrive -ErrorAction SilentlyContinue
                if (-not $psDriveExists) {
                    $null = New-PSDrive -Name $hivePSDrive -PSProvider Registry -Root "HKLM:\\$hivePSDrive" -ErrorAction SilentlyContinue
                }
                # 遥测/诊断/隐私/性能（所有优化一次性写入）
                $regPaths = @(
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = 'AllowTelemetry'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = 'AllowDiagnosticData'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\DataCollection"; Name = 'AllowTelemetry'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\DataCollection"; Name = 'AllowDiagnosticData'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\SQMClient\Windows"; Name = 'CEIPEnable'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'EnableLUA'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Error Reporting"; Name = 'Disabled'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\Windows Error Reporting"; Name = 'Disabled'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\CloudContent"; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\CloudContent"; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\GameBar"; Name = 'AutoGameModeEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\GameBar"; Name = 'UseNexusForGameBarEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\GameBar"; Name = 'GameBarEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\GameBar"; Name = 'AllowAutoGameMode'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\GameConfigStore"; Name = 'GameDVR_Enabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\GameDVR"; Name = 'AllowGameDVR'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'AllowCortana'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'AllowCortanaAboveLock'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'ConnectedSearchUseWeb'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'ConnectedSearchUseWebOverMeteredConnections'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search"; Name = 'CortanaConsent'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search"; Name = 'SearchBoxTaskbarMode'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'EnableSmartScreen'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows Defender\Real-Time Protection"; Name = 'DisableRealtimeMonitoring'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\Server\ServerManager\Tasks\Startup"; Name = 'WindowsManagementInstrumentation'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'EnableTaskScheduler'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = 'NoAutoplayfornon-volume devices'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = 'NoDriveTypeAutoRun'; Value = 255; Type = 'DWord' },
                    # ---- 禁止自动更新（用户硬需求：装完和 OOBE 都不能自己更）----
                    # NoAutoUpdate=1  → 彻底关掉"自动检查/下载/安装"，但设置里手动
                    #                   "检查更新"仍然可用（手动更新能力保留）；
                    # AUOptions=2     → 万一策略被绕过，也只允许"通知下载并通知安装"；
                    # AutoInstallMinorUpdates=0 → 连小更新都不许悄悄装；
                    # Defer 400 天    → 功能更新/质量更新推迟到 400 天（约等于永不来）；
                    # NoAutoRebootWithLoggedOnUsers=1 → 就算有更新也不许自动重启；
                    # ExcludeWUDriversInQualityUpdate=1 → Windows Update 不自动装驱动。
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = 'NoAutoUpdate'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = 'AUOptions'; Value = 2; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = 'AutoInstallMinorUpdates'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'DeferFeatureUpdatesPeriodInDays'; Value = 400; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'DeferQualityUpdatesPeriodInDays'; Value = 400; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'NoAutoRebootWithLoggedOnUsers'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1; Type = 'DWord' },
                    # 应用商店也不许自己更新（否则被删的预装应用可能被商店推回来）
                    @{ Path = "$hiveLabel\Policies\Microsoft\WindowsStore"; Name = 'DisableAutoUpdate'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\DeliveryOptimization"; Name = 'DownloadMode'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\DeliveryOptimization"; Name = 'DeviceUniqueId'; Value = ''; Type = 'String' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\DeliveryOptimization"; Name = 'CacheMemorySizeInBytes'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\DeliveryOptimization"; Name = 'CacheMemorySizeInBytes'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\NCSI"; Name = 'EnableActiveProbing'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'EnableSmartScreen'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\DNSClient"; Name = 'DisableSmartNameResolution'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\DNSClient"; Name = 'DisableMulticast'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = 'NoAutoplayfornon-volume devices'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = 'NoAutorun'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'AllowCortana'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'AllowCortanaAboveLock'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search"; Name = 'CortanaConsent'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Search"; Name = 'DisableAIDataAnalysis'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search"; Name = 'SearchBoxTaskbarMode'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search"; Name = 'SearchboxTaskbarMode'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search\Flighting"; Name = 'HyperPersonalization'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Search\Flighting"; Name = 'ImmersiveSearch'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'TaskbarAl'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'ShowTaskViewButton'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'TaskbarAI'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'DisableAIAnalytics'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = 'HideChatIcon'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\Windows Chat"; Name = 'ChatIcon'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\WindowsAI"; Name = 'RemoveMicrosoftCopilotApp'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsAI"; Name = 'DisableAIActions'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsAI"; Name = 'DisableClickToDo'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\WindowsAI"; Name = 'RemoveMicrosoftCopilotApp'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\WindowsAI"; Name = 'DisableAIActions'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\WindowsAI"; Name = 'DisableClickToDo'; Value = 1; Type = 'DWord' },

                    # ---- 锁屏聚焦 / 开始菜单推广 / 广告（CloudContent 策略）----
                    # DisableWindowsSpotlightFeatures=1 → 锁屏不再轮播"Windows 聚焦"壁纸（省网络+省后台）
                    # DisableSoftLanding=1             → 开始菜单不再推"提示和建议"
                    # DisableThirdPartySuggestions=1   → 不推第三方应用建议
                    # DisableTailoredExperiencesWithDiagnosticData=1 → 不用诊断数据做个性化推荐
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableWindowsSpotlightFeatures'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableWindowsSpotlightOnSettings'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableWindowsSpotlightOnActionCenter'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableSoftLanding'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableThirdPartySuggestions'; Value = 1; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\CloudContent"; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1; Type = 'DWord' },

                    # ---- 广告 ID / 个性化广告 ----
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\AdvertisingInfo"; Name = 'DisabledByGroupPolicy'; Value = 1; Type = 'DWord' },

                    # ---- 活动历史记录（时间线 / 云端同步用户操作）----
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\System"; Name = 'EnableActivityFeed'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\System"; Name = 'PublishUserActivities'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\System"; Name = 'UploadUserActivities'; Value = 0; Type = 'DWord' },

                    # ---- 关掉 C 盘预留空间（Win11 默认锁约 7 GB 给"更新储备"）----
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\ReserveManager"; Name = 'ShippedWithReserves'; Value = 0; Type = 'DWord' },

                    # ---- 静默装应用（HKLM 版，配合 DEFAULT hive 的 HKCU 版双保险）----
                    # SilentInstalledAppsEnabled=0 → 系统不再往开始菜单里"赠送"Candy Crush 之类
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SilentInstalledAppsEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'PreInstalledAppsEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'OemPreInstalledAppsEnabled'; Value = 0; Type = 'DWord' },

                    # ---- OneDrive：卸载首次登录自动安装（Run 键删值）----
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Run"; Name = 'OneDriveSetup'; Value = ''; Type = 'Delete' },
                    @{ Path = "$hiveLabel\Wow6432Node\Microsoft\Windows\CurrentVersion\Run"; Name = 'OneDriveSetup'; Value = ''; Type = 'Delete' }
                )

                # 跳过 OOBE 相关（skip_oobe 打开时才写）：
                #   BypassNRO=1            —— OOBE 不再强制「必须联网 + 登录微软账户」，
                #                              断网时会直接给出「我没有互联网连接 → 创建本地账户」入口；
                #   DisablePrivacyExperience —— 直接跳过 OOBE 的隐私设置（位置/诊断/广告 ID…）整页；
                #   EnableFirstLogonAnimation=0 —— 去掉首次登录的转圈欢迎动画，进桌面更快。
                if ($SkipOobe) {
                    $regPaths += @(
                        @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\OOBE"; Name = 'BypassNRO'; Value = 1; Type = 'DWord' },
                        @{ Path = "$hiveLabel\Policies\Microsoft\Windows\OOBE"; Name = 'DisablePrivacyExperience'; Value = 1; Type = 'DWord' },
                        @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'EnableFirstLogonAnimation'; Value = 0; Type = 'DWord' }
                    )
                }

                # 注册表优化：直接调 reg add，避免 PS 持有句柄，所有 reg add 子进程各自退出
                foreach ($reg in $regPaths) {
                    $keyPath = $reg.Path
                    try {
                        if ($reg.Type -eq 'DWord') {
                            $null = reg.exe add $keyPath /v $reg.Name /t REG_DWORD /d $reg.Value /f 2>&1
                        } elseif ($reg.Type -eq 'Delete') {
                            # 删值（OneDrive 的 Run 键之类），值不存在时 reg 会返回非 0，忽略即可
                            $null = reg.exe delete $keyPath /v $reg.Name /f 2>&1
                        } else {
                            $null = reg.exe add $keyPath /v $reg.Name /t REG_SZ /d $reg.Value /f 2>&1
                        }
                        if ($LASTEXITCODE -eq 0) {
                            if ($reg.Type -eq 'Delete') { Write-Info "已删除注册表值: $($reg.Path)\\$($reg.Name)" }
                            else { Write-Info "已设置注册表: $($reg.Path)\\$($reg.Name) = $($reg.Value)" }
                        }
                    } catch { <# ignore #> }
                }
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 200
                reg.exe unload $hiveLabel 2>&1 | Out-Null
                Write-Info "SOFTWARE hive unload 结果: $LASTEXITCODE"
                Remove-PSDrive -Name $hivePSDrive -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- 4c. 删掉会自己跑更新的计划任务 ----
        # 策略（NoAutoUpdate）只管"Windows Update 主程序"，计划任务是另一条触发路径。
        # 直接删 Tasks 目录下的任务文件即可，离线状态最省事，且只删更新/遥测类，
        # 不碰磁盘整理、系统诊断、Defender 扫描这些正经任务。
        $tasksDir = Join-Path $mnt 'Windows\System32\Tasks\Microsoft\Windows'
        $taskFiles = @(
            'WindowsUpdate\Scheduled Start',          # ⭐ 例行 Windows 更新（会自动下载安装）
            'WindowsUpdate\Orchestrator\USO_UxBroker',# 更新编排器
            'WindowsUpdate\Orchestrator\UpdateOrchestrator',
            'Automatic App Update',                   # 商店应用自动更新
            'Maps\MapsToastTask', 'Maps\MapsUpdateTask',
            'Customer Experience Improvement Program\Consolidator',
            'Customer Experience Improvement Program\UsbCeip',
            'Application Experience\Microsoft Compatibility Appraiser',
            'Application Experience\ProgramDataUpdater',
            'DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
        )
        foreach ($t in $taskFiles) {
            $tf = Join-Path $tasksDir $t
            if (Test-Path -LiteralPath $tf) {
                try {
                    Remove-Item -LiteralPath $tf -Force -ErrorAction Stop
                    Write-Info "已删除计划任务: $t"
                } catch { Write-Warning "删除计划任务 $t 失败: $_" }
            }
        }

        # ---- 4b. DEFAULT 用户 hive：新用户首次登录的 HKCU 默认值 ----
        # Windows 新建账户时会拷贝 C:\Users\Default\NTUSER.DAT 当模板，
        # 所以下面写进去的值对**之后创建的每个账户**都生效。
        # 之前有一半优化写在 HKLM 下，其实根本改不到这些 per-user 键（白写）。
        $defaultHive = Join-Path $mnt 'Users\Default\NTUSER.DAT'
        if (Test-Path -LiteralPath $defaultHive) {
            $hiveLabel = 'HKLM\WWINBLDG_DEFAULT'
            $null = reg.exe load $hiveLabel $defaultHive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $defaultReg = @(
                    # 不让系统静默给新账户塞应用（"装完自己又冒出一堆 Appx"的元凶）
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SilentInstalledAppsEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'PreInstalledAppsEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'OemPreInstalledAppsEnabled'; Value = 0; Type = 'DWord' },
                    # 开始菜单"推荐的项目" / 应用推广（338388=推荐、338389=提示、338393=账户提示）
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SystemPaneSuggestionsEnabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SubscribedContent-338388Enabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SubscribedContent-338389Enabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'SubscribedContent-338393Enabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = 'RotatingLockScreenOverlayEnabled'; Value = 0; Type = 'DWord' },
                    # 广告 ID / 诊断数据个性化
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; Name = 'Enabled'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0; Type = 'DWord' },
                    # 任务栏：隐藏小组件按钮（WebExperience 已移除，留着是死按钮）、隐藏"任务视图"
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'TaskbarDa'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'ShowTaskViewButton'; Value = 0; Type = 'DWord' },
                    # 搜索框只留图标，省一段常驻 UI
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Search"; Name = 'SearchboxTaskbarMode'; Value = 2; Type = 'DWord' },
                    # 资源管理器：显示文件扩展名（防钓鱼 .exe 伪装）+ 打开时直接进"此电脑"
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'HideFileExt'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'LaunchTo'; Value = 1; Type = 'DWord' },
                    # 性能：关掉透明特效（少一层合成）、新程序不延迟高亮
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = 'EnableTransparency'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize"; Name = 'StartupDelayInMSec'; Value = 0; Type = 'DWord' },
                    # 位置服务（系统级关闭，设置→隐私 里可再开）
                    @{ Path = "$hiveLabel\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = 'Value'; Value = 'Deny'; Type = 'String' }
                )
                foreach ($reg in $defaultReg) {
                    try {
                        if ($reg.Type -eq 'DWord') {
                            $null = reg.exe add $reg.Path /v $reg.Name /t REG_DWORD /d $reg.Value /f 2>&1
                        } else {
                            $null = reg.exe add $reg.Path /v $reg.Name /t REG_SZ /d $reg.Value /f 2>&1
                        }
                        if ($LASTEXITCODE -eq 0) { Write-Info "已设置默认账户注册表: $($reg.Name) = $($reg.Value)" }
                    } catch { <# ignore #> }
                }
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 200
                $null = reg.exe unload $hiveLabel 2>&1
                Write-Info "DEFAULT hive unload 结果: $LASTEXITCODE"
            } else {
                Write-Warning "DEFAULT hive load 失败，跳过新用户默认值优化"
            }
        }

        # ---- 5. 写入 SetupComplete.cmd + FirstBoot.ps1 ----
        $scriptsDir = Join-Path $mnt 'Windows\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
        $setupComplete = Join-Path $scriptsDir 'SetupComplete.cmd'
        $setupCompleteContent = @'
@echo off
REM ===== SYSTEM-Intel-MIC SetupComplete（SYSTEM 身份、首次登录前执行）=====
REM 1) 后台启动 Office 离线安装
REM 2) 后台起激活器 Activate.cmd：等 Office 装完 -> 等联网 -> MAS 无人值守激活
REM 3) 注册 RunOnce，让 FirstBoot.ps1 在用户第一次进桌面时弹窗显示进度

if exist "C:\OfficeInstall\setup.exe" (
    echo [SYSTEM-Intel-MIC] Starting Office offline installation...
    start "" /MIN "C:\OfficeInstall\setup.exe" /configure "C:\OfficeInstall\configuration.xml"
)

if exist "C:\FirstBoot\Activate.cmd" (
    echo [SYSTEM-Intel-MIC] Starting background activator...
    start "" /B cmd /c C:\FirstBoot\Activate.cmd
)

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v SYSTEM_Intel_MIC_FirstBoot /t REG_SZ /d "powershell -NoProfile -ExecutionPolicy Bypass -File C:\FirstBoot\FirstBoot.ps1" /f

exit /b 0
'@
        Set-Content -LiteralPath $setupComplete -Value $setupCompleteContent -Encoding Ascii

                $firstBootDir = Join-Path $mnt 'FirstBoot'
        New-Item -ItemType Directory -Force -Path $firstBootDir | Out-Null

        # ---- Activate.cmd：SYSTEM 后台跑的激活器 ----
        # 为什么不在 FirstBoot.ps1 里直接跑 MAS：
        #   * FirstBoot.ps1 是普通用户会话，跑 HWID 要弹 UAC、还可能没权限；
        #   * 26100+ 的 HWID/TSforge 必须联网，而用户可能还没连网；
        #   * Office 还没装完时跑 Ohook 一定失败。
        # 所以交给 SetupComplete 起的 SYSTEM 后台进程，按顺序等两件事再跑 MAS，
        # 结果写成标记文件，前台的 FirstBoot.ps1 只负责显示。
        $activateCmd = Join-Path $firstBootDir 'Activate.cmd'
        $activateContent = @'
REM ===== SYSTEM-Intel-MIC Activate (SYSTEM, launched by SetupComplete) =====
REM Wait for Office -> wait for network -> run MAS unattended -> write result marker
setlocal enabledelayedexpansion
set LOG=C:\FirstBoot\activation.log
set RES=C:\FirstBoot\ACTIVATION_RESULT.txt
set WAITED=0
set ONLINE=0
set HWIDCODE=NA
set OHOOKCODE=NA
set WIN_LICENSE=NA
echo [%date% %time%] activator start > "%LOG%"

REM --- 1) Wait until FirstBoot writes OFFICE_DONE (it installs Office), max 90 min ---
:waitoffice
if exist "C:\FirstBoot\OFFICE_DONE" goto officedone
set /a WAITED+=1
if %WAITED% gtr 360 goto officedone
ping -n 16 127.0.0.1 >nul
goto waitoffice
:officedone
echo [%date% %time%] office marker: >> "%LOG%"
if exist "C:\FirstBoot\OFFICE_DONE" type "C:\FirstBoot\OFFICE_DONE" >> "%LOG%"

REM --- 2) Wait for network (26100+ HWID/TSforge needs it), max 30 min ---
set WAITED=0
:waitnet
ping -n 1 -w 2000 223.5.5.5 >nul 2>&1
if not errorlevel 1 goto netok
ping -n 1 -w 2000 114.114.114.114 >nul 2>&1
if not errorlevel 1 goto netok
set /a WAITED+=1
if %WAITED% gtr 60 goto netgone
ping -n 31 127.0.0.1 >nul
goto waitnet
:netok
set ONLINE=1
echo [%date% %time%] network is up >> "%LOG%"
goto dorun
:netgone
echo [%date% %time%] no network after 30 min, Office offline activation only >> "%LOG%"

:dorun
REM --- 3) MAS unattended: any switch selects unattended mode (no menu, no keypress). ---
REM     HWID and Ohook run as TWO separate calls so neither one gets skipped:
REM       /HWID  = Windows digital license (needs network)
REM       /Ohook = Office permanent activation (works offline)
if %ONLINE% equ 1 call "C:\MAS\MAS_AIO.cmd" /HWID /S >> "%LOG%" 2>&1
if %ONLINE% equ 1 set HWIDCODE=!errorlevel!
call "C:\MAS\MAS_AIO.cmd" /Ohook /S >> "%LOG%" 2>&1
set OHOOKCODE=!errorlevel!
echo [%date% %time%] MAS exit: HWID=!HWIDCODE! OHOOK=!OHOOKCODE! >> "%LOG%"

REM --- 4) Double check the real Windows license state via WMI (no GUI, no popup) ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Get-CimInstance SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL AND LicenseStatus = 1' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p) { '1' } else { '0' }" > "%TEMP%\wl.txt" 2>&1
findstr /r /x /c:"1" "%TEMP%\wl.txt" >nul 2>&1
if not errorlevel 1 set WIN_LICENSE=1
findstr /r /x /c:"0" "%TEMP%\wl.txt" >nul 2>&1
if not errorlevel 1 set WIN_LICENSE=0

REM --- 5) Result marker read by FirstBoot.ps1 ---
if %ONLINE% equ 1 goto resonline
echo NETWORK=OFFLINE> "%RES%"
goto resdone
:resonline
echo NETWORK=OK> "%RES%"
:resdone
echo HWID_EXIT=!HWIDCODE!>> "%RES%"
echo OHOOK_EXIT=!OHOOKCODE!>> "%RES%"
echo WIN_LICENSE=!WIN_LICENSE!>> "%RES%"
echo DONE>> "%RES%"
echo [%date% %time%] activator finished, WIN_LICENSE=!WIN_LICENSE! >> "%LOG%"
endlocal
exit /b 0

'@
        # Ascii 写出：Activate.cmd 里全是英文注释，杜绝编码歧义
        Set-Content -LiteralPath $activateCmd -Value $activateContent -Encoding Ascii

        $firstBootPs1 = Join-Path $firstBootDir 'FirstBoot.ps1'
        $firstBootContent = @'
# SYSTEM-Intel-MIC FirstBoot Orchestrator（普通用户会话，RunOnce 触发）
# 只做三件事：
#   1) 显示"正在安装 Office / 正在激活"的进度窗口；
#   2) 等 Office 装完（需要时补拉一次 setup.exe）；
#   3) 读后台激活器写的结果标记，把"激活成功/失败"显示出来。
# 真正跑 MAS 的是 SetupComplete 起的 SYSTEM 后台进程 Activate.cmd ——
# 这里**不碰** MAS，避免普通用户权限不足、没联网、Office 还没装完这三种坑。

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- RunOnce 自删除（只执行一次）---
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v SYSTEM_Intel_MIC_FirstBoot /f 2>&1 | Out-Null

# --- 顶级置顶窗口（始终在最前，可手动关闭）---
$win = New-Object System.Windows.Window
$win.Title = "SYSTEM-Intel-MIC 优化版 Windows 11"
$win.Width = 540; $win.Height = 380
$win.WindowStartupLocation = 'CenterScreen'
$win.Topmost = $true
$win.ResizeMode = 'NoResize'
$win.ShowInTaskbar = $false
$win.Background = [System.Windows.Media.Brushes]::White

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Margin = '20'
$stack.Orientation = 'Vertical'

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = "SYSTEM-Intel-MIC Windows 11 优化版"
$title.FontSize = 20
$title.FontWeight = 'Bold'
$title.Margin = '0,0,0,10'
$stack.Children.Add($title)

$status = New-Object System.Windows.Controls.TextBlock
$status.Text = "正在初始化，请稍候..."
$status.TextWrapping = 'Wrap'
$status.FontSize = 14
$status.Margin = '0,0,0,8'
$stack.Children.Add($status)

$info = New-Object System.Windows.Controls.TextBlock
$info.Text = "• 由 SYSTEM-Intel-MIC 构建`r`n• 已移除：AI/Copilot/Recall/Teams/Outlook/OneDrive/Xbox/纸牌/资讯/手机连接/获取帮助`r`n• 已禁用：自动更新（含 OOBE）/遥测/广告/推送安装`r`n• 保留：记事本/PowerShell/画图/计算器/Edge/商店/照片/相机/媒体播放器`r`n• B站主页：https://space.bilibili.com/1978487514"
$info.TextWrapping = 'Wrap'
$info.FontSize = 12
$info.Foreground = [System.Windows.Media.Brushes]::Gray
$stack.Children.Add($info)

$win.Content = $stack
$win.Show()

$updateStatus = {
    param($msg)
    $status.Dispatcher.Invoke([Action]{ $status.Text = $msg })
}

# --- 1. 等待 Office 安装完成（SetupComplete 已用 SYSTEM 启动，这里只等待/补拉）---
$officeExe = 'C:\OfficeInstall\setup.exe'
$officeConf = 'C:\OfficeInstall\configuration.xml'
function Get-OfficeSetupRunning {
    try {
        return [bool](Get-CimInstance -ClassName Win32_Process -Filter "Name='setup.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like 'C:\OfficeInstall\*' })
    } catch { return $false }
}
if ((Test-Path -LiteralPath $officeExe) -and (Test-Path -LiteralPath $officeConf)) {
    if (-not (Get-OfficeSetupRunning)) {
        # SetupComplete 那边没起来（或已结束），这里补一次
        Start-Process -FilePath $officeExe -ArgumentList "/configure `"$officeConf`"" -NoNewWindow | Out-Null
    }
    $deadline = (Get-Date).AddMinutes(60)
    while ((Get-OfficeSetupRunning) -and (Get-Date) -lt $deadline) {
        & $updateStatus "正在安装 Office 365 (Word/Excel/PowerPoint)，请勿关机或断电..."
        Start-Sleep -Seconds 15
    }
}

# --- 1.5 安装完成后清理离线安装包（C:\OfficeInstall 约 3.6 GB，装完就是纯废文件）---
$officeRoot = 'C:\OfficeInstall'
if ((Test-Path -LiteralPath $officeRoot) -and -not (Get-OfficeSetupRunning)) {
    # 只有确认真装上了才删：装失败时这是唯一的离线安装源，删了就永远补不回来
    $appsOk = $true
    foreach ($exe in @('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE')) {
        $hit = (Test-Path -LiteralPath ("C:\Program Files\Microsoft Office\root\Office16\$exe")) -or
               (Test-Path -LiteralPath ("C:\Program Files (x86)\Microsoft Office\root\Office16\$exe"))
        if (-not $hit) { $appsOk = $false }
    }
    if ($appsOk) {
        & $updateStatus "Office 安装完成，正在清理安装包（释放约 3.6 GB 磁盘空间）..."
        Start-Sleep -Seconds 20   # 等 Click-To-Run 把文件句柄放干净，否则删到一半会失败
        for ($i = 1; $i -le 3; $i++) {
            try {
                Remove-Item -LiteralPath $officeRoot -Recurse -Force -ErrorAction Stop
                break
            } catch {
                Start-Sleep -Seconds 10
            }
        }
        if (-not (Test-Path -LiteralPath $officeRoot)) {
            & $updateStatus "✅ 已清理 Office 安装包，释放 3.6 GB"
        } else {
            & $updateStatus "Office 已安装（安装包清理失败，可手动删除 $officeRoot）"
        }
        Start-Sleep -Seconds 3
    } else {
        & $updateStatus "Office 未能确认安装成功，保留 $officeRoot 以便重试"
        Start-Sleep -Seconds 3
    }
}

# --- 1.9 通知后台激活器：Office 这一步已经结束（装完/没装/失败都算结束）---
# 后台 Activate.cmd 只认这个标记，避免它在那儿盲等一个根本没起来的 setup.exe。
$officeState = if (-not (Test-Path -LiteralPath $officeRoot)) { 'SKIP' }
               elseif (-not (Get-OfficeSetupRunning)) { 'DONE' } else { 'TIMEOUT' }
Set-Content -LiteralPath 'C:\FirstBoot\OFFICE_DONE' -Value "$officeState $(Get-Date -Format s)" -Encoding Ascii

# --- 2. 等后台激活器（Activate.cmd）写结果标记 ---
# 它会先等 Office 装完、再等联网，然后用无人值守模式跑 MAS（/HWID /Ohook /S）。
$resultFile = 'C:\FirstBoot\ACTIVATION_RESULT.txt'
$deadline = (Get-Date).AddMinutes(60)
while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) {
    & $updateStatus "正在激活 Windows + Office（等待联网并运行 MAS，无需操作）..."
    Start-Sleep -Seconds 10
}

# --- 3. 显示激活结果 ---
function Get-ResValue([object[]] $Lines, [string] $Key) {
    $hit = $Lines | Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($hit) { return ($hit -replace [regex]::Escape("$Key="), '') }
    return $null
}
$verdict = ''
$tail = ''
if (Test-Path -LiteralPath $resultFile) {
    $raw = @(Get-Content -LiteralPath $resultFile -ErrorAction SilentlyContinue)
    $net  = Get-ResValue $raw 'NETWORK'
    $hwid = Get-ResValue $raw 'HWID_EXIT'
    $ohk  = Get-ResValue $raw 'OHOOK_EXIT'
    $logF = 'C:\FirstBoot\activation.log'
    if (Test-Path -LiteralPath $logF) { $tail = ((Get-Content -LiteralPath $logF -Tail 8) -join "`r`n") }
    # Windows 以真实授权状态为准（WIN_LICENSE=1 表示已授权），拿不到再退回退出码
    $lic = Get-ResValue $raw 'WIN_LICENSE'
    $winOk  = if ($lic -eq '1') { $true } elseif ($lic -eq '0') { $false } else { ($hwid -eq '0') }
    $offOk  = ($ohk -eq '0')
    $netTxt = if ($net -eq 'OFFLINE') { '离线：仅跑了 Office 离线激活，联网后可再点一次 C:\MAS\MAS_AIO.cmd 激活 Windows' }
              else { '已联网' }
    if ($winOk -and $offOk) {
        $verdict = "✅ 激活完成（$netTxt）`r`nWindows 已激活，Office (Word/Excel/PowerPoint) 已激活。"
    } else {
        $parts = @()
        if ($winOk) { $parts += 'Windows ✅ 已激活' } else { $parts += "Windows ⚠ 返回码 $hwid" }
        if ($offOk) { $parts += 'Office ✅ 已激活' } else { $parts += "Office ⚠ 返回码 $ohk" }
        $verdict = "⚠ 激活部分完成（$netTxt）`r`n" + ($parts -join "`r`n") + "`r`n可手动双击运行 C:\MAS\MAS_AIO.cmd 重试。"
    }
} else {
    $verdict = "⚠ 未等到激活结果（可能联网较慢或激活器被占用）。`r`n可手动双击运行 C:\MAS\MAS_AIO.cmd 重试。"
}

& $updateStatus $verdict
if ($tail) {
    $info.Text = "• 由 SYSTEM-Intel-MIC 构建`r`n• 激活日志尾部：`r`n$tail"
}
# 停留一会儿让用户看得到结果，也能随时手动关掉
Start-Sleep -Seconds 20
$win.Dispatcher.Invoke([Action]{ $win.Close() })
'@
        # utf8BOM：FirstBoot.ps1 由 RunOnce 里的 Windows PowerShell 5.1 执行，
        # 无 BOM 的 UTF-8 会被 5.1 当成 ANSI 解码，中文会变乱码
        Set-Content -LiteralPath $firstBootPs1 -Value $firstBootContent -Encoding UTF8BOM


        # ---- 6. 如果需要，下载 Office ODT + MAS ----
        if ($OfficeOffline -or $MasActivate) {
            $downloadDir = Join-Path $BuildDir '_downloads'
            New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
        }

        if ($OfficeOffline) {
            # ODT + Office 离线包（约 3.5 GB）由 scripts/Download-Office.ps1 负责下载：
            #   - 正常情况：workflow 在跑 UUP 下载/转换**之前**就把它后台启动了，与转换并行；
            #   - 兜底：后台没跑或没跑完，就在本地补跑一次。
            # 任何失败都只警告、跳过 Office 集成，绝不拖垮已经跑了一个多小时的镜像构建。
            try {
                $officeDlDir = if ($env:OFFICE_DL_DIR) { $env:OFFICE_DL_DIR }
                               else { Join-Path (Split-Path -Parent $BuildDir) 'office_dl' }
                $doneMarker = Join-Path $officeDlDir 'OFFICE_DL_DONE'
                $failMarker = Join-Path $officeDlDir 'OFFICE_DL_FAIL'
                $officeSrc = $null

                # 后台任务（主流程里 Start-Job 起的）：一边等一边把它的输出打进主日志
                $job = Get-Job -Name 'OfficeOfflineDownload' -ErrorAction SilentlyContinue
                if ($job) {
                    Write-Info "等待 Office 离线包并行下载（JobId=$($job.Id) -> $officeDlDir）..."
                    $deadline = (Get-Date).AddMinutes(120)
                    while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) {
                        Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  [office-dl] $_" }
                        Start-Sleep -Seconds 15
                        $job = Get-Job -Name 'OfficeOfflineDownload' -ErrorAction SilentlyContinue
                        if (-not $job) { break }
                    }
                    Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  [office-dl] $_" }
                    if ($job) {
                        Write-Info "Office 并行下载任务状态: $($job.State)"
                        if ($job.State -ne 'Completed') { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                    }
                } elseif (Test-Path -LiteralPath $officeDlDir) {
                    # 没有后台任务但目录在（比如手动预下载过），最多再等 60 秒
                    Write-Info "没有后台下载任务，检查已有目录 $officeDlDir"
                    $deadline = (Get-Date).AddSeconds(60)
                    while (-not (Test-Path -LiteralPath $doneMarker) -and
                           -not (Test-Path -LiteralPath $failMarker) -and
                           (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
                }

                if (Test-Path -LiteralPath $doneMarker) {
                    $officeSrc = $officeDlDir
                    Write-Info "Office 离线包已就绪（并行下载）: $((Get-Content -LiteralPath $doneMarker -Raw).Trim())"
                } else {
                    if (Test-Path -LiteralPath $failMarker) {
                        Write-Warning "Office 并行下载失败: $((Get-Content -LiteralPath $failMarker -Raw).Trim())"
                    }
                    Write-Info "并行下载没产出，本地补跑 Download-Office.ps1（复用同一目录，可续传）..."
                    $dlScript = Join-Path $PSScriptRoot 'Download-Office.ps1'
                    if (Test-Path -LiteralPath $dlScript) {
                        New-Item -ItemType Directory -Force -Path $officeDlDir | Out-Null
                        $logFile = Join-Path $officeDlDir 'office_fallback.log'
                        $psExe = (Get-Process -Id $PID).Path
                        # 全部输出（含 stderr）落到文件，再打回主日志，失败原因一定看得见
                        & $psExe -NoProfile -ExecutionPolicy Bypass -File $dlScript -WorkDir $officeDlDir *> $logFile
                        $code = $LASTEXITCODE
                        if (Test-Path -LiteralPath $logFile) {
                            Get-Content -LiteralPath $logFile -Tail 40 | ForEach-Object { Write-Host "  [office-dl] $_" }
                        }
                        if ($code -eq 0 -and (Test-Path -LiteralPath $doneMarker)) {
                            $officeSrc = $officeDlDir
                        } else {
                            $reason = if (Test-Path -LiteralPath $failMarker) { (Get-Content -LiteralPath $failMarker -Raw).Trim() } else { '(没有失败标记)' }
                            Write-Warning "Download-Office.ps1 退出码 ${code}: $reason"
                        }
                    } else {
                        Write-Warning "找不到 $dlScript，跳过 Office 集成"
                    }
                }

                if (-not $officeSrc) {
                    Write-Warning "Office 离线包不可用，跳过 Office 集成（ISO 照常构建）"
                } else {
                    $setupSrc = Join-Path $officeSrc 'setup.exe'
                    $cfgSrc = Join-Path $officeSrc 'configuration.xml'
                    if (-not (Test-Path -LiteralPath $setupSrc)) { throw "缺少 $setupSrc" }
                    if (-not (Test-Path -LiteralPath $cfgSrc))   { throw "缺少 $cfgSrc" }

                    # ODT 实际布局是 <SourcePath>\Office\Data\<版本>（SourcePath 不含 /Office）；
                    # 兼容旧版 ODT 的 <SourcePath>\OfficeData，遇到就搬成新布局，
                    # 这样镜像内 configuration.xml 的 SourcePath=C:\OfficeInstall 永远对得上。
                    $pkgRoot = Join-Path $officeSrc 'Office'
                    if (-not (Test-Path -LiteralPath (Join-Path $pkgRoot 'Data'))) {
                        $legacy = Join-Path $officeSrc 'OfficeData'
                        if (Test-Path -LiteralPath $legacy) {
                            New-Item -ItemType Directory -Force -Path $pkgRoot | Out-Null
                            Move-Item -LiteralPath $legacy -Destination (Join-Path $pkgRoot 'Data') -Force
                            Write-Info 'Office 数据目录已从旧布局 OfficeData 归一为 Office\Data'
                        }
                    }
                    if (-not (Test-Path -LiteralPath (Join-Path $pkgRoot 'Data'))) {
                        throw "找不到 Office 数据目录（检查了 $pkgRoot\Data 和 $legacy）"
                    }

                    $officeInstallDst = Join-Path $mnt 'OfficeInstall'
                    New-Item -ItemType Directory -Force -Path $officeInstallDst | Out-Null
                    Copy-Item -LiteralPath $setupSrc -Destination $officeInstallDst -Force
                    Copy-Item -LiteralPath $cfgSrc -Destination $officeInstallDst -Force
                    # 整个 Office 目录（含 Data\<版本>）搬进镜像 -> C:\OfficeInstall\Office\Data\<版本>
                    Copy-Item -LiteralPath $pkgRoot -Destination $officeInstallDst -Recurse -Force

                    $size = (Get-ChildItem -LiteralPath (Join-Path $officeInstallDst 'Office') -Recurse -File |
                        Measure-Object -Property Length -Sum).Sum
                    Write-Info "Office 离线包已集成到镜像（C:\OfficeInstall\Office\Data，$([math]::Round($size / 1MB, 1)) MB）"
                }
            } catch {
                Write-Warning "Office 集成失败，跳过（不影响 ISO 构建）: $_"
            }
        }

        if ($MasActivate) {
            $masDir = Join-Path $mnt 'MAS'
            New-Item -ItemType Directory -Force -Path $masDir | Out-Null
            $masUrl = 'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/All-In-One-Version-KL/MAS_AIO.cmd'
            Write-Info "下载 MAS_AIO.cmd..."
            try {
                Invoke-WebRequest -Uri $masUrl -OutFile (Join-Path $masDir 'MAS_AIO.cmd') -TimeoutSec 60 -ErrorAction Stop
                Write-Info "MAS 已集成到镜像"
            } catch {
                Write-Warning "MAS 下载失败: $_"
            }
        }

        # ---- 7. 卸载并提交 ----
        # 提交曾因挂载句柄未释放报 Error 32（文件被占用）；注册表 hive 现在都已正常 unload，
        # 这里再加：提交前强制 GC + 失败重试，最后兜底用文档化的 /Unmount-Wim /Commit。
        Write-Info "开始提交 DISM 镜像..."
        [System.GC]::Collect()
        Start-Sleep -Seconds 3
        $mounted = $true
        $commitOk = $false
        for ($i = 1; $i -le 3 -and -not $commitOk; $i++) {
            dism.exe /Unmount-Wim /MountDir:$mnt /Commit 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) { $commitOk = $true; $mounted = $false }
            else {
                Write-Warning "dism /Unmount-Wim /Commit 第 $i 次失败（退出码 $LASTEXITCODE）"
                if ($i -lt 3) { Start-Sleep -Seconds 20 }
            }
        }
        if (-not $commitOk) {
            # 兜底：/Commit-Image 保存改动（镜像保持挂载），再显式卸载
            dism.exe /Commit-Image /MountDir:$mnt 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -eq 0) {
                $commitOk = $true
                dism.exe /Unmount-Wim /MountDir:$mnt /Discard 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $mounted = $false }
            }
        }
        if (-not $commitOk) { throw "dism 提交镜像失败（3 次 /Commit-Image 重试均未成功）" }
        Write-Info "离线精简/集成完成"
    } catch {
        # 出错时尝试放弃挂载
        dism.exe /Unmount-Wim /MountDir:$mnt /Discard 2>&1 | Out-Null
        $mounted = $false
        throw "离线定制失败: $_"
    } finally {
        if ($mounted) {
            # 兜底：万一还挂着，先丢弃，避免挂载点残留导致后面封盘时文件被占用
            dism.exe /Unmount-Wim /MountDir:$mnt /Discard 2>&1 | Out-Null
        }
        if (Test-Path -LiteralPath $mnt) { Remove-Item -LiteralPath $mnt -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# 5.3 展开 ISO -> 塞文件 -> cdimage 重新封盘
# ---------------------------------------------------------------------------
function Invoke-IsoReseal([System.IO.FileInfo] $Iso, [string] $Xml) {
    # 转换器跑完后 UUPs/ 里还躺着几个 GB 的原始包，先腾地方
    foreach ($d in @('UUPs', 'ISOFOLDER', 'bin\temp', 'temp')) {
        $p = Join-Path $buildDirectory $d
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; Write-Info "已清理 $d 腾出空间" }
            catch { Write-Warning "清理 $d 失败（继续）: $_" }
        }
    }

    $label = Get-IsoLabel -Path $Iso.FullName -Fallback 'CPRA_X64FRE_ZH-CN_DV9'
    Write-Info "原 ISO 卷标: $label"

    $treeName = '_iso_tree'
    $tree = Join-Path $buildDirectory $treeName
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tree | Out-Null

    # 展开：挂载后 robocopy，跟 Windows Setup 看到的内容完全一致
    Write-Info "展开 ISO 到 $tree"
    $dismount = $false
    try {
        $vol = Mount-DiskImage -ImagePath $Iso.FullName -PassThru | Get-Volume
        $dismount = $true
        $src = "$($vol.DriveLetter):\"
        & robocopy.exe $src $tree /E /DCOPY:T /R:2 /W:2 /NFL /NDL /NJH /NJS /NP /MT:16 /A-:R | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { throw "robocopy 展开 ISO 失败，退出码 $rc" }
        Write-Info "ISO 展开完成（robocopy 退出码 $rc）"
    } finally {
        if ($dismount) { Dismount-DiskImage -ImagePath $Iso.FullName -ErrorAction SilentlyContinue | Out-Null }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tree 'sources\boot.wim'))) {
        throw "展开后的 $tree\sources\boot.wim 不存在，ISO 结构异常"
    }
    # robocopy 会把源盘的只读属性带过来，去掉才好往里写东西
    & attrib.exe -R /S /D ($tree + '\*') | Out-Null

    # ---- 深度精简：离线定制 install.wim（Appx 移除、AI/Capability 移除、注册表、服务、Office/MAS 集成）----
    if ($DeepDebloat -or $OfficeOffline -or $MasActivate -or $PerfTweaks) {
        Write-Info "开始离线深度定制 install.wim（DeepDebloat=$DeepDebloat Office=$OfficeOffline Mas=$MasActivate PerfTweaks=$PerfTweaks）..."
        Invoke-OfflineCustomization -Tree $tree -BuildDir $buildDirectory
    }

    # ---- 写入 autounattend.xml ----
    if (-not $Xml) { throw 'Invoke-IsoReseal 需要调用方先生成好 autounattend.xml 内容' }
    if (-not (Test-XmlWellFormed $Xml)) { throw "autounattend.xml 不是合法 XML：`n$Xml" }
    $answerFile = Join-Path $tree 'autounattend.xml'
    Set-Content -LiteralPath $answerFile -Value $Xml -Encoding utf8
    Write-Info "已写入 autounattend.xml ($([math]::Round((Get-Item $answerFile).Length / 1KB, 1)) KB)"

    # ---- 往 install.wim 里塞 OEM logo（失败只警告，不拖垮已经跑了一个多小时的构建）----
    if ($logoSource) {
    try {
        $wimFile = Get-ChildItem -LiteralPath (Join-Path $tree 'sources') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'install.wim' } | Select-Object -First 1
        if (-not $wimFile) {
            Write-Warning "没有 install.wim（wim2swm 模式只产 .swm），OEM logo 文件不会被注入"
        } else {
            $wimlib = Join-Path $buildDirectory 'bin\wimlib-imagex.exe'
            if (-not (Test-Path -LiteralPath $wimlib)) {
                Write-Warning "找不到 $wimlib，跳过 OEM logo 注入"
            } else {
                $imgCount = @(Get-WindowsImage -ImagePath $wimFile.FullName).Count
                $logoInWim = '\Windows\System32\oemlogo' + [System.IO.Path]::GetExtension($logoSource)
                $cmdTxt = Join-Path $buildDirectory '_iso_logo.txt'
                $cmdBat = Join-Path $buildDirectory '_iso_logo.cmd'
                Set-Content -LiteralPath $cmdTxt `
                    -Value ('add "{0}" "{1}"' -f $logoSource, $logoInWim) -Encoding utf8
                for ($i = 1; $i -le $imgCount; $i++) {
                    $rel = $treeName + '\sources\' + $wimFile.Name
                    $lines = @(
                        '@echo off'
                        ('cd /d "{0}"' -f $buildDirectory)
                        ('bin\wimlib-imagex.exe update "{0}" {1} < "{2}"' -f $rel, $i, $cmdTxt)
                        'exit /b %errorlevel%'
                    )
                    Set-Content -LiteralPath $cmdBat -Value $lines -Encoding Ascii
                    & cmd.exe /c "`"$cmdBat`"" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "wimlib 退出码 $LASTEXITCODE（第 $i/$imgCount 个镜像）" }
                }
                Write-Info "OEM logo 已注入 $($wimFile.Name) 的 $imgCount 个镜像 -> $logoInWim"
            }
        }
    } catch {
        Write-Warning "OEM logo 注入失败（不影响 ISO，只是 Logo 显示不出来）: $_"
    }
    }

    # ---- ESD 重打包：精简/Office/MAS/OEM logo 全做完了，最后才把 install.wim 用
    #      LZMS solid 重导出成 install.esd（DISM /Compress:recovery），约省 1.3~1.8 GB。
    #      放在最后是因为：esd 没法挂载定制，也没有工具能往里塞文件，只有 wim 能干活。----
    if ($Esd) {
        $sourcesDir = Join-Path $tree 'sources'
        $wimInTree = Get-ChildItem -LiteralPath $sourcesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'install.wim' } | Select-Object -First 1
        if (-not $wimInTree) {
            Write-Warning 'sources 下没有 install.wim（wim2swm？），跳过 ESD 重打包，按原样封盘'
        } else {
            $esdPath = Join-Path $sourcesDir 'install.esd'
            if (Test-Path -LiteralPath $esdPath) { Remove-Item -LiteralPath $esdPath -Force -ErrorAction SilentlyContinue }
            $wimPath = $wimInTree.FullName
            $imgCount = @(Get-WindowsImage -ImagePath $wimPath).Count
            Write-Info "ESD 重打包：install.wim 的 $imgCount 个镜像 -> install.esd（LZMS solid，这步很吃 CPU，可能要十几分钟）"
            $esdWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $esdOk = $true
            # 单镜像导出上限 90 分钟：LZMS solid 压 9GB 在 2 核 runner 上很慢，
            # 一旦超时立刻放弃 ESD 改用 wim 封盘。绝不能用 `& dism` 无限期等——
            # 上一轮就是这么把整轮构建挂了近 5 小时，最后只能取消。
            $esdTimeoutMs = 90 * 60 * 1000
            for ($i = 1; $i -le $imgCount -and $esdOk; $i++) {
                # 不加 /CheckIntegrity：它会对整个 9GB 源做全量校验，白花几十分钟，
                # 而源 wim 是本流程刚生成并提交过的，没有损坏风险。
                $dismArgs = @('/Export-Image', "/SourceImageFile:$wimPath", "/SourceIndex:$i",
                              "/DestinationImageFile:$esdPath", '/Compress:recovery')
                # 目标文件已存在时必须显式给 DestinationIndex，否则第二个镜像导不进去
                if ($i -gt 1) { $dismArgs += "/DestinationIndex:$i" }
                Write-Info "  导出镜像 $i/$imgCount （LZMS solid，上限 90 分钟，超时自动回退 wim）..."
                $swOne = [System.Diagnostics.Stopwatch]::StartNew()
                $proc = Start-Process -FilePath 'dism.exe' -ArgumentList $dismArgs -NoNewWindow -PassThru
                $finished = $proc.WaitForExit($esdTimeoutMs)
                $swOne.Stop()
                $mins = [int]$swOne.Elapsed.TotalMinutes
                if (-not $finished) {
                    try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
                    Write-Warning "  镜像 $i 导出超时（$mins 分钟），已强制结束，回退用 wim 封盘"
                    $esdOk = $false
                } elseif ($proc.ExitCode -ne 0) {
                    Write-Warning "  镜像 $i 导出失败（退出码 $($proc.ExitCode)，耗时 $mins 分钟）"
                    $esdOk = $false
                } else {
                    Write-Info "  镜像 $i 导出完成（耗时 $mins 分钟）"
                }
            }
            $esdWatch.Stop()
            if ($esdOk -and (Test-Path -LiteralPath $esdPath)) {
                $wimMB = [math]::Round($wimInTree.Length / 1MB, 1)
                $esdMB = [math]::Round((Get-Item -LiteralPath $esdPath).Length / 1MB, 1)
                Remove-Item -LiteralPath $wimPath -Force
                Write-Info ("ESD 重打包完成: {0} MB -> {1} MB（省 {2} MB，耗时 {3:n0} 秒）" -f `
                    $wimMB, $esdMB, [math]::Round($wimMB - $esdMB, 1), $esdWatch.Elapsed.TotalSeconds)
            } else {
                # 失败就丢掉半截 esd、保留 wim 原样封盘，绝不让压缩这步拖垮跑了一个多小时的构建
                Remove-Item -LiteralPath $esdPath -Force -ErrorAction SilentlyContinue
                Write-Warning 'ESD 重打包失败，保留 install.wim 原样封盘（ISO 会大 1.3~1.8 GB）'
            }
        }
    }

    # ---- 用转换器自带的 cdimage 重新封盘 ----
    $cdimage = Join-Path $buildDirectory 'bin\cdimage.exe'
    if (-not (Test-Path -LiteralPath $cdimage)) { throw "找不到 $cdimage，无法重新封盘" }
    $sevenZip = Join-Path $buildDirectory 'bin\7z.exe'
    if (-not (Test-Path -LiteralPath $sevenZip)) { $sevenZip = '7z.exe' }

    if (Test-Path -LiteralPath (Join-Path $tree 'boot\etfsboot.com')) {
        $bootdata = '-bootdata:2#p0,e,b"' + $treeName + '\boot\etfsboot.com"#pEF,e,b"' + $treeName + '\efi\Microsoft\boot\efisys.bin"'
    } else {
        $bootdata = '-bootdata:1#pEF,e,b"' + $treeName + '\efi\Microsoft\boot\efisys.bin"'
    }

    $repacked = Join-Path $buildDirectory '_iso_repacked.iso'
    if (Test-Path -LiteralPath $repacked) { Remove-Item -LiteralPath $repacked -Force }

    # 走 .cmd 而不是直接 & cdimage：-bootdata 里内嵌的引号交给 cmd 解析最省心
    $repackBat = Join-Path $buildDirectory '_iso_repack.cmd'
    $repackLog = Join-Path $buildDirectory '_iso_repack.log'
    $cdLine = 'bin\cdimage.exe ' + $bootdata +
              ' -o -m -u2 -udfver102 -l"' + $label + '" ' + $treeName + ' "' + $repacked + '"'
    $lines = @(
        '@echo off'
        ('cd /d "{0}"' -f $buildDirectory)
        $cdLine
        'exit /b %errorlevel%'
    )
    Set-Content -LiteralPath $repackBat -Value $lines -Encoding Ascii
    Write-Info "cdimage 重新封盘: $cdLine"
    # 必须赋值：Tee-Object 会把对象继续往下游输出，直接挂在函数里会污染本函数的返回值
    $repackOut = @( & cmd.exe /c "`"$repackBat`"" 2>&1 | Tee-Object -FilePath $repackLog )
    $repackOut | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::cdimage 重新封盘失败，日志最后 40 行"
        Get-Content -LiteralPath $repackLog -Tail 40 -ErrorAction SilentlyContinue | Write-Host
        throw "cdimage 重新封盘失败，退出码 $LASTEXITCODE"
    }

    # ---- 校验重新封盘的结果 ----
    $ri = Get-Item -LiteralPath $repacked
    if ($ri.Length -lt 1GB) { throw "重新封盘的 ISO 只有 $([math]::Round($ri.Length / 1MB, 1)) MB，明显异常" }
    $listing = & $sevenZip l $repacked 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "7z 无法列出重新封盘的 ISO（退出码 $LASTEXITCODE）" }
    if ($listing -notmatch '(?i)autounattend\.xml') { throw '重新封盘的 ISO 里没有 autounattend.xml' }
    if ($listing -notmatch '(?i)boot\.wim') { throw '重新封盘的 ISO 里没有 boot.wim' }
    if ($Esd) {
        if ($listing -notmatch '(?i)install\.esd') { throw '开启了 esd 但重新封盘的 ISO 里没有 install.esd' }
    } elseif ($listing -notmatch '(?i)install\.(wim|esd|swm)') {
        throw '重新封盘的 ISO 里没有 install.wim/esd/swm，Windows Setup 会装不了'
    }
    Write-Info "重新封盘成功: $([math]::Round($ri.Length / 1GB, 2)) GB"

    # ---- 清理：先删展开目录和原 ISO，再把新 ISO 改回原名 ----
    Remove-Item -LiteralPath $tree -Recurse -Force
    Remove-Item -LiteralPath $Iso.FullName -Force
    Move-Item -LiteralPath $repacked -Destination $Iso.FullName -Force
    # 副作用函数：成功输出流必须保持干净，任何东西都不许往外写（调用方用 | Out-Null 再兜一层）
}

# ---------------------------------------------------------------------------
# 5.x 预生成 autounattend.xml：在开跑前就把内容和格式都定死，省得跑了一小时才发现配错
# ---------------------------------------------------------------------------
$unattendXml = $null
if ($Unattend) {
    $unattendXml = New-UnattendXml
    if (-not $unattendXml) {
        throw 'Unattend 已开启但没有任何可写入的设置（hw_bypass / skip_oobe / local_* / oem_* 全空）'
    }
    if (-not (Test-XmlWellFormed $unattendXml)) {
        throw "生成的 autounattend.xml 不是合法 XML：`n$unattendXml"
    }
    Write-Info "autounattend.xml 草稿已生成并校验通过（$([math]::Round($unattendXml.Length / 1KB, 1)) KB）"
}

# ---------------------------------------------------------------------------
# 1. 选择构建 / 语言 / 版本
# ---------------------------------------------------------------------------
Write-Info "查找 UUP dump 构建: search='$Search' 输入=$Build 通道=$Channel 架构=$Arch"
$listId = Invoke-UupApi 'listid.php' @{ search = $Search }
$builds = @(Resolve-Builds $listId.response.builds)
Write-Info "搜索命中 $($builds.Count) 个构建"

$candidates = @($builds | Where-Object { Test-TrackTitle ([string]$_.title) })
if ($major) {
    $candidates = @($candidates | Where-Object { ([string]$_.build).StartsWith($major) })
}
if ($Build -match '^\d+\.\d+$') {
    $candidates = @($candidates | Where-Object { [string]$_.build -eq $Build })
}
$candidates = @($candidates | Sort-Object { try { [version]$_.build } catch { [version]'0.0' } } -Descending)

if (-not $candidates) {
    $seen = @($builds | Select-Object -First 8 | ForEach-Object { "      - $($_.title)" }) -join "`n"
    throw ("UUP dump 上没有符合条件的构建（输入=$Build, 通道=$Channel, 架构=$Arch）。`n" +
           "      换个构建号，或打开 https://uupdump.net/ 查看可用版本（首页 Downloads 列表里 amd64 行括号内的数字）。`n" +
           "      搜到的标题：`n$seen")
}

$target = $candidates[0]
$id = $target.uuid
$uupUrl = "$WebBase/selectlang.php?id=$id"
Write-Info "选中构建: $($target.title) ($id)"
Write-Info "UUP dump 页面: $uupUrl"

$langs = Get-ObjectKeys (Invoke-UupApi 'listlangs.php' @{ id = $id }).response.langFancyNames
if ($langs -notcontains $Lang) {
    throw "构建 $($target.title) 不提供 $Lang 语言包（可用: $($langs -join ', ')）"
}

$editionKeys = Get-ObjectKeys (Invoke-UupApi 'listeditions.php' @{ id = $id; lang = $Lang }).response.editionFancyNames
Write-Info "该构建在 $Lang 下可用版本: $($editionKeys -join ', ')"

$baseEditionQuery = 'professional'
$autodl = '2'
$virtualEdition = $null

switch ($Edition) {
    'multi' {
        if (-not ($editionKeys -contains 'PROFESSIONAL' -or $editionKeys -contains 'CORE')) {
            throw "构建不提供 CORE/PROFESSIONAL，无法生成 multi 版本"
        }
        $baseEditionQuery = 'core;professional'
    }
    'pro' {
        if ($editionKeys -notcontains 'PROFESSIONAL') { throw "构建不提供 PROFESSIONAL" }
    }
    default {
        # 企业版不是 UUP dump 的直接 SKU，用 “Create additional editions” 从专业版派生
        if ($editionKeys -notcontains 'PROFESSIONAL') { throw "构建不提供 PROFESSIONAL，无法派生企业版" }
        $autodl = '3'
        $virtualEdition = 'Enterprise'
    }
}

# ---------------------------------------------------------------------------
# 2. 下载 UUP dump 下载包
# ---------------------------------------------------------------------------
$Destination = $Destination.TrimEnd('/', '\')
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$buildDirectory = Join-Path $Destination 'uup-build'
if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory }
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null

$pkgQuery = "id=$id&pack=$([uri]::EscapeDataString($Lang))&edition=$([uri]::EscapeDataString($baseEditionQuery))"
$body = @{ autodl = $autodl; cleanup = '1' }
if (-not $NoUpdates) { $body['updates'] = '1' }
if ($virtualEdition) { $body['virtualEditions[]'] = $virtualEdition }

$pkgZip = Join-Path $Destination 'uup-package.zip'
Write-Info "下载下载包 (autodl=$autodl, updates=$(-not $NoUpdates), virtual=$virtualEdition)"
Invoke-WebRequest -Method Post -Uri "$WebBase/get.php?$pkgQuery" -Body $body -OutFile $pkgZip -TimeoutSec 120
Expand-Archive -LiteralPath $pkgZip -DestinationPath $buildDirectory -Force
Remove-Item -LiteralPath $pkgZip -Force

$cmdPath = Join-Path $buildDirectory 'uup_download_windows.cmd'
$iniPath = Join-Path $buildDirectory 'ConvertConfig.ini'
if (-not (Test-Path $cmdPath) -or -not (Test-Path $iniPath)) {
    throw "下载包内容不完整（缺少 uup_download_windows.cmd / ConvertConfig.ini）"
}

# ---------------------------------------------------------------------------
# 3. 按需调整 ConvertConfig.ini
# ---------------------------------------------------------------------------
# 可选：把仓库 Drivers/ 目录下的驱动复制进工作目录（转换器默认 Drv_Source=_work\Drivers）
$driversEnabled = $false
if ($Drivers) {
    $srcDrivers = Join-Path $repoRoot 'Drivers'
    if (Test-Path -LiteralPath $srcDrivers) {
        Copy-Item -LiteralPath $srcDrivers -Destination (Join-Path $buildDirectory 'Drivers') -Recurse -Force
        $driversEnabled = $true
        Write-Info "驱动目录已复制: $srcDrivers"
    } else {
        Write-Warning "没有找到 $srcDrivers，本次跳过驱动注入"
    }
}

$text = Get-Content -LiteralPath $iniPath -Raw
$text = Set-IniValue $text 'AutoExit' '1'          # 转换完直接退出，不等待按键
$text = Set-IniValue $text 'Cleanup' '1'           # 组件清理
if (-not $NoResetBase) { $text = Set-IniValue $text 'ResetBase' '1' }   # 重置组件基线，镜像更小
# 注意：这里**故意不设** wim2esd/vwim2esd。UUP dump 转换阶段转 esd 收益小，而且产物一旦变成
# install.esd，后面的深度精简 / Office 集成 / MAS / OEM logo 全都找不到 install.wim 只能跳过。
# 改成：全程用 wim 走完所有定制，最后在重新封盘前用 DISM /Compress:recovery
# 一次性重打包成 install.esd（见 Invoke-IsoReseal 里的「ESD 重打包」段）。
if ($NetFx3) { $text = Set-IniValue $text 'NetFx3' '1' }                # 预装 .NET Framework 3.5
if ($SkipApps) { $text = Set-IniValue $text 'SkipApps' '1' }            # 跳过预装 Store 应用
if ($SkipEdge) { $text = Set-IniValue $text 'SkipEdge' '1' }            # 跳过 Edge 集成
if ($Wim2Swm) {
    $text = Set-IniValue $text 'wim2swm' '1'                            # install.wim 拆成 .swm
    if ($Esd) { Write-Warning 'wim2swm 与 esd 同开：产物只有 .swm，ESD 重打包会找不到 install.wim 而跳过' }
}
if ($driversEnabled) { $text = Set-IniValue $text 'AddDrivers' '1' }    # 注入 Drivers/ 驱动
if ($virtualEdition) {
    $text = Set-IniValue $text 'StartVirtual' '1'
    $text = Set-IniValue $text 'vAutoEditions' $virtualEdition
    # enterprise -> 只保留企业版镜像；enterprise_pro -> 专业版+企业版都在
    $text = Set-IniValue $text 'vDeleteSource' $(if ($Edition -eq 'enterprise') { '1' } else { '0' })
}
Set-Content -LiteralPath $iniPath -Value $text -NoNewline
Hide-Aria2Noise -Path $cmdPath

# ---------------------------------------------------------------------------
# 4. 下载 UUP 文件并转换成 ISO
# ---------------------------------------------------------------------------
# 传入脚本里固定的 GUID 参数可跳过 UAC 提权重启；stdin 接 NUL 让所有 pause 立即返回
$guid = $null
if ((Get-Content -LiteralPath $cmdPath -Raw) -match 'if "\[%1\]" == "\[([0-9a-f\-]+)\]"') { $guid = $Matches[1] }

# ---------------------------------------------------------------------------
# 【关键】修正子进程的 PSModulePath
# Windows PowerShell 5.1 从 pwsh 派生时会继承 pwsh 放在最前面的 PowerShell 7 模块路径，
# 5.1 的模块自动加载先命中 PS7 的 Microsoft.PowerShell.Utility（清单要求 PS 7）就失败放弃、
# 不再向后搜索，于是 get_aria2.ps1 的 Get-FileHash 以及转换器里所有 `powershell -nop -c ...`
# 全部 CommandNotFound（见 PowerShell/PowerShell#8635："because the Core standard module
# path comes first"）。这里生成一个 cmd 包装脚本，只在子进程会话里换成「Windows PowerShell
# 优先」的 PSModulePath（并剔掉 PS7 的三条），我们自己 pwsh 的环境一点不动。
$ps7Paths = @(
    (Join-Path $PSHOME 'Modules'),
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'PowerShell\Modules')
)
$childModulePath = (@(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
) + @(($env:PSModulePath -split ';') | Where-Object { $_ -and ($ps7Paths -notcontains $_) })) -join ';'

$wrapperPath = Join-Path $buildDirectory '_winbuild_run.cmd'
$wrapperLines = @(
    '@echo off'
    "set `"PSModulePath=$childModulePath`""
    # 预检：模块路径没修好就立刻失败，别等到跑了一个小时才炸
    'powershell -NoProfile -Command "if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"'
    'if errorlevel 1 ('
    '    echo [winbuild] FAIL: Windows PowerShell cannot load Microsoft.PowerShell.Utility'
    '    exit /b 9'
    ')'
    "cd /d `"$buildDirectory`""
)
$wrapperLines += $(if ($guid) { "uup_download_windows.cmd $guid < NUL" } else { 'uup_download_windows.cmd < NUL' })
$wrapperLines += 'exit /b %errorlevel%'
Set-Content -LiteralPath $wrapperPath -Value $wrapperLines -Encoding Ascii

$rawLog = Join-Path $buildDirectory 'uup_build.log'
Write-Info "子进程 PSModulePath 已修正（以 $(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules') 开头，已剔除 PowerShell 7 模块路径）"

# ---- Office 离线包：在最耗时的 UUP 下载/转换**之前**就起后台任务，和 Windows 下载并行 ----
$officeDlDir = if ($env:OFFICE_DL_DIR) { $env:OFFICE_DL_DIR } else { Join-Path $Destination 'office_dl' }
$officeJob = $null
if ($OfficeOffline) {
    $dlScript = Join-Path $PSScriptRoot 'Download-Office.ps1'
    if (Test-Path -LiteralPath $dlScript) {
        New-Item -ItemType Directory -Force -Path $officeDlDir | Out-Null
        try {
            # Start-Job 的子进程输出可以用 Receive-Job 收回来打进主日志，失败原因看得见
            $officeJob = Start-Job -Name 'OfficeOfflineDownload' -FilePath $dlScript -ArgumentList $officeDlDir
            Write-Info "Office 离线包并行下载已启动（JobId=$($officeJob.Id) -> $officeDlDir），与 UUP 下载同时进行"
        } catch {
            Write-Warning "启动 Office 并行下载失败（稍后会本地补跑）: $_"
        }
    } else {
        Write-Warning "找不到 $dlScript，Office 将在离线集成阶段本地补跑"
    }
}

Write-Info "开始下载 UUP 文件并构建 ISO（这一步最耗时）"
Push-Location $buildDirectory
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & cmd.exe /c "`"$wrapperPath`"" 2>&1 | Tee-Object -FilePath $rawLog
} finally {
    $ErrorActionPreference = $prevEap
    Pop-Location
}

# ---------------------------------------------------------------------------
# 5. 校验产物 / 注入无人值守应答文件
# ---------------------------------------------------------------------------
$isoFile = Get-ChildItem -LiteralPath $buildDirectory -Filter '*.iso' -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending | Select-Object -First 1

if (-not $isoFile) {
    Write-Host "::error::没有生成 ISO，以下是构建日志的最后 200 行"
    Get-Content -LiteralPath $rawLog -Tail 200 -ErrorAction SilentlyContinue | Write-Host
    throw "uup_download_windows.cmd 未能生成 ISO，详见 $rawLog"
}

Write-Info "ISO 生成成功: $($isoFile.Name) ($([math]::Round($isoFile.Length / 1GB, 2)) GB)"

if ($Unattend) {
    $oemFields = @($OemOwner, $OemOrg, $OemProvider, $oemUrlValue, $OemManufacturer, $OemModel, $oemLogoPath, $OemPhone) |
        Where-Object { $_ -and $_.Trim() }
    Write-Info ("注入 autounattend.xml：免硬件检测={0} 跳过OOBE={1} 预建账户={2} OEM字段={3}个" -f `
        $HwBypass, $SkipOobe, $([bool]$LocalUser.Trim()), $oemFields.Count)
    $isoPath = $isoFile.FullName
    # | Out-Null：只取副作用，绝不信任函数的成功输出流（历史教训：Tee-Object 污染过返回值）
    Invoke-IsoReseal -Iso $isoFile -Xml $unattendXml | Out-Null
    $isoFile = Get-Item -LiteralPath $isoPath
} else {
    Write-Info "未开启 Unattend，跳过 autounattend.xml 注入"
}

$sha256 = (Get-FileHash -LiteralPath $isoFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

# 读取镜像内的版本列表（失败不影响构建）
$images = @()
try {
    $img = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru | Get-Volume
    $srcDir = "$($img.DriveLetter):\sources"
    # 产物可能是 install.wim / install.swm（wim2swm）/ install.esd（esd）
    $wim = Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('install.wim', 'install.swm', 'install.esd') } |
        Select-Object -First 1
    if ($wim) {
        $images = @(Get-WindowsImage -ImagePath $wim.FullName | ForEach-Object {
            $d = Get-WindowsImage -ImagePath $wim.FullName -Index $_.ImageIndex
            [pscustomobject]@{ index = $d.ImageIndex; name = $d.ImageName; version = $d.Version }
        })
    } else {
        Write-Warning "$srcDir 下没有 install.wim/esd/swm，跳过版本列表读取"
    }
} catch {
    Write-Warning "读取镜像内版本信息失败（不影响产物）: $_"
} finally {
    Dismount-DiskImage -ImagePath $isoFile.FullName -ErrorAction SilentlyContinue | Out-Null
}

$finalIso = Join-Path $Destination $isoFile.Name
Move-Item -LiteralPath $isoFile.FullName -Destination $finalIso -Force
$isoFileSize = (Get-Item -LiteralPath $finalIso).Length

$checksumPath = "$finalIso.sha256.txt"
Set-Content -LiteralPath $checksumPath -Value "$sha256  $($isoFile.Name)" -NoNewline -Encoding ascii

$meta = [pscustomobject]@{
    name       = $isoFile.Name
    title      = $target.title
    build      = $target.build
    buildInput = $Build
    channel    = $Channel
    edition    = $Edition
    lang       = $Lang
    arch       = $Arch
    size       = $isoFileSize
    checksum   = $sha256
    images     = $images
    options    = @{
        updates   = [bool](-not $NoUpdates)
        esd       = [bool]$Esd
        netfx3    = [bool]$NetFx3
        resetBase = [bool](-not $NoResetBase)
        skipApps  = [bool]$SkipApps
        skipEdge  = [bool]$SkipEdge
        drivers   = [bool]$driversEnabled
        wim2swm   = [bool]$Wim2Swm
        unattend  = [bool]$Unattend
        hwBypass  = [bool]($Unattend -and $HwBypass)
        skipOobe  = [bool]($Unattend -and $SkipOobe)
        oemLogo   = [string]$oemLogoPath
    }
    uupDump    = $uupUrl
}
Set-Content -LiteralPath "$finalIso.json" -Value ($meta | ConvertTo-Json -Depth 6)

Write-Info "SHA256: $sha256"

# 成功后清理 UUP 下载与转换工作目录（约 10 GB），给后面的分卷腾空间；日志单独留一份
try {
    Copy-Item -LiteralPath $rawLog -Destination (Join-Path $Destination 'uup_build.log') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force -ErrorAction Stop
    Write-Info "已清理工作目录 $buildDirectory"
} catch {
    Write-Warning "清理工作目录失败（不影响产物）: $_"
}

if ($env:GITHUB_ENV) {
    @(
        "ISO_NAME=$($isoFile.Name)",
        "ISO_PATH=$finalIso",
        "ISO_SHA256=$sha256",
        "ISO_BUILD=$($target.build)",
        "ISO_CHANNEL=$Channel",
        "ISO_TITLE=$($target.title)",
        "ISO_SIZE=$isoFileSize",
        "ISO_IMAGES=$(($images | ForEach-Object name) -join '/')",
        "UUP_URL=$uupUrl"
    ) | Add-Content -Path $env:GITHUB_ENV -Encoding utf8
}
if ($env:GITHUB_OUTPUT) {
    "iso_path=$finalIso" | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8
}

Write-Info "完成: $finalIso"
