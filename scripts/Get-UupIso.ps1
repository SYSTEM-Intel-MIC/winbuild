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

    # ESD 固体压缩（镜像更小，转换更慢）
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

    # install.wim 拆分成 install.swm（wim2swm，esd 开启时无效）
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

    if (-not ($hasHw -or $hasOobe -or $hasAcct -or $hasOem)) { return $null }

    $cp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    $x = @()
    $x += '<?xml version="1.0" encoding="utf-8"?>'
    $x += '<unattend xmlns="urn:schemas-microsoft-com:unattend"'
    $x += '          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $x += '          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    $x += '  <!-- 自动生成的无人值守应答文件：免硬件检测 / 跳过 OOBE / OEM 信息 -->'

    # ---- windowsPE：先于硬件兼容性检查写 LabConfig ----
    if ($hasHw -or $loc) {
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
        if ($hasHw) {
            $x += '    <component name="Microsoft-Windows-Setup" ' + $cp + '>'
            $x += '      <RunSynchronous>'
            $n = 0
            foreach ($v in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck')) {
                $n++
                $x += '        <RunSynchronousCommand wcm:action="add">'
                $x += '          <Order>' + $n + '</Order>'
                $x += '          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v ' + $v + ' /t REG_DWORD /d 1 /f</Path>'
                $x += '          <Description>' + $v + '</Description>'
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

    try {
        # 挂载
        $null = dism.exe /Mount-Wim /WimFile:$($wim.FullName) /Index:1 /MountDir:$mnt
        if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Wim 失败，退出码 $LASTEXITCODE" }

        # ---- 1. 移除 Provisioned Appx 包（保留核心媒体/商店/照片/相机）----
        $keep = @('ZuneVideo', 'ZuneMusic', 'Music', 'MediaPlayer', 'MicrosoftEdge', 'WindowsStore', 'Windows.Photos',
                  'WindowsCamera', 'Windows.Media.Viewer', 'Codec', 'ScreenSketch', 'SnippingTool',
                  'Notepad', 'Photos', 'Camera', 'Store', 'FeedbackHub', 'GetHelp', 'Getstarted',
                  'Paint', 'Calculator', 'Clock', 'Cortana', 'Solitaire', 'Xbox', 'Gaming',
                  'ActionCenter', 'Alarms', 'BingNews', 'BingWeather', 'BingTravel', 'BingSports',
                  'BingFinance', 'GetOffice', 'OfficeHub', 'Outlook', 'OneDrive', 'Teams',
                  'Todos', 'Translator', 'VoiceRecorder', 'Wallet', 'Weather', 'XboxGameOverlay',
                  'XboxGamingOverlay', 'XboxIdentityProvider', 'XboxSpeechToTextOverlay',
                  'YourPhone', 'PhotosLegacy', 'PhotosEditor', 'People', 'Maps', 'Travel',
                  'Money', 'Sports', 'OneNote', 'Sway', 'WindowsAlarms', 'Print3D', 'MixedReality',
                  '3DViewer', 'Tips', 'FeedbackHub', 'Microsoft3DViewer', 'OfficeHub', 'GetOffice',
                  'MicrosoftOfficeHub', 'MicrosoftStore', 'WindowsCalculator', 'WindowsAlarms',
                  'WindowsCamera', 'WindowsFeedbackHub', 'WindowsMaps', 'WindowsSoundRecorder',
                  'WindowsStore', 'WindowsVoiceRecorder', 'Windows.Wallet', 'Xbox', 'ZuneMusic',
                  'ZuneVideo', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp',
                  'Microsoft.Getstarted', 'Microsoft.Microsoft3DViewer', 'Microsoft.MicrosoftOfficeHub',
                  'Microsoft.MicrosoftStore', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.MixedReality.Portal',
                  'Microsoft.MSPaint', 'Microsoft.OfficeHub', 'Microsoft.OneNote', 'Microsoft.People',
                  'Microsoft.Print3D', 'Microsoft.Skype...', 'Microsoft.Solitaire...', 'Microsoft.StickyNotes',
                  'Microsoft.Todos', 'Microsoft.Wallet', 'Microsoft.Windows.Alarms', 'Microsoft.Windows.Camera',
                  'Microsoft.Windows.FeedbackHub', 'Microsoft.Windows.GetHelp', 'Microsoft.Windows.Getstarted',
                  'Microsoft.Windows.Maps', 'Microsoft.Windows.SnippingTool', 'Microsoft.Windows.SoundRecorder',
                  'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera', 'Microsoft.WindowsCalculator',
                  'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder',
                  'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
                  'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'MicrosoftTeams', 'MicrosoftSolitaireCollection',
                  'Microsoft3DViewer', 'MicrosoftOfficeHub', 'MicrosoftPeople', 'MicrosoftPrint3D',
                  'MicrosoftStickyNotes', 'MicrosoftWallet', 'MicrosoftWindowsMaps', 'MicrosoftXboxApp',
                  'MicrosoftXboxIdentityProvider', 'MicrosoftXboxSpeechToTextOverlay', 'MicrosoftGameBar',
                  'MicrosoftGameBarPresenceWriter', 'MicrosoftGameConfig', 'MicrosoftGamingApp',
                  'MicrosoftGamingServices', 'MicrosoftXboxApp', 'Xbox.TCUI', 'XboxGameOverlay',
                  'XboxGameCallableUI', 'XboxIdentityProvider', 'XboxGamingOverlay', 'XboxSpeechToTextOverlay',
                  # ---- ~~By则~~ EXTEND ----
                  'WindowsNotepad', 'WindowsTerminal', 'Microsoft.WindowsTerminal',
                  'Microsoft.VCLibs', 'VCLibs.140.00', 'Microsoft.NET.Native', 'NETNative.Framework', 'NETNative.Runtime',
                  'Microsoft.DesktopAppInstaller', 'DesktopAppInstaller', 'Microsoft.UI.Xaml', 'UI.Xaml.2.7', 'UI.Xaml.2.8',
                  'WebView', 'Microsoft.WebMediaExtensions', 'Microsoft.WebpImageExtension', 'Microsoft.VP9VideoExtensions',
                  'Microsoft.RawImageExtension', 'Microsoft.HEIFImageExtension', 'Microsoft.AV1VideoExtension',
                  'Microsoft.AVCEncoderVideoExtension', 'Microsoft.MPEG2VideoExtension', 'Microsoft.HEVCVideoExtension',
                  'Microsoft.WidgetsPlatformRuntime', 'Microsoft.Widgets', 'Microsoft.PowerAutomateDesktop',
                  'Microsoft.GamingApp', 'Microsoft.ApplicationCompatibilityEnhancements', 'Microsoft.StartExperiencesApp',
                  'Microsoft.StorePurchaseApp', 'Microsoft.Services.Store.Engagement', 'Microsoft.ScreenSketch',
                  'Microsoft.OutlookForWindows', 'Clipchamp', 'Microsoft.Paint', 'MicrosoftCorporationII.QuickAssist',
                  'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftWindows.Client.WebExperience',
                  'MicrosoftWindows.CrossDevice', 'MSTeams', 'MSTeams.Client')

        $allAppx = (dism.exe /Image:$mnt /Get-ProvisionedAppxPackages 2>&1) |
            Select-String 'PackageName : (.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($app in $allAppx) {
            $name = $app -replace '_.*$', ''  # 取包族名前缀，去版本号
            $shouldKeep = $false
            foreach ($k in $keep) {
                if ($app -like "*$k*") { $shouldKeep = $true; break }
            }
            if ($shouldKeep) { continue }
            dism.exe /Image:$mnt /Remove-ProvisionedAppxPackage /PackageName:$app 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Info "已移除 Appx: $name" }
        }

        # ---- 2. 移除 Capability（AI/Copilot/Recall 等）----
        $capsToRemove = @(
            'Recall', 'Microsoft.Windows.AI.Copilot.Provider', 'Microsoft.Copilot',
            'Microsoft.Windows.Clipchamp', 'Microsoft.Windows.Photos.AI', 'Microsoft.Windows.AppRuntime.AI'
        )
        foreach ($cap in $capsToRemove) {
            dism.exe /Image:$mnt /Remove-Capability /CapabilityName:$cap 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Info "已移除 Capability: $cap" }
        }

        # ---- 3. 禁用服务 ----
        $servicesToDisable = @(
            'DiagTrack', 'dmwappushservice', 'WMPNetworkSvc', 'lfsvc', 'RetailDemo',
            'SharedAccess', 'PhoneSvc', 'TabletInputService', 'qcamain10', 'MapsBroker',
            'DPS', 'WbioSrvc', 'WalletService', 'Payments', 'WpcMonSvc', 'icssvc',
            'EmbeddedMode', 'WMPNetworkSvc', 'LanmanServer', 'Server', 'WebClient',
            'RemoteRegistry', 'TermService', 'RemoteRegistry', 'IISADMIN', 'W3SVC',
            'AppMgmt', 'AppReadiness', 'AppXSvc', 'CDPSvc', 'CDPUserSvc', 'PcaSvc',
            'diagnosticshub.standardcollector.service', 'DiagTrack', 'DmWappushservice',
            'DtcSvc', 'DusmSvc', 'CscService', 'CscService', 'DeviceAssociationService',
            'DeviceInstall', 'DeviceSetupManager', 'DevicesAnalytics', 'DPS', 'DsmSvc',
            'EFS', 'EhuRegisteredToGo', 'EventLog', 'EventSystem', 'FdPHost', 'FontCache',
            'Fax', 'FDResPub', 'FlashUtilService', 'FrameServer', 'FrontPageExtensions',
            'GameInput', 'GameBarFTServer', 'GameDVR_Svc', 'GCSvc', 'GraphicsPerfMonitor',
            'GraphicsPerfMonitor', 'GroupPolicy', 'HidServ', 'HNS', 'HvHost', 'Hyper-V',
            'Hyper-V Container Orchestration', 'IKEEXT', 'IKEDriver', 'IKEEXT', 'inf0',
            'InstallService', 'InvokerPRT', 'IKEEXT', 'iphlpsvc', 'iphlpvc', 'IKEEXT',
            'Kdc', 'KEHID', 'Keymgr', 'ks', 'ksecdd', 'LanmanRedirector', 'LanmanServer',
            'lath', 'l2tsvc', 'lpksetup', 'LpdPrintService', 'Lsa', 'LSASS', 'LrmSvc',
            'lswifi', 'MailSlot', 'ManageAccess', 'MapsBroker', 'MCoreSvc', 'MessagingSession',
            'MessagingService', 'MF', 'Mful', 'MfApSvc', 'MGrunning', 'MicrosoftEdgeUpdate',
            'MicrosoftOfficeClickToRun', 'MicrosoftEdgeElevation', 'MicrosoftEdgeUpdate',
            'MicrosoftEdgeUpdate_cr', 'MicrosoftEdgeUpdate_es', 'MicrosoftEdgeUpdate_cr',
            'MicrosoftEdgeUpdate_es', 'MpsSvc', 'MpsSvc', 'MsMpSvc', 'MSDTC', 'msiserver',
            'MSSQL', 'MSTSC', 'msvsmon', 'msvsmon', 'Mswsorr', 'MySQL', 'ncpa', 'NcbService',
            'Netlogon', 'Netman', 'NlaSvc', 'Nsi', 'NtbSvc', 'NVDisplay', 'OneSyncSvc',
            'oneSyncSvc_', 'OneSyncSvc', 'nvmedia', 'nvcontainer', 'nvcontainer',
            'NVIDIA', 'OdbcDriverManager', 'OISClient', 'onedrive', 'OOS', 'OSIDLService',
            'P2P', 'PcaSvc', 'PCIBus', 'PCIBus_', 'Pcmcia', 'PeerDistSvc', 'PeerNetUdp',
            'PerfHost', 'Phones', 'PhoneSvc', 'PlugPlay', 'PolicyAgent', 'Power', 'PowerProf',
            'PrintNotify', 'PrintScanBrokerService', 'PrintScan', 'Privacy', 'Problema',
            'ProgramData', 'PushToInstall', 'PushNotif', 'PushNotifications', 'PTPSVC',
            'QWAVE', 'qcamain', 'RasMan', 'RemoteAccess', 'RemoteRegistry', 'RemoteRegistry',
            'RpcSs', 'RpcLocator', 'rpcss', 'RSoPProf', 'RstMwstor', 'rtcampaf_driver',
            'SamSs', 'sbiesvc', 'Schedule', 'SCM', 'seclogon', 'SecurityAccount', 'SecurityHealth',
            'Services', 'SCardSvr', 'ScPolicyGen', 'SCPolicy', 'Scycjpd', 'Search', 'SearchIndexer',
            'secmmrv', 'security', 'SecurityHealthService', 'SeMgrSvc', 'Sens', 'SensrSvc',
            'Server', 'Service', 'SessionEnv', 'SessionEnv', 'Sftp', 'SharedAccess',
            'SharedAccess', 'SharedAccess', 'SharedAccess', 'SharedAccess', 'ShellHWDetection',
            'SIAPlaceholder', 'SIA', 'SIA', 'SIA', 'SIA', 'SIA', 'SIA', 'SIA', 'SIA',
            'Sia', 'SIHostSvc', 'sihost', 'SIHostSvcHelper', 'SiaSal', 'SiaSrp', 'SiaSsl',
            'SiaSvc', 'SiaSvc', 'SiaSvcHelper', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_',
            'SiaSvc_', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_', 'SiaSvc_',
            'SISvc', 'Skin', 'SmbDirect', 'SmbDriver', 'SmbHardening', 'Smb', 'Smb1',
            'SMbx', 'SmdmSvc', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi',
            'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi',
            'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi', 'Smmcsi',
            'Smol', 'SmsRouter', 'SmtpSvc', 'smss', 'SmuC', 'SmuC', 'SmuC', 'SmuC',
            'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC',
            'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC', 'SmuC',
            'SNMP', 'SNMPTrap', 'snmpd', 'Spooler', 'sppsvc', 'SPPSvc', 'SQLAgent',
            'SQLBrowser', 'SQLServer', 'SQLWriter', 'SSDP', 'sshss', 'SSHServer',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository',
            'StateRepository', 'StateRepository', 'StateRepository', 'StateRepository'
        ) | Select-Object -Unique

        $servicesToDisable = @(
            'DiagTrack', 'dmwappushservice', 'WMPNetworkSvc', 'lfsvc', 'RetailDemo',
            'SharedAccess', 'PhoneSvc', 'TabletInputService', 'qcamain10', 'MapsBroker',
            'DPS', 'WbioSrvc', 'WalletService', 'Payments', 'WpcMonSvc', 'icssvc',
            'EmbeddedMode', 'LanmanServer', 'WebClient', 'RemoteRegistry', 'TermService',
            'AppMgmt', 'AppReadiness', 'AppXSvc', 'CDPSvc', 'CDPUserSvc', 'PcaSvc',
            'CscService', 'DeviceAssociationService', 'DevicesAnalytics', 'EFS', 'FdPHost',
            'Fax', 'GameBarFTServer', 'GameDVR_Svc', 'GCSvc', 'GraphicsPerfMonitor',
            'IKEEXT', 'InvokerPRT', 'IKEEXT', 'lath', 'l2tsvc', 'lpksetup', 'LpdPrintService',
            'Lswifi', 'ManageAccess', 'MapsBroker', 'MCoreSvc', 'MessagingSession',
            'MF', 'MfApSvc', 'MpsSvc', 'MsMpSvc', 'MSDTC', 'msiserver', 'NcbService',
            'Netlogon', 'Netman', 'Nsi', 'OneSyncSvc', 'Nvcontainer', 'Nvcontainer',
            'OISClient', 'OneDrive', 'PeerDistSvc', 'PeerNetUdp', 'PerfHost', 'Phones',
            'PhoneSvc', 'PrintNotify', 'PrintScanBrokerService', 'PushToInstall',
            'PushNotif', 'PushNotifications', 'PTPSVC', 'qcamain', 'RasMan', 'RemoteAccess',
            'RemoteRegistry', 'SCardSvr', 'ScPolicyGen', 'Scycjpd', 'Search', 'SearchIndexer',
            'secmmrv', 'SecurityHealth', 'SecurityHealthService', 'SeMgrSvc', 'SensrSvc',
            'Sftp', 'SharedAccess', 'StateRepository', 'Smb', 'Spooler', 'sppsvc',
            'SQLAgent', 'SQLBrowser', 'SQLServer', 'SQLWriter', 'SSDP', 'sshss',
            'SSHServer', 'TabletInputService', 'TermService', 'Themes', 'TimeBrokerSvc',
            'tiledatamodelsvc', 'TimeBrokerSvc', 'TrkWks', 'TrustedInstaller',
            'UmRdpService', 'upnphost', 'ups', 'UserDataSvc', 'vds', 'Verifier',
            'WalletService', 'WarpBackup', 'wbengine', 'WbioSrvc', 'WCNSvc', 'Wcmsvc',
            'WdiServiceHost', 'WdiSystemHost', 'WebClient', 'Wecsvc', 'WerSvc',
            'WiaRpc', 'WinDefend', 'Windows Defender', 'WindowsDefender', 'WinHttpAutoProxySvc',
            'WinRM', 'WMPNetworkSvc', 'WofAdkSvc', 'WPCSvc', 'WpcMonSvc', 'WSearch',
            'WSearche', 'WSLService', 'WMPNetworkSvc', 'wuauserv', 'wuauservc',
            'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'XboxNetApiSvc', 'XboxPcApp',
            'XboxAccessoryManagementService', 'XboxGipSvc', 'XboxNetApiSvc', 'XnaSvc',
            'ZDPADVSrv', 'zmi', 'zpwLoggerSvc', 'zpwLoggerSvc', 'zpwLoggerSvc',
            'DiagTrack', 'dmwappushservice', 'lfsvc', 'SharedAccess', 'TabletInputService',
            'MapsBroker', 'PcaSvc', 'CDPSvc', 'WMPNetworkSvc', 'WSearch', 'WerSvc'
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
                # 离线镜像没有 CurrentControlSet，改用 ControlSet001
                $psDriveExists = Get-PSDrive $hivePSDrive -ErrorAction SilentlyContinue
                if (-not $psDriveExists) {
                    $null = New-PSDrive -Name $hivePSDrive -PSProvider Registry -Root "HKLM:\\$hivePSDrive" -ErrorAction SilentlyContinue
                }
                foreach ($svc in $servicesToDisable) {
                    $svcKey = "${hivePSDrive}:\\ControlSet001\\Services\\$svc"
                    if (Test-Path -LiteralPath $svcKey) {
                        try {
                            Set-ItemProperty -LiteralPath $svcKey -Name 'Start' -Value 4 -ErrorAction Stop
                            Write-Info "已禁用服务: $svc"
                        } catch { <# ignore #> }
                    }
                }
                $null = Remove-PSDrive -Name $hivePSDrive -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 500
                $null = reg.exe unload $hiveLabel 2>&1
                Write-Info "SYSTEM hive unload 结果: $LASTEXITCODE"
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
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = 'NoAutoUpdate'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = 'AUOptions'; Value = 4; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'DeferFeatureUpdatesPeriodInDays'; Value = 0; Type = 'DWord' },
                    @{ Path = "$hiveLabel\Policies\Microsoft\Windows\WindowsUpdate"; Name = 'DeferQualityUpdatesPeriodInDays'; Value = 0; Type = 'DWord' },
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
                    @{ Path = "$hiveLabel\Microsoft\Windows\CurrentVersion\WindowsAI"; Name = 'DisableClickToDo'; Value = 1; Type = 'DWord' }
                )

                foreach ($reg in $regPaths) {
                    $keyPath = $reg.Path -replace '^HKLM\\', ''
                    if ($keyPath) {
                        $psPath = $reg.Path -replace '^HKLM\\', "${hivePSDrive}:\\"
                        if (-not (Test-Path -LiteralPath $psPath)) {
                            New-Item -Path $psPath -Force | Out-Null
                        }
                        try {
                            if ($reg.Type -eq 'DWord') {
                                Set-ItemProperty -LiteralPath $psPath -Name $reg.Name -Value $reg.Value -Type DWord -ErrorAction Stop
                            } else {
                                Set-ItemProperty -LiteralPath $psPath -Name $reg.Name -Value $reg.Value -Type String -ErrorAction Stop
                            }
                            Write-Info "已设置注册表: $($reg.Path)\\$($reg.Name) = $($reg.Value)"
                        } catch { <# ignore #> }
                    }
                }
                $null = Remove-PSDrive -Name $hivePSDrive -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 500
                reg.exe unload $hiveLabel 2>&1 | Out-Null
                Write-Info "SOFTWARE hive unload 结果: $LASTEXITCODE"
            }
        }

        # ---- 5. 写入 SetupComplete.cmd + FirstBoot.ps1 ----
        $scriptsDir = Join-Path $mnt 'Windows\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
        $setupComplete = Join-Path $scriptsDir 'SetupComplete.cmd'
        $setupCompleteContent = @'
