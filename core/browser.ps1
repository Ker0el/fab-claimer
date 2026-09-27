<#
  Fab 领取助手 —— 浏览器定位 / 启动 / 验证（唯一真相源）

  ★ 为什么要有这个文件
  这段逻辑以前在 gui.ps1 和 auto-claim.cmd 里各写了一份：界面那份会找
  Chrome/Edge/Brave/Vivaldi/360/QQ 外加注册表，计划任务那份只硬编码了 5 条
  Chrome/Edge 的路径，而且不读 settings.json。用户在界面上手动指定了 Brave，
  计划任务照样找不到浏览器 —— 失败还只写进 logs\task.log，界面从来不读，
  于是自动领取可以静默失败几个月没人知道。两份名单必然漂移，所以合成一份。

  ★ 判定标准
  以前是"这个路径下有没有 chrome.exe"（猜路径 = 白名单，永远会漏）。
  现在是"这个 exe 启动后能不能开出 Chromium 的 CDP 端口"—— 找 10 个像浏览器的
  文件，不如确认 1 个真能用的。判据是 GET /json/version 有没有 Browser 字段，
  这是 Chromium 系专有的，比 exe 名字可靠得多。

  用法：
    . "$PSScriptRoot\browser.ps1"                    # 点源进 GUI
    powershell -File browser.ps1 -Ensure             # 独立跑，计划任务用
    powershell -File browser.ps1 -List               # 只列出候选，排查用
#>
[CmdletBinding()]
param(
    [switch]$Ensure,       # 独立模式：保证有一个能用的浏览器，打印一行 JSON
    [switch]$List          # 只列出候选，不启动（排查用）
)

# 注意：这里刻意不设 $ErrorActionPreference。
# 本文件会被 gui.ps1 点源进来，顶层改这个变量会连带改掉 GUI 自己的
# 'Stop' 设定，那等于悄悄改了整个界面的报错行为。里面的函数全都自带
# try/catch 和显式 -ErrorAction，不需要靠它。独立运行时在末尾单独设。

# ================= 路径 / 端口 =================

$script:BCore = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:BRoot = (Get-Item (Join-Path $script:BCore '..')).FullName
$script:BProfile = Join-Path $script:BRoot 'profile'
$script:BLogDir = Join-Path $script:BRoot 'logs'
$script:BSettings = Join-Path $script:BCore 'settings.json'
$script:BPortFile = Join-Path $script:BCore 'cdp-port.txt'

# 端口：FAB_CDP 环境变量 > settings.json 里上次定下的 > 9222
function Initialize-BPort {
    $fromEnv = $null
    if ($env:FAB_CDP) { try { $fromEnv = ([uri]$env:FAB_CDP).Port } catch {} }
    if (-not $fromEnv) {
        $s = Read-BSettings
        if ($s['cdpPort']) { try { $fromEnv = [int]$s['cdpPort'] } catch {} }
    }
    if ($fromEnv -and $fromEnv -gt 0) { $script:BPort = [int]$fromEnv } else { $script:BPort = 9222 }
    $script:BPortPinned = [bool]$fromEnv
}

# ================= settings.json（GUI 和本文件共用一份）=================

function Read-BSettings {
    $o = @{}
    if (Test-Path -LiteralPath $script:BSettings) {
        try {
            # PS 5.1 的 ConvertFrom-Json 碰到 BOM 会解析失败，手动去掉
            $t = [System.IO.File]::ReadAllText($script:BSettings).TrimStart([char]0xFEFF)
            $j = $t | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value }
        } catch {}
    }
    return $o
}

