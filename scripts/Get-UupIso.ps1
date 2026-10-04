#!/usr/bin/env pwsh
<#
.SYNOPSIS
    从 UUP dump 构建 Windows ISO（全流程在 GitHub Actions 里跑，本地不下载任何 UUP 文件）。

.DESCRIPTION
    1. 调 UUP dump API 按「构建号 + 通道 + 架构」找到目标构建（默认 26220 / insider / amd64）
    2. 从 UUP dump 下载“下载包”（ConvertConfig.ini + uup_download_windows.cmd）
    3. 按参数改写 ConvertConfig.ini（累积更新 / ESD / 预装 .NET3.5 / 跳过应用 / 跳过 Edge /
       WIM 分卷 / 注入驱动 / 虚拟版本=企业版）
    4. 运行 uup_download_windows.cmd：aria2 从 Windows Update 服务器拉 UUP 文件，
       再用 uup-converter-wimlib 挂载、打补丁、导出并生成 ISO

    参考实现：ylx2016/uup-dump-build-and-get-windows-iso
#>

[CmdletBinding()]
param(
    # 目标版本：pro=专业版（首跑默认）/ enterprise=仅企业版 / enterprise_pro=专业版+企业版 / multi=家庭版+专业版
    [ValidateSet('enterprise', 'enterprise_pro', 'pro', 'multi')]
    [string] $Edition = 'pro',

    # 输出目录（Windows runner 的 D: 盘空间最大）
    [string] $Destination = 'd:/output',

    # 构建号：26220 = Windows 11 Dev 通道；也可填精确版本 26220.9587
    [string] $Build = '26220',

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
    [switch] $Wim2Swm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ApiBase = 'https://api.uupdump.net'
$WebBase = 'https://uupdump.net'

# 支持三种写法：26220（取该构建最新修订）/ 26220.9587（精确版本）/ 自由搜索词
$major = $null
if ($Build -match '^(\d+)(\.\d+)?$') { $major = ($Build -split '\.')[0] }
$Search = if ($major) { "windows 11 $major $Arch" } else { $Build }

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
#   insider -> "Windows 11 Insider Preview Feature Update (26220.9587)" 这类预览版
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
    $repoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
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
# 5. 校验产物
# ---------------------------------------------------------------------------
$isoFile = Get-ChildItem -LiteralPath $buildDirectory -Filter '*.iso' -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending | Select-Object -First 1

if (-not $isoFile) {
    Write-Host "::error::没有生成 ISO，以下是构建日志的最后 200 行"
    Get-Content -LiteralPath $rawLog -Tail 200 -ErrorAction SilentlyContinue | Write-Host
    throw "uup_download_windows.cmd 未能生成 ISO，详见 $rawLog"
}

Write-Info "ISO 生成成功: $($isoFile.Name) ($([math]::Round($isoFile.Length / 1GB, 2)) GB)"
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