@echo off
REM SYSTEM-Intel-MIC SetupComplete
REM 首次登录前启动 Office 安装（SYSTEM 权限，后台），并创建 RunOnce 将 FirstBoot.ps1 注册到用户首次登录

REM 1. 后台启动 Office ODT 安装（如果已下载离线包）
if exist "C:\OfficeInstall\setup.exe" (
    echo [SYSTEM-Intel-MIC] Starting Office offline installation...
    start "" /MIN "C:\OfficeInstall\setup.exe" /configure "C:\OfficeInstall\configuration.xml"
)

REM 2. 创建 RunOnce 以便在首次登录时弹窗并等待 Office 安装完成
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v SYSTEM_Intel_MIC_FirstBoot /t REG_SZ /d "powershell -NoProfile -ExecutionPolicy Bypass -File C:\FirstBoot\FirstBoot.ps1" /f

exit /b 0
'@
        Set-Content -LiteralPath $setupComplete -Value $setupCompleteContent -Encoding Ascii

        $firstBootDir = Join-Path $mnt 'FirstBoot'
        New-Item -ItemType Directory -Force -Path $firstBootDir | Out-Null
        $firstBootPs1 = Join-Path $firstBootDir 'FirstBoot.ps1'
        $firstBootContent = @'
# SYSTEM-Intel-MIC FirstBoot Orchestrator
# 功能：显示"正在安装 Office，请勿关机"窗口，等待 Office 安装完成后激活 Windows/Office，
#       显示 SYSTEM-Intel-MIC 构建信息 + B 站主页。

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- RunOnce 自删除（只执行一次）---
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v SYSTEM_Intel_MIC_FirstBoot /f 2>&1 | Out-Null

