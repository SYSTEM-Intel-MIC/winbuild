<#
.SYNOPSIS
    下载 Office Deployment Tool(ODT) 并拉取 Office 365 离线安装包（Word / Excel / PowerPoint）。

.DESCRIPTION
    被两种方式使用：
      1. workflow 在「Build ISO」步骤之前用 Start-Process 后台启动，
         与 UUP dump 的下载/转换**并行**跑，省掉串行等待的十几分钟；
      2. Get-UupIso.ps1 在后台任务没跑成时，作为兜底在本地补跑一次。

    产出（全部落在 -WorkDir 里）：
      setup.exe                    ODT 解出来的安装器
      configuration.xml            安装用配置（SourcePath=C:\OfficeInstall，不含 /Office，
                                   ODT 自己拼 Office\Data\<版本>，见 MS 文档
                                   "The SourcePath value shouldn't include the /Office part
                                    or the name of the folder on which Office Data is downloaded"）
      configuration.download.xml   下载用配置（SourcePath=本目录）
      Office\Data\<版本>\*.dat|*.cab   Office 离线安装数据（ODT 实际布局，约 3.6 GB）
      OFFICE_DL_DONE               成功标记（主脚本轮询它）
      OFFICE_DL_FAIL               失败标记 + 原因（主脚本轮询到就跳过 Office，不拖垮构建）

    注意：早期文档/旧版 ODT 用的是 <SourcePath>\OfficeData\，但 16.0.20326 的 setup.exe
    实际写的是 <SourcePath>\Office\Data\<版本>\（已在 runner 上实测验证）。脚本两种布局都认，
    并统一归一成 Office\Data\，这样镜像内的安装配置 SourcePath=C:\OfficeInstall 永远正确。

    退出码：0 = 成功，1 = 失败。
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $WorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log([string] $Message) {
    Write-Host ("[office-dl {0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

# ODT 官方直链（Microsoft download.microsoft.com，非第三方）
$OdtUrls = @(
    'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20326-20112.exe'
)

# 只要 Word / Excel / PowerPoint：其余 Access/OneDrive/OneNote/Outlook/Publisher/Skype/Teams 全部 ExcludeApp
$ConfigurationTemplate = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise" SourcePath="__SRCPATH__">
    <Product ID="O365ProPlusRetail">
      <!-- 必须写死 zh-cn：MatchOS 是「按运行 setup.exe 的那台机器的 OS 语言」在下载阶段就解析掉，
           GitHub runner 是 en-US，会下成英文包（日志里会出现 stream.x64.en-us.dat / *1033.cab），
           装到 zh-CN 目标机上时 ODT 找不到 zh-cn 流就得联网补下，离线集成就废了。
           本 ISO 就是 zh-CN 版，所以下载和安装都固定 zh-cn。 -->
      <Language ID="zh-cn" />
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
  <Updates Enabled="FALSE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@

$doneMarker = Join-Path $WorkDir 'OFFICE_DL_DONE'
$failMarker = Join-Path $WorkDir 'OFFICE_DL_FAIL'
$startMarker = Join-Path $WorkDir 'OFFICE_DL_START'

try {
    if (Test-Path -LiteralPath $doneMarker) {
        Write-Log "已有完成标记，跳过: $((Get-Content -LiteralPath $doneMarker -Raw).Trim())"
        exit 0
    }
    Remove-Item -LiteralPath $doneMarker, $failMarker -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    # 立刻写一个「已启动」标记：主脚本靠它判断任务到底跑没跑起来
    Set-Content -LiteralPath $startMarker -Encoding Utf8 -Value (
        "启动 {0}  PID={1}`nWorkDir={2}`nPS={3}" -f (Get-Date -Format o), $PID, $WorkDir, $PSHOME)
} catch {
    Write-Log "初始化 WorkDir 失败: $_"
    exit 1
}

function Test-PeFile([string] $Path) {
    # 校验下载到的是真正的 PE（MDZ 头 = "MZ"），防止下到 HTML 错误页
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 2
            [void]$fs.Read($buf, 0, 2)
            return ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A)
        } finally { $fs.Close() }
    } catch { return $false }
}