function Save-BSettings([hashtable]$Values) {
    try {
        $o = Read-BSettings
        foreach ($k in $Values.Keys) {
            if ($Values[$k] -or $Values[$k] -eq 0) { $o[$k] = $Values[$k] } else { $o.Remove($k) }
        }
        $json = if ($o.Count -gt 0) { $o | ConvertTo-Json -Depth 4 } else { '{}' }
        [System.IO.File]::WriteAllText($script:BSettings, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# ================= CDP 探测：真正的判据 =================

function Get-CdpInfo {
    param([int]$Port = $(if ($script:BPort) { $script:BPort } else { 9222 }))
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/json/version")
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $req.Proxy = $null          # 系统代理会把 127.0.0.1 也劫走，这是真会发生的坑
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return ($txt | ConvertFrom-Json)
    } catch { return $null }
}

# 端口上是不是一个真的 Chromium 浏览器（而不只是"有个东西在监听"）
function Test-CdpBrowser {
    param([int]$Port = $(if ($script:BPort) { $script:BPort } else { 9222 }))
    $i = Get-CdpInfo -Port $Port
    return [bool]($i -and $i.Browser)
}

# 端口上这个浏览器有没有窗口。
# headless 的没有 —— 对这个程序等于没有浏览器：用户得看得见窗口才能登录 Epic、
# 才能过 Cloudflare 的人机验证。判据是 /json/version 的 User-Agent：
# 实测有头 Chrome 是 "Chrome/153.0.0.0"，无头是 "HeadlessChrome/153.0.0.0"。
function Test-CdpHeaded {
    param([int]$Port = $(if ($script:BPort) { $script:BPort } else { 9222 }))
    $i = Get-CdpInfo -Port $Port
    if (-not $i -or -not $i.Browser) { return $false }
    return -not ([string]$i.'User-Agent' -match 'HeadlessChrome')
}

# 上次本程序启动的浏览器进程号（记在 settings.json 的 cdpPid）。
#   有记录、进程还在  → 是我们的
#   有记录、进程没了  → 端口上那个是别人的（我们那个早关了）
#   没记录（全新安装/删过 settings.json）→ 判断不了，按"是"处理，宁可漏判也别误伤
function Test-CdpIsOurs {
    $s = Read-BSettings
    $owner = 0
    try { $owner = [int]$s['cdpPid'] } catch { return $true }
    if ($owner -le 0) { return $true }
    try { $null = Get-Process -Id $owner -ErrorAction Stop; return $true } catch { return $false }
}

<#
  端口上那个浏览器能不能直接拿来用。返回 @{ ok; kind; why }
  kind: 'ok' | 'none'（端口上没浏览器）| 'unusable'（有，但不能用）

  ★ 为什么不能只判 Test-CdpBrowser
  实测踩过：另一个工具在本机开了个 headless Chrome 占着 9222（--headless=new
  --user-data-dir=%TEMP%\cdp-*），本程序"端口上有个 Chromium"就直接接了上去了。
  症状是「没有窗口 + 未登录 + 被 Cloudflare 拦」，三条全都没指向真正的原因，
  排查了很久。headless 天生干不了这件事（没窗口，用户没法登录也没法过验证），
  别人的浏览器也不该抢 —— 另一头可能是别人的自动化任务，抢过来两边都坏。
#>
function Test-CdpReusable {
    param([int]$Port = $(if ($script:BPort) { $script:BPort } else { 9222 }))
    if (-not (Test-CdpBrowser -Port $Port)) { return @{ ok = $false; kind = 'none'; why = $null } }
    if (-not (Test-CdpHeaded -Port $Port)) {
        return @{ ok = $false; kind = 'unusable'; why = '是个没有窗口的 headless 浏览器' }
    }
    if (-not (Test-CdpIsOurs)) {
        return @{ ok = $false; kind = 'unusable'; why = '不是本程序启动的（上次那个已经关了）' }
    }
    return @{ ok = $true; kind = 'ok'; why = $null }
}

function Test-PortOpen {
    param([int]$Port)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(600, $false)) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

# 端口被别的程序占着时换个能用的。Chromium 自己会"静默地不开调试端口"继续跑，
# 表现成"浏览器起不来"，其实是被占。这是以前最容易误诊的一种。
function Resolve-FreePort {
    param([int]$Start = 9222, [int]$Tries = 10)
    for ($p = $Start; $p -lt ($Start + $Tries); $p++) {
        if (Test-CdpBrowser -Port $p) { return @{ Port = $p; Reuse = $true } }
        if (-not (Test-PortOpen -Port $p)) { return @{ Port = $p; Reuse = $false } }
    }
    return @{ Port = $Start; Reuse = $false }
}

# ================= 候选收集 =================

function Add-Candidate($List, $Seen, [string]$ExePath, [string]$Source) {
    $p = Clean-Path $ExePath
    if (-not $p) { return }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return }
    # 排除明显不是浏览器的：Windows 自带的 explorer/iexplore
    $name = [System.IO.Path]::GetFileName($p)
    if ($name -match '^(explorer|iexplore|iexpress)\.exe$') { return }
    if (-not $Seen.Add($p)) { return }
    [void]$List.Add([pscustomobject]@{ Path = $p; Source = $Source })
}

# 注册表里的路径很脏：DisplayIcon 写成 "C:\...\chrome.exe,0"，InstallLocation
# 可能带引号、带尾反斜杠。不洗干净直接喂 Test-Path 会抛"路径中有非法字符"。
function Clean-Path([string]$Value) {
    if (-not $Value) { return $null }
    $p = $Value.Trim().Trim('"').Trim()
    $p = $p -replace ',\s*-?\d+\s*$', ''      # 去掉图标序号
    $p = $p.Trim().Trim('"').Trim()
    if (-not $p -or $p -match '[\x00-\x1f]') { return $null }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $null }
    return $p
}

