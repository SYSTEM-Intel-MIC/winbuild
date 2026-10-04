# winbuild — GitHub Actions 构建 Windows 11 ISO

在 **GitHub Actions 云端**用 [UUP dump](https://uupdump.net) 下载 UUP 更新包并转换成可启动 ISO，
本地不下载任何 UUP 文件，构建完成后**分卷（≤2GB）发布到 GitHub Release**。

- 默认：**build `26220`（Dev 通道）/ x64 / 简体中文 / 专业版**
- 构建号**可手动输入**（`26220` 取最新修订，或精确到 `26220.9587`），并有 `insider` / `stable` 通道下拉
- 触发：手动 `workflow_dispatch`，全部参数在网页上填
- 参考：[ylx2016/uup-dump-build-and-get-windows-iso](https://github.com/ylx2016/uup-dump-build-and-get-windows-iso)、[yprsoft/UUPdumpWinISO](https://github.com/yprsoft/UUPdumpWinISO)、[adavak/win_iso_build](https://github.com/adavak/win_iso_build/releases)

> ⚠️ UUP dump **没有 LTSC 版本**（LTSC 2024 是 26100）。本流水线做的是
> 专业版 / 企业版 / 家庭版。要 LTSC 参考 adavak 的「官方 ISO + 补丁」路线。

## 目录结构

```
winbuild/
├── .github/workflows/build-win11-iso.yml   # CI：磁盘检查 → 构建 → 分卷 → 发 Release
├── scripts/Get-UupIso.ps1                 # 主脚本：找构建 → 下载包 → 改配置 → 转 ISO
└── Drivers/                               # 可选：要注入镜像的驱动放这里（勾 drivers 开关才生效）
```

## 工作原理

1. 调 UUP dump API（`api.uupdump.net`）按 `windows 11 <构建号> amd64` 搜索，按**通道**过滤标题后取最新：
   - `stable` → `Windows 11, version 26H2 (26300.9550)` 这类正式版
   - `insider` → `Windows 11 Insider Preview Feature Update (26220.9587)` 这类预览版
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
5. 计算 SHA256、读出镜像内的版本列表、写元数据 JSON，清理工作目录
6. `7z -v2000m` 把 ISO 切成 2000MB 分卷（Release 单文件上限 2GB），删掉原始 ISO，`gh release create` 发布

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
| `build` | 文本 | **`26220`** | **构建号，可手填**：`26220` = 该版本最新修订；精确版本填 `26220.9587`。查最新见下节 |
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

架构 `x64`、语言 `zh-CN` 已固定；要改就调 `scripts/Get-UupIso.ps1 -Arch amd64 -Lang zh-cn ...`。

### 怎么查「最新版本号」填进 `build`

1. **最简单**：打开 <https://uupdump.net/>，首页 *Downloads* 列表里找 amd64 那行，括号里的数字就是，
   例如 `Windows 11 Insider Preview Feature Update (26220.9587) amd64` → 填 `26220`（取最新）或 `26220.9587`（精确）
2. **按类别浏览**：<https://uupdump.net/known.php?q=category:w11-26h2>（26H2 正式版）、
   `category:w11-26h2-beta`、`category:w11-26h1` 等，页面上就是所有可用构建
3. **直接搜**：<https://uupdump.net/known.php?q=关键词>，如 `known.php?q=26220`
4. 常见构建号：`26300` = 26H2 正式版、`26220` = Dev 通道、`26340` = 26H2 Beta、`28000` = 26H1

填错不会乱跑：脚本会把搜到的标题列出来并报错，改一下再点就行。

## 产物

Release 标签形如 `Win11_26220-insider_x64_zh-CN_pro_26220.9587_20261003`：

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
  删掉用不到的预装软件，构建成功后立刻删工作目录、分卷后删原始 ISO，峰值占用约 12GB。
- **时长**：下载 + 转换 + 分卷一般 40～90 分钟，作业上限 6 小时。
- **额度**：私有仓库 Windows runner 消耗 2 倍分钟（2000 分钟/月 ≈ 16 次构建）；
  公开仓库免费但代码公开。
- **Dev 通道镜像**是预览版，仅供测试，别当生产机用；想要稳定就 `channel=stable` + `build=26300`。
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
| `找不到 PROFESSIONAL` / 语言包 | 该构建暂未提供 zh-cn 或对应版本，换个构建号 |
| 分卷上传失败 | 确认 workflow 有 `permissions: contents: write`（已内置），token 未过期 |