try {
    # ---- 1. 下载 ODT ----
    $odtExe = Join-Path $WorkDir 'officedeploymenttool_20326-20112.exe'
    if ((Test-Path -LiteralPath $odtExe) -and -not (Test-PeFile $odtExe)) {
        Remove-Item -LiteralPath $odtExe -Force
    }
    if (-not (Test-Path -LiteralPath $odtExe)) {
        $ok = $false
        foreach ($u in $OdtUrls) {
            try {
                Write-Log "下载 ODT: $u"
                Invoke-WebRequest -Uri $u -OutFile $odtExe -TimeoutSec 300 -UseBasicParsing -ErrorAction Stop
                if (Test-PeFile $odtExe) { $ok = $true; break }
                Write-Log '下载到的不是 PE 文件（多半是网页），换下一个地址'
                Remove-Item -LiteralPath $odtExe -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log "ODT 下载失败: $_"
            }
        }
        if (-not $ok) { throw 'ODT 下载失败' }
    }
    Write-Log "ODT 就绪: $([math]::Round((Get-Item -LiteralPath $odtExe).Length / 1MB, 1)) MB"

    # ---- 2. 解压出 setup.exe ----
    $setupExe = Join-Path $WorkDir 'setup.exe'
    if (-not (Test-Path -LiteralPath $setupExe)) {
        Write-Log "解压 ODT 到 $WorkDir"
        $p = Start-Process -FilePath $odtExe -ArgumentList '/quiet', "/extract:$WorkDir" -Wait -PassThru
        Write-Log "ODT 解压退出码 $($p.ExitCode)"
        if (-not (Test-Path -LiteralPath $setupExe)) {
            $found = @(Get-ChildItem -Path $WorkDir -Recurse -Filter 'setup.exe' -File -ErrorAction SilentlyContinue) |
                Select-Object -First 1
            if ($found) {
                Copy-Item -LiteralPath $found.FullName -Destination $setupExe -Force
            }
        }
    }
    if (-not (Test-Path -LiteralPath $setupExe)) {
        $names = (Get-ChildItem -Path $WorkDir -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
        throw "ODT 解压后没找到 setup.exe（目录内容：$names）"
    }
    Write-Log 'setup.exe 就绪'

    # ---- 3. 写两份 configuration.xml ----
    # 下载用：SourcePath 指向本目录，setup /download 会把数据写到 <SourcePath>\Office\Data\<版本>
    $dlConfig = Join-Path $WorkDir 'configuration.download.xml'
    Set-Content -LiteralPath $dlConfig -Value ($ConfigurationTemplate -replace '__SRCPATH__', $WorkDir) -Encoding Utf8
    # 安装用：SourcePath 指向镜像内的 C:\OfficeInstall（不含 \Office、\Office\Data，
    # ODT 会自己拼出 C:\OfficeInstall\Office\Data\<版本>），会被拷进镜像
    $installConfig = Join-Path $WorkDir 'configuration.xml'
    Set-Content -LiteralPath $installConfig -Value ($ConfigurationTemplate -replace '__SRCPATH__', 'C:\OfficeInstall') -Encoding Utf8

    # ---- 4. setup /download 拉离线包 ----
    # 实测布局：<SourcePath>\Office\Data\<版本>；部分旧版本是 <SourcePath>\OfficeData\<版本>
    $dataDir = Join-Path $WorkDir (Join-Path 'Office' 'Data')
    $legacyDataDir = Join-Path $WorkDir 'OfficeData'
    Write-Log '开始下载 Office 离线安装包（约 3.6 GB，视网络 5~30 分钟；已下过的会自动校验续传）...'
    $p = Start-Process -FilePath $setupExe -ArgumentList '/download', "`"$dlConfig`"" -Wait -PassThru
    Write-Log "setup /download 退出码 $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "setup.exe /download 失败，退出码 $($p.ExitCode)" }

    # ---- 5. 布局归一：不管是 Office\Data 还是 OfficeData，最后都统一成 Office\Data ----
    if (-not (Test-Path -LiteralPath $dataDir) -and (Test-Path -LiteralPath $legacyDataDir)) {
        try {
            $pkgRoot = Join-Path $WorkDir 'Office'
            New-Item -ItemType Directory -Force -Path $pkgRoot | Out-Null
            Move-Item -LiteralPath $legacyDataDir -Destination $dataDir -Force
            Write-Log "已把旧布局 OfficeData 归一为 Office\Data"
        } catch {
            Write-Log "布局归一失败（沿用旧布局）: $_"
            $dataDir = $legacyDataDir
        }
    }

    # ---- 6. 校验（不光看文件个数，还看体积，防止半截数据被当成完成）----
    if (-not (Test-Path -LiteralPath $dataDir)) {
        throw "Office 数据目录没有生成（检查了 $dataDir 和 $legacyDataDir）"
    }
    $files = @(Get-ChildItem -Path $dataDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { throw "Office 数据目录 $dataDir 是空的" }
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    $max = ($files | Measure-Object -Property Length -Maximum).Maximum
    if ($sum -lt 1500MB) { throw ("Office 数据只有 {0} MB（< 1500 MB），下载不完整" -f [math]::Round($sum / 1MB, 1)) }
    if ($max -lt 50MB) { throw ("Office 数据最大文件只有 {0} MB，下载不完整" -f [math]::Round($max / 1MB, 1)) }

    Set-Content -LiteralPath $doneMarker -Encoding Utf8 -Value (
        "完成时间 {0}`n数据目录: {1}`n体积: {2} MB / {3} 个文件" -f `
            (Get-Date -Format o), $dataDir, [math]::Round($sum / 1MB, 1), $files.Count
    )
    Write-Log ("完成，{0} {1} MB / {2} 个文件" -f $dataDir, [math]::Round($sum / 1MB, 1), $files.Count)

    # ---- 7. 剔除 arm64 交叉部件（x64 装机用不到，净省 451 MB）----
    # ODT 会顺带下 stream.x64.x-none.arm64x.dat(+.cat)，那是给 ARM64 设备用的。
    # 已在 runner 上做过 A/B 断网实验：CDN 屏蔽到只能回 404 的情况下，删掉这两个文件
    # 再 setup /configure 依然 exit=0、Word/Excel/PowerPoint 三件齐全、130 秒装完（比完整包还快），
    # 说明 ODT 根本不校验也不回退下载，这两个文件纯粹是白占 451 MB。
    $armFiles = @(Get-ChildItem -Path $dataDir -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'arm64' })
    if ($armFiles.Count -gt 0) {
        $armMB = [math]::Round(($armFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
        $armFiles | Remove-Item -Force
        Write-Log "已剔除 arm64 交叉部件 $($armFiles.Count) 个 / $armMB MB（x64 装机用不到，实测断网仍可安装）"
    }
    exit 0
} catch {
    $msg = "$_"
    Write-Log "失败: $msg"
    try {
        Set-Content -LiteralPath $failMarker -Encoding Utf8 -Value $msg
    } catch {
        try {
            Set-Content -LiteralPath (Join-Path $WorkDir 'OFFICE_DL_FAIL.txt') -Encoding Utf8 -Value $msg
        } catch { }
    }
    exit 1
}