# 1) 用户在界面上手动指定的（计划任务也必须认这个，以前就是漏在这）
#    与 lastBrowser 分开两个字段：手动的永远压过自动记住的，否则用户指定的
#    会被下一次自动探测悄悄顶掉，那就是个假设置。
function Get-SettingBrowser {
    $s = Read-BSettings
    $b = [string]$s['browser']
    if ($b -and (Test-Path -LiteralPath $b -PathType Leaf)) { return $b }
    return $null
}

# 2) 上次成功用过的那一个 —— "稳定"的真正来源。
#    探测只在第一次发生，之后永远钉住同一个，不会今天 Chrome 明天 Edge；
#    出了怪问题也只要换这一个变量，不必去猜这次用的是哪个。
function Get-LastBrowser {
    $s = Read-BSettings
    $b = [string]$s['lastBrowser']
    if ($b -and (Test-Path -LiteralPath $b -PathType Leaf)) { return $b }
    return $null
}

# 2) 常见安装位置 + 3) App Paths + 4) PATH —— 主流浏览器，最可靠的一批
function Get-MainstreamBrowsers {
    $pf   = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $lad  = $env:LOCALAPPDATA
    $out = New-Object System.Collections.ArrayList

    # 顺序即优先级：Chrome 最稳，Edge（Windows 自带）次之
    foreach ($b in @(
        @{ n = 'Google\Chrome\Application\chrome.exe';    s = '常见位置/Chrome' },
        @{ n = 'Microsoft\Edge\Application\msedge.exe';   s = '常见位置/Edge' },
        @{ n = 'BraveSoftware\Brave-Browser\Application\brave.exe'; s = '常见位置/Brave' },
        @{ n = 'Vivaldi\Application\vivaldi.exe';         s = '常见位置/Vivaldi' },
        @{ n = 'Chromium\Application\chrome.exe';         s = '常见位置/Chromium' }
    )) {
        foreach ($d in @($pf, $pf86, $lad)) {
            if ($d) { [void]$out.Add([pscustomobject]@{ Path = (Join-Path $d $b.n); Source = $b.s }) }
        }
    }
    # 注册表 App Paths（三个 hive；装在非标准位置时靠这个）
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    )) {
        foreach ($n in @('chrome.exe', 'msedge.exe', 'brave.exe', 'vivaldi.exe', 'chromium.exe')) {
            try {
                $v = (Get-ItemProperty -Path "$root\$n" -ErrorAction Stop).'(default)'
                if ($v) { [void]$out.Add([pscustomobject]@{ Path = $v; Source = "AppPaths/$n" }) }
            } catch {}
        }
    }
    # PATH 兜底
    foreach ($n in @('chrome.exe', 'msedge.exe', 'brave.exe')) {
        try {
            $c = (Get-Command $n -ErrorAction SilentlyContinue).Source
            if ($c) { [void]$out.Add([pscustomobject]@{ Path = $c; Source = "PATH/$n" }) }
        } catch {}
    }
    return $out
}

