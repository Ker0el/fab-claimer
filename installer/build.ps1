<#
  Fab 限时免费领取助手 —— 打包成 Windows 安装程序

  用法：
    powershell -ExecutionPolicy Bypass -File installer\build.ps1
    powershell -ExecutionPolicy Bypass -File installer\build.ps1 -NoCompile   # 只挑文件不编译，排查用

  ★ 为什么要"先挑一遍再打包"，而不是让 Inno 直接扫整个文件夹
  profile\（216MB）里是**真实的 Epic 登录凭据**，logs\ 里有用户名和本机路径。
  在 .iss 里写 Excludes 当然也能排除，但那属于"我以为排掉了"：排除规则写错一个字
  不会报错，只会安静地把登录态打进安装包发出去 —— 而那是撤不回来的。
  所以这里改成白名单复制：挑出来的东西可以一眼看全，第 3 步还会自己数一遍、
  把清单打出来，确认干净了才交给 ISCC。
#>
[CmdletBinding()]
param(
    [switch]$NoCompile,
    [string]$Iscc = ''          # ISCC.exe 路径；不传就自己去注册表找
)

$ErrorActionPreference = 'Stop'

$Installer = $PSScriptRoot
$Root      = (Get-Item (Join-Path $Installer '..')).FullName
$Stage     = Join-Path $Installer '_stage'

function Say([string]$m) { Write-Host $m }

# ---------- 1. 版本号（从 version.json 读，不另立一份）----------
$VerFile = Join-Path $Root 'version.json'
if (-not (Test-Path -LiteralPath $VerFile)) { throw "找不到 version.json：$VerFile" }
$VerJson = [System.IO.File]::ReadAllText($VerFile).TrimStart([char]0xFEFF) | ConvertFrom-Json
$Version = [string]$VerJson.version
if (-not $Version) { throw 'version.json 里没有 version 字段' }
Say "版本：$Version"

# ---------- 2. 准备暂存目录 ----------
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
[void](New-Item -ItemType Directory -Path $Stage -Force)

# 根目录要发的文件：**白名单**，一个个点名。
# 不写成"除了这些之外全都发" —— 黑名单会随着文件夹里多出东西而悄悄失效
# （本机就躺着一个「Fab领取助手.exe - 快捷方式.lnk」，那种东西不该进安装包）。
$rootFiles = @(
    'Fab领取助手.exe',
    '使用说明.txt',
    'README.md',
    'LICENSE',
    'THIRD-PARTY-NOTICES.md',
    'version.json'
)
foreach ($f in $rootFiles) {
    $src = Join-Path $Root $f
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "缺文件：$f" }
    Copy-Item -LiteralPath $src -Destination $Stage -Force
}

# core\ 整个搬，但**点名排除**运行期状态（用户指定的浏览器/端口）。
# 这两个是用户机器上长出来的，发出去会覆盖掉别人自己的设置。
$coreExclude = @('settings.json', 'cdp-port.txt')
$coreSrc = Join-Path $Root 'core'
$coreDst = Join-Path $Stage 'core'
[void](New-Item -ItemType Directory -Path $coreDst -Force)
Get-ChildItem -LiteralPath $coreSrc -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($coreSrc.Length).TrimStart('\', '/')
    if ($coreExclude -contains $_.Name) { return }
    $dst = Join-Path $coreDst $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
}

# ---------- 3. 自己数一遍：暂存目录里到底有什么 ----------
# 这一步是给眼睛看的，不是给机器看的。.iss 里还有一道编译期硬闸做兜底。
$mustNotExist = @(
    'profile', 'logs', '.git',
    'claimed.json', 'next-check.json',
    'core\settings.json', 'core\cdp-port.txt'
)
foreach ($p in $mustNotExist) {
    if (Test-Path -LiteralPath (Join-Path $Stage $p)) {
        throw "暂存目录里出现了不该有的东西：$p —— 停下，别打包"
    }
}
# 浏览器凭据文件只可能出现在 profile\ 里。真出现了就是白名单漏了，直接失败。
$credNames = @('Cookies', 'Login Data', 'Web Data', 'Login Data-journal', 'Local State')
$creds = Get-ChildItem -LiteralPath $Stage -Recurse -File -Force -ErrorAction SilentlyContinue |
         Where-Object { $credNames -contains $_.Name }
if ($creds) {
    throw ("暂存目录里发现浏览器凭据文件（{0}）—— 停下，别打包" -f (($creds | ForEach-Object { $_.FullName }) -join '; '))
}
if (-not (Test-Path -LiteralPath (Join-Path $Stage 'version.json'))) { throw '暂存目录里没有 version.json' }

$all = Get-ChildItem -LiteralPath $Stage -Recurse -File -Force
$sizeMb = [Math]::Round((($all | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Say ("暂存目录干净：{0} 个文件，{1} MB" -f $all.Count, $sizeMb)
Say '  根目录：'
Get-ChildItem -LiteralPath $Stage -File | ForEach-Object { Say ("    {0}  ({1} KB)" -f $_.Name, [Math]::Round($_.Length / 1KB)) }
Say '  core\ 顶层：'
Get-ChildItem -LiteralPath (Join-Path $Stage 'core') | ForEach-Object {
    if ($_.PSIsContainer) { Say ("    {0}\  (目录)" -f $_.Name) } else { Say ("    {0}  ({1} KB)" -f $_.Name, [Math]::Round($_.Length / 1KB)) }
}

if ($NoCompile) { Say ''; Say '-NoCompile：到此为止，没有编译。'; exit 0 }

# ---------- 4. 编译 ----------
if (-not $Iscc) {
    # 按注册表卸载项找（这台机器 Program Files 在 D 盘，猜 C:\ 会误判成"没装"）
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $loc = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like '*Inno Setup*' } |
           Select-Object -First 1 -ExpandProperty InstallLocation
    if ($loc) { $Iscc = Join-Path $loc 'ISCC.exe' }
}
if (-not $Iscc -or -not (Test-Path -LiteralPath $Iscc)) {
    throw '找不到 ISCC.exe。装一个 Inno Setup，或用 -Iscc "路径\ISCC.exe" 指定。'
}
Say ''
Say "用：$Iscc"

$iss = Join-Path $Installer 'fab-claimer.iss'
& $Iscc "/DAppVersion=$Version" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败，退出码 $LASTEXITCODE" }

$out = Join-Path $Installer 'Output'
$setup = Get-ChildItem -LiteralPath $out -Filter '*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Say ''
Say ("✅ 安装包：{0}" -f $setup.FullName)
Say ("   {0} MB" -f [Math]::Round($setup.Length / 1MB, 1))