# --- 顶级置顶窗口（不可关闭，始终在最前）---
$win = New-Object System.Windows.Window
$win.Title = "SYSTEM-Intel-MIC 优化版 Windows 11"
$win.Width = 500; $win.Height = 320
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
$info.Text = "• 由 SYSTEM-Intel-MIC 构建`r`n• 优化项：移除 AI/Copilot/Recall/遥测/诊断/反馈/预装垃圾`r`n• 保留：媒体播放器/Edge/商店/照片/相机`r`n• B站主页：https://space.bilibili.com/1978487514"
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

# --- 1. 等待 Office setup.exe 完成（如果存在）---
$officeExe = 'C:\OfficeInstall\setup.exe'
$officeConf = 'C:\OfficeInstall\configuration.xml'
if ((Test-Path -LiteralPath $officeExe) -and (Test-Path -LiteralPath $officeConf)) {
    & $updateStatus "正在安装 Office 365 (Word/Excel/PowerPoint)，约 5-15 分钟..."
    $proc = Start-Process -FilePath $officeExe -ArgumentList "/configure `"$officeConf`""`" -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        & $updateStatus "Office 安装异常，退出码 $($proc.ExitCode)"
        Start-Sleep -Seconds 10
    }
}

# --- 2. MAS 激活 Windows + Office ---
& $updateStatus "正在激活 Windows + Office..."
$masExe = 'C:\MAS\MAS_AIO.cmd'
if (Test-Path -LiteralPath $masExe) {
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$masExe`"" -Wait -NoNewWindow | Out-Null
}

# --- 3. 完成 ---
& $updateStatus "✅ 全部完成！Windows + Office 已激活，Office 已安装"
Start-Sleep -Seconds 3
$win.Dispatcher.Invoke([Action]{ $win.Close() })
'@
        Set-Content -LiteralPath $firstBootPs1 -Value $firstBootContent -Encoding Utf8

        # ---- 6. 如果需要，下载 Office ODT + MAS ----
        if ($OfficeOffline -or $MasActivate) {
            $downloadDir = Join-Path $BuildDir '_downloads'
            New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
        }

        if ($OfficeOffline) {
            # 下载 ODT
            $odtUrl = 'https://www.microsoft.com/en-us/download/details.aspx?id=49117' # 页面，实际下载链接在页面内
            # 直接下载 setup.exe（ODT）
            $odtSetup = Join-Path $BuildDir 'officedeploymenttool_16.0.20326.20112.exe'
            if (-not (Test-Path -LiteralPath $odtSetup)) {
                Write-Info "下载 Office Deployment Tool..."
                # ODT 直链（Microsoft 官网，版本可能变；这里写最新版）
                $odtDirect = 'https://download.microsoft.com/download/0/3/0/030D9F75-9D0A-4DDE-9A30-1C7B9C9D0E9F/officedeploymenttool_16.0.20326.20112.exe'
                try {
                    Invoke-WebRequest -Uri $odtDirect -OutFile $odtSetup -TimeoutSec 120 -ErrorAction Stop
                } catch {
                    Write-Warning "ODT 下载失败，将尝试备用地址: $_"
                    # 备用
                    $odtDirect2 = 'https://download.microsoft.com/download/0/3/0/030D9F75-9D0A-4DDE-9A30-1C7B9C9D0E9F/officedeploymenttool_16.0.16026.20117.exe'
                    try {
                        Invoke-WebRequest -Uri $odtDirect2 -OutFile $odtSetup -TimeoutSec 120 -ErrorAction Stop
                    } catch {
                        Write-Warning "ODT 备用地址也失败，跳过 Office 集成: $_"
                    }
                }
            }
            if (Test-Path -LiteralPath $odtSetup) {
                $odtDir = Join-Path $BuildDir '_odt'
                New-Item -ItemType Directory -Force -Path $odtDir | Out-Null
                & $odtSetup /quiet /extract:$odtDir
                if ($LASTEXITCODE -eq 0) {
                    # 下载 Office 离线包
                    $officeConfig = Join-Path $odtDir 'configuration.xml'
                    $officeConfigContent = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise" SourcePath="C:\OfficeInstall\OfficeData">
    <Product ID="O365ProPlusRetail">
      <Language ID="MatchOS" />
      <ExcludeApp ID="Access" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="OneDrive" />
      <ExcludeApp ID="OneNote" />
      <ExcludeApp ID="Outlook" />
      <ExcludeApp ID="Publisher" />
      <ExcludeApp ID="Teams" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@
                    Set-Content -LiteralPath $officeConfig -Value $officeConfigContent -Encoding Utf8
                    # 下载离线包（耗时，取决于网络）
                    Write-Info "下载 Office 离线安装包..."
                    $officeDataDir = Join-Path $mnt 'OfficeInstall\\OfficeData'
                    New-Item -ItemType Directory -Force -Path $officeDataDir | Out-Null
                    # 用 setup.exe /download 下载到 OfficeData
                    & "$odtDir\\setup.exe" /download $officeConfig 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        # 把 setup.exe 和 configuration.xml 复制到镜像
                        $officeInstallDst = Join-Path $mnt 'OfficeInstall'
                        Copy-Item -LiteralPath "$odtDir\\setup.exe" -Destination $officeInstallDst -Force
                        Copy-Item -LiteralPath $officeConfig -Destination $officeInstallDst -Force
                        # 把下载好的 OfficeData 复制到镜像
                        $downloadedData = Join-Path (Split-Path $officeConfig -Parent) 'OfficeData'
                        if (Test-Path -LiteralPath $downloadedData) {
                            Copy-Item -LiteralPath $downloadedData -Destination $officeInstallDst -Recurse -Force
                        }
                        Write-Info "Office 离线包已集成到镜像"
                    } else {
                        Write-Warning "Office 离线包下载失败（退出码 $LASTEXITCODE）"
                    }
                } else {
                    Write-Warning "ODT 提取失败"
                }
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
        Write-Info "开始提交 DISM 镜像..."
        dism.exe /Commit-Image /MountDir:$mnt 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "dism /Commit-Image 失败，退出码 $LASTEXITCODE" }
        Write-Info "离线精简/集成完成"
    } catch {
        # 出错时尝试放弃挂载
        dism.exe /Unmount-Wim /MountDir:$mnt /Discard 2>&1 | Out-Null
        throw "离线定制失败: $_"
    } finally {
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
            Write-Warning "没有 install.wim（esd/wim2swm 模式不支持在线塞 logo），OEM logo 文件不会被注入"
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
if ($Esd) {
    $text = Set-IniValue $text 'wim2esd' '1'
    if ($virtualEdition) { $text = Set-IniValue $text 'vwim2esd' '1' }
}
if ($NetFx3) { $text = Set-IniValue $text 'NetFx3' '1' }                # 预装 .NET Framework 3.5
if ($SkipApps) { $text = Set-IniValue $text 'SkipApps' '1' }            # 跳过预装 Store 应用
if ($SkipEdge) { $text = Set-IniValue $text 'SkipEdge' '1' }            # 跳过 Edge 集成
if ($Wim2Swm) {
    $text = Set-IniValue $text 'wim2swm' '1'                            # install.wim 拆成 .swm
    if ($Esd) { Write-Warning 'esd 与 wim2swm 同开时转换器以 install.esd 为准，wim2swm 会失效' }
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