# 5) Windows 自己记着的"默认浏览器是谁" —— 品牌无关、位置无关
function Get-DefaultBrowserExe {
    $out = New-Object System.Collections.ArrayList
    try {
        $progId = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction Stop).ProgId
        if ($progId) {
            $cmd = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction Stop).'(default)'
            [void]$out.Add([pscustomobject]@{ Path = (Extract-ExeFromCommand $cmd); Source = "默认浏览器/$progId" })
        }
    } catch {}
    try {
        $cmd = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\http\shell\open\command' -ErrorAction Stop).'(default)'
        [void]$out.Add([pscustomobject]@{ Path = (Extract-ExeFromCommand $cmd); Source = '默认浏览器/http' })
    } catch {}
    return $out
}

function Extract-ExeFromCommand([string]$Cmd) {
    if (-not $Cmd) { return $null }
    if ($Cmd -match '"([^"]+\.exe)"') { return $matches[1] }
    if ($Cmd -match '^\s*([^\s]+\.exe)') { return $matches[1] }
    return $null
}

# 6) 卸载表 —— 覆盖面最广的一张网：不管什么品牌、装在哪个盘，只要正常安装过
#    就会在这登记。绿色版/便携版登记不了，那种只能靠"指定浏览器在哪"。
#
#    这里必须用精确文件名白名单，不能用 /chrome|browser|quark/ 这类模糊匹配：
#    实测会把「夸克网盘 quark_cloud_drive.exe」当成浏览器收进来 —— 那东西一旦
#    被启动会弹窗、可能还要求登录，比"找不到浏览器"糟糕得多。
#    验证虽然靠真启动 CDP，但误报的代价是先把无关程序拉起来，所以要在入口就掐掉。
$script:BrowserExeNames = @(
    'chrome.exe', 'chromium.exe', 'msedge.exe', 'brave.exe', 'vivaldi.exe', 'opera.exe',
    '360chrome.exe', '360se.exe', '360se6.exe', 'QQBrowser.exe', 'SogouExplorer.exe',
    '2345Explorer.exe', 'QuarkPCBrowser.exe', 'CentBrowser.exe', 'Maxthon.exe',
    'liebao.exe', 'TheWorld.exe', 'browser.exe'
)

function Get-InstalledBrowsers {
    $out = New-Object System.Collections.ArrayList
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop } catch { continue }
            if (-not $p) { continue }
            $disp = [string]$p.DisplayName
            foreach ($raw in @([string]$p.DisplayIcon, [string]$p.InstallLocation)) {
                $v = Clean-Path $raw
                if (-not $v) { continue }
                if (Test-Path -LiteralPath $v -PathType Container) {
                    # 给的是目录：在里头按精确名找
                    foreach ($n in $script:BrowserExeNames) {
                        $c = Join-Path $v $n
                        if (Test-Path -LiteralPath $c -PathType Leaf) {
                            [void]$out.Add([pscustomobject]@{ Path = $c; Source = "卸载表/$disp" })
                        }
                    }
                } elseif (Test-Path -LiteralPath $v -PathType Leaf) {
                    # 给的是 exe：名字必须在白名单里
                    $name = [System.IO.Path]::GetFileName($v)
                    if ($script:BrowserExeNames -contains $name) {
                        [void]$out.Add([pscustomobject]@{ Path = $v; Source = "卸载表/$disp" })
                    }
                }
            }
        }
    }
    return $out
}


# 汇总：按"最可能顺利走完 Epic 结账"的顺序排
function Get-BrowserCandidates {
    $list = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # 用户明确指定的排第一，覆盖其它一切
    Add-Candidate $list $seen (Get-SettingBrowser) '手动指定'

    # 上次成功的紧随其后：钉住它，是"稳定性"的来源
    Add-Candidate $list $seen (Get-LastBrowser) '上次使用'

    # 主流浏览器
    foreach ($c in (Get-MainstreamBrowsers)) { Add-Candidate $list $seen $c.Path $c.Source }

    foreach ($c in (Get-DefaultBrowserExe)) { Add-Candidate $list $seen $c.Path $c.Source }

    # 最后才是覆盖面最广、但也最不确定的一批
    $n = 0
    foreach ($c in (Get-InstalledBrowsers)) {
        if ($n -ge 6) { break }
        $before = $list.Count
        Add-Candidate $list $seen $c.Path $c.Source
        if ($list.Count -gt $before) { $n++ }
    }
    return $list
}

# ================= 启动 + 验证 =================

function Start-BrowserExe {
    param(
        [string]$Exe,
        [int]$Port = $(if ($script:BPort) { $script:BPort } else { 9222 }),
        [int]$WaitSec = 15
    )
    if (-not (Test-Path -LiteralPath $script:BProfile)) {
        New-Item -ItemType Directory -Path $script:BProfile -Force | Out-Null
    }
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Exe -PassThru -ErrorAction Stop -ArgumentList @(
            "--remote-debugging-port=$Port",
            "--user-data-dir=`"$script:BProfile`"",
            '--no-first-run', '--no-default-browser-check',
            'https://www.fab.com/'
        )
    } catch {
        return [pscustomobject]@{ ok = $false; browser = ''; error = "启动失败：$($_.Exception.Message)"; proc = $null }
    }

    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-CdpBrowser -Port $Port) {
            $info = Get-CdpInfo -Port $Port
            return [pscustomobject]@{ ok = $true; browser = [string]$info.Browser; error = $null; proc = $proc }
        }
    }

    # 没开出调试端口。可能是被安全软件拦了，也可能它根本不是 Chromium。
    # 把这个进程收掉 —— 否则它会占着 profile 目录，下一个候选因为目录被锁也起不来，
    # 于是全军覆没，报出来却是"找不到浏览器"。
    $err = '启动后没能开出调试端口（可能被安全软件拦截，或不是 Chromium 内核）'
    if ($proc) {
        try {
            if (-not $proc.HasExited) { $proc.Kill(); Start-Sleep -Milliseconds 1200 }
            else { $err = '程序启动后立刻退出了（可能不是浏览器，或被安全软件拦截）' }
        } catch {}
    }
    return [pscustomobject]@{ ok = $false; browser = ''; error = $err; proc = $null }
}

# ================= 编排 =================

function Write-BError([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $script:BLogDir)) { New-Item -ItemType Directory -Path $script:BLogDir -Force | Out-Null }
        [System.IO.File]::WriteAllText(
            (Join-Path $script:BLogDir 'browser-error.txt'),
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text`r`n",
            (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

function Clear-BError {
    try {
        $f = Join-Path $script:BLogDir 'browser-error.txt'
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    } catch {}
}

<#
  保证有一个能用的浏览器。返回：
    @{ ok; exe; source; browser; port; error; tried }
#>
function Ensure-BrowserWork {
    param(
        [scriptblock]$Log = $null,     # 可选：进度回调，GUI 用来刷状态栏
        [int]$MaxTry = 8               # 最多试几个候选，兜住最坏耗时
    )
    $say = { param($m) if ($Log) { & $Log $m } }
    if (-not $script:BPort) { Initialize-BPort }
    $result = @{ ok = $false; exe = ''; source = ''; browser = ''; port = $script:BPort; error = $null; tried = @() }

    # 端口上已经有一个能直接用的浏览器 —— 复用（这是最常见的情况）
    $re = Test-CdpReusable -Port $script:BPort
    if ($re.ok) {
        $info = Get-CdpInfo -Port $script:BPort
        & $say "已连接到正在运行的浏览器（$($info.Browser)）"
        $result.ok = $true; $result.browser = [string]$info.Browser; $result.source = '已在运行'
        Clear-BError
        return $result
    }

    # 端口上有个浏览器、但不能直接拿来用（headless / 别人的）：换端口，别去动它。
    # 从 端口+1 开始找 —— 从原端口开始的话 Resolve-FreePort 一眼就看见"这儿有浏览器"，
    # 会把同一个端口原样还回来。
    if ($re.kind -eq 'unusable') {
        & $say "端口 $($script:BPort) 上的浏览器不能直接用（$($re.why)），换个端口"
        $script:BPort = (Resolve-FreePort -Start ($script:BPort + 1)).Port
        $result.port = $script:BPort
        & $say "改用端口 $($script:BPort)"
    }
    # 端口被非浏览器占着：Chromium 遇到端口被占不会报错，只会静默地不开调试端口，
    # 一路看下来就是"浏览器起不来"。换个端口比在这上面耗着强。
    elseif (Test-PortOpen -Port $script:BPort) {
        & $say "端口 $($script:BPort) 被其它程序占用了，换一个"
        $fp = Resolve-FreePort -Start $script:BPort
        if ($fp.Port -ne $script:BPort) {
            $script:BPort = $fp.Port
            $result.port = $script:BPort
            & $say "改用端口 $($script:BPort)"
        }
    }

    $cands = Get-BrowserCandidates
    if (-not $cands -or $cands.Count -eq 0) {
        $result.error = '没有找到任何浏览器'
        Write-BError $result.error
        return $result
    }

    $i = 0
    foreach ($c in $cands) {
        if ($i -ge $MaxTry) { break }
        $i++
        & $say "正在尝试浏览器（$i/$([Math]::Min($MaxTry,$cands.Count))）：$($c.Path)"
        $r = Start-BrowserExe -Exe $c.Path -Port $script:BPort
        if ($r.ok) {
            $result.ok = $true; $result.exe = $c.Path; $result.source = $c.Source; $result.browser = $r.browser
            & $say "已连接：$($r.browser)"
            # 钉住这个，下次直接用，也保证计划任务用的是同一个。
            # 只写 lastBrowser，绝不写 browser —— 那是用户手动指定的位置。
            # cdpPid 是"这个端口上的浏览器是我们的"的凭据，下次启动要靠它认人。
            Save-BSettings @{ lastBrowser = $c.Path; cdpPort = $script:BPort; cdpPid = $r.proc.Id }
            Clear-BError
            return $result
        }
        [void]$result.tried.Add("$($c.Path)  [$($c.Source)]  → $($r.error)")
        & $say "不行：$($r.error)"
    }

    $result.error = if ($result.tried.Count -ge $MaxTry) {
        "试过 $MaxTry 个浏览器都没能用（详细原因见日志）"
    } else {
        "试过 $($result.tried.Count) 个浏览器都没能用（详细原因见日志）"
    }
    Write-BError ($result.error + "`r`n" + ($result.tried -join "`r`n"))
    return $result
}

# ================= 独立运行模式（给 auto-claim.cmd 用）=================

if ($Ensure -or $List) {
    $ErrorActionPreference = 'Continue'   # 独立运行：全是"试一试"的代码，不该因一条失败就中断
    Initialize-BPort
    $log = { param($m) [Console]::Error.WriteLine($m) }

    if ($List) {
        $cands = Get-BrowserCandidates
        foreach ($c in $cands) { Write-Output "$($c.Path)   [$($c.Source)]" }
        Write-Output "共 $($cands.Count) 个候选"
        exit 0
    }

    $r = Ensure-BrowserWork -Log $log
    if ($r.ok) {
        # 端口写进文件，auto-claim.cmd 才能用同一个（它读不了 JSON）
        try {
            [System.IO.File]::WriteAllText($script:BPortFile, [string]$r.port, (New-Object System.Text.UTF8Encoding $false))
        } catch {}
    }
    Write-Output (ConvertTo-Json @{
        ok = $r.ok; exe = $r.exe; source = $r.source; browser = $r.browser; port = $r.port; error = $r.error
    } -Compress)
    exit $(if ($r.ok) { 0 } else { 1 })
}
