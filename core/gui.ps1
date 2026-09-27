<#
  Fab 限时免费领取助手 —— 图形界面
  由 启动.bat 调起。读取 core\claim.mjs 输出的 NDJSON 事件流并显示。
  所有路径均相对本脚本，整个文件夹可任意改名/移动。
#>

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 高清屏不糊
Add-Type -Namespace FabApp -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
try { [void][FabApp.Dpi]::SetProcessDPIAware() } catch {}

# ---------- 单实例 ----------
# 开两个界面会互抢同一个浏览器调试端口，必须挡住。
# 这个互斥体同时被安装程序用作 AppMutex，用来检测"程序正在运行"。
$script:AppMutex = $null
try {
    $createdNew = $false
    $script:AppMutex = New-Object System.Threading.Mutex($true, 'FabClaimerGui', [ref]$createdNew)
    if (-not $createdNew) {
        Add-Type -Namespace FabApp -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
        $h = [FabApp.Win]::FindWindow($null, 'Fab 限时免费领取助手')
        if ($h -ne [IntPtr]::Zero) {
            # 已经在开着了，把它拉到前面就行，别再开一个
            [void][FabApp.Win]::ShowWindow($h, 9)      # SW_RESTORE
            [void][FabApp.Win]::SetForegroundWindow($h)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                '程序已经在运行了（窗口可能在别的程序后面，检查一下任务栏）。',
                'Fab 领取助手', 'OK', 'Information')
        }
        exit
    }
} catch { }   # 拿不到互斥体不该让程序起不来

# ---------- 路径 ----------
$Core      = $PSScriptRoot                                    # ...\core
$AppRoot   = (Get-Item (Join-Path $Core '..')).FullName        # 程序根目录
$NodeExe   = Join-Path $Core 'node.exe'
$ClaimJs   = Join-Path $Core 'claim.mjs'
$AutoCmd   = Join-Path $Core 'auto-claim.cmd'
$LogDir    = Join-Path $AppRoot 'logs'
$ClaimedJs = Join-Path $AppRoot 'claimed.json'
$IconFile  = Join-Path $Core 'fab.ico'            # Fab 图标（窗口 / 任务栏 / 快捷方式）
$RunLog    = Join-Path $LogDir 'task.log'
$TaskName  = 'FabLimitedTimeFreeAutoClaim'
# profile\ 和 settings.json 由 browser.ps1 管理（$script:BProfile / $script:BSettings），
# 这里不再各留一份，免得两处路径哪天对不上

# 版本号 —— 显示在标题下面，也用来和远端比"要不要更新"。
# 读不到就当空（旧版本装上来的没有这个文件），绝不能因此让程序起不来。
$script:AppVer = ''
try {
    $vt = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'version.json')).TrimStart([char]0xFEFF)
    $script:AppVer = [string](($vt | ConvertFrom-Json).version)
} catch { $script:AppVer = '' }

# ---------- 浏览器定位 / 启动 / 验证 ----------
# 全部收在 browser.ps1 里，界面和计划任务共用同一份。
# 以前这里和 auto-claim.cmd 各写了一份名单，必然漂移：界面上手动指定了
# Brave，计划任务那份只认硬编码的 5 条 Chrome/Edge 路径，于是自动领取
# 静默失败几个月没人知道。
. (Join-Path $Core 'browser.ps1')

# 调试端口：FAB_CDP 环境变量 > settings.json 上次定下的 > 9222。
# 端口可能因为被别的程序占用而自动换掉，所以必须问 browser.ps1 要，不能写死。
function Sync-CdpPort {
    $script:Port    = $script:BPort
    $script:CdpBase = "http://127.0.0.1:$($script:BPort)"
}
$script:Port = $script:BPort
$script:CdpBase = "http://127.0.0.1:$($script:BPort)"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ---------- 状态 ----------
$script:Proc      = $null
$script:Busy      = $false
$script:LoggedIn  = $false
$script:LoginWaitSec = 0      # 已经等了多久登录，显示给用户看，免得他以为程序卡住了
$script:LoginName = ''
$script:WhoProc   = $null
$script:WhoTicks  = 0
$script:LoginProc = $null
$script:AutoLoginDone = $false
$script:UpdProc   = $null     # 后台查新版本
$script:UpdApplyProc = $null  # 正在下载新版本
$script:UpdVer    = ''        # 查到的远端版本号
$script:UpdLocal  = ''        # 本机版本号
$script:UpdNotes  = ''
$script:UpdManual = $false    # 这次检查是不是用户手动点的（决定失败要不要出声）
$script:HintIsUpdate = $false # 提示条上现在挂的是"更新"还是"登录"
$script:Items     = [ordered]@{}   # uid -> @{Title;State;Reason}
$script:OkCount   = 0
$script:TodoCount = 0
$script:Ends      = ''
$script:ListItems = @{}            # uid -> ListViewItem

# ================= 工具函数 =================


# 找浏览器这件事已经从本文件搬走了 —— 见 browser.ps1 的 Get-BrowserCandidates。
# 那边不再靠"猜路径"（那是白名单，永远会漏），而是按
#   手动指定 → 上次成功的 → 主流浏览器 → 默认浏览器关联 → 卸载表 → PATH
# 收集候选，再逐个真启动一次、用 /json/version 确认它真的开出了 CDP 端口才认。

# 真的一个浏览器都用不了时的出路：说清楚是什么原因 + 给出能走的路。
#
# 文案必须区分「一个都没找到」和「找到了但起不来」——
# 以前两者都报「找不到浏览器」，用户照着提示去装 Edge，装完发现还是不行，
# 因为真正的原因是调试端口被安全软件拦了。给错原因比不给原因更浪费时间。
# 返回：'pick' | 'edge' | 'cancel'
function Show-NoBrowserHelp {
    param([string]$Reason = '', $Tried = @())

    Set-Status '没有可用的浏览器' 'err'
    Add-Log "没有可用的浏览器。$Reason" 'err'
    # 别用 $t 当循环变量。PowerShell 的脚本块是动态作用域的，别处在事件回调里
    # 解析 $t 时会被这里临时盖住 —— 我在测试脚本里就这么被咬了一次。
    foreach ($item in $Tried) { Add-Log "  试过 $item" 'warn' }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Fab 领取助手 —— 没有可用的浏览器'
    $dlg.ClientSize      = New-Object System.Drawing.Size(640, 390)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    if ($fontUI) { $dlg.Font = $fontUI }
    if ($form -and -not $form.IsDisposed -and $form.Icon) { $dlg.Icon = $form.Icon }

    $tip = New-Object System.Windows.Forms.Label
    $tip.Location = New-Object System.Drawing.Point(16, 14)
    $tip.Size     = New-Object System.Drawing.Size(608, 62)
    $tip.Text = "本程序需要一个 Chromium 内核的浏览器（Chrome / Edge / Brave 等），`n" +
                "并且它要能开启调试端口 —— 程序靠这个端口模拟真人点击走完 Epic 结账。`n`n" +
                "自动查找没有成功：$Reason"
    $dlg.Controls.Add($tip)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location   = New-Object System.Drawing.Point(16, 84)
    $box.Size       = New-Object System.Drawing.Size(608, 168)
    $box.Multiline  = $true
    $box.ReadOnly   = $true
    $box.ScrollBars = 'Both'    # 不换行，路径很长；只给竖条的话横向会被截掉又拖不动
    $box.WordWrap   = $false
    $box.BackColor  = [System.Drawing.Color]::FromArgb(248, 248, 248)
    $box.Text = if ($Tried -and @($Tried).Count) { (@($Tried) -join "`r`n") } else { '（没有可尝试的候选）' }
    $dlg.Controls.Add($box)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(16, 258)
    $hint.Size     = New-Object System.Drawing.Size(608, 60)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $hint.Text = "「指定浏览器在哪」：浏览器装在非标准位置、或你用的是绿色版时，选它的 exe。`n" +
                 "「打开 Edge 下载页」：本机确实一个能用的都没有时，装一个再回来。"
    $dlg.Controls.Add($hint)

    # 四个按钮。用 Tag 传动作、用脚本级变量回传结果 ——
    # 事件处理器里靠闭包捕获局部变量在 PS 5.1 上不可靠（GetNewClosure 会把
    # $script: 也一并换到新作用域里去），Tag + 脚本级变量是最稳的写法。
    $script:NoBrowserChoice = 'cancel'
    $script:NoBrowserDlg    = $dlg
    $mk = {
        param([string]$Text, [int]$X, [int]$Y, [int]$W, [string]$Action, [bool]$Primary)
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $Text
        $b.Tag       = $Action
        $b.Location  = New-Object System.Drawing.Point($X, $Y)
        $b.Size      = New-Object System.Drawing.Size($W, 34)
        $b.FlatStyle = 'System'
        if ($Primary -and $fontHd) { $b.Font = $fontHd }
        $b.Add_Click({
            $script:NoBrowserChoice = [string]$this.Tag
            if ($script:NoBrowserDlg -and -not $script:NoBrowserDlg.IsDisposed) { $script:NoBrowserDlg.Close() }
        })
        $script:NoBrowserDlg.Controls.Add($b)
        return $b
    }
    [void](& $mk '指定浏览器在哪…'   16 326 190 'pick'   $true)
    [void](& $mk '打开 Edge 下载页'  216 326 150 'edge'   $false)
    [void](& $mk '先不处理'         546 326  78 'cancel' $false)

    if ($form -and -not $form.IsDisposed) { [void]$dlg.ShowDialog($form) } else { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    $script:NoBrowserDlg = $null
    return $script:NoBrowserChoice
}

# ---------- 设置读写 ----------
# 真正读写 settings.json 的是 browser.ps1 的 Read-BSettings / Save-BSettings。
# 这里不再自己实现一份：两个实现写同一个文件就是"多个真相源"，
# 正是这次要消掉的东西（见 browser.ps1 顶部的说明）。
function Read-Settings { return Read-BSettings }
function Save-Settings([hashtable]$Values) { Save-BSettings $Values }

function Select-BrowserDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '请选择浏览器程序（chrome.exe / msedge.exe / brave.exe 等）'
    $dlg.Filter = '浏览器程序 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    $dlg.CheckFileExists = $true
    foreach ($d in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($d -and (Test-Path $d)) { $dlg.InitialDirectory = $d; break }
    }
    # 有主窗口就挂上去当 owner，保证选择框弹在前面
    $r = if ($form -and -not $form.IsDisposed) { $dlg.ShowDialog($form) } else { $dlg.ShowDialog() }
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}

# 跑一遍完整的候选搜索 + 启动 + 验证。进度刷到状态栏。
function Invoke-BrowserSearch {
    $r = Ensure-BrowserWork -Log {
        param($m)
        Set-Status $m 'run'
        [System.Windows.Forms.Application]::DoEvents()
    }
    Sync-CdpPort
    if ($r.ok) { Add-Log "浏览器：$($r.browser)（来自 $($r.source)）" 'ok' }
    return $r
}

# 保证浏览器可用。真正的逻辑都在 browser.ps1，这里只负责刷界面和在彻底失败时问用户。
function Ensure-Browser {
    # 复用只认"能干活、而且是我们自己启动的"浏览器 —— 判据在 browser.ps1。
    # 这里图省事只看"端口上有没有浏览器"的话，会把别人的 headless Chrome 接过来，
    # 那东西没窗口、也没登录态，用户看到的是「没有窗口 + 未登录 + 被 Cloudflare 拦」。
    if ((Test-CdpReusable -Port $script:BPort).ok) { Sync-CdpPort; return $true }
    Set-Status '正在启动浏览器…' 'run'
    [System.Windows.Forms.Application]::DoEvents()

    $r = Invoke-BrowserSearch
    if ($r.ok) { return $true }

    while ($true) {
        $choice = Show-NoBrowserHelp -Reason $r.error -Tried $r.tried

        if ($choice -eq 'cancel') { return (Test-CdpBrowser -Port $script:BPort) }
        if ($choice -eq 'edge')   { Start-Process 'https://www.microsoft.com/edge/download'; return $false }

        if ($choice -eq 'pick') {
            $exe = Select-BrowserDialog
            if (-not $exe) { continue }     # 在选择框里取消了，退回上一层

            Set-Status '正在测试这个浏览器…' 'run'
            [System.Windows.Forms.Application]::DoEvents()
            $t = Start-BrowserExe -Exe $exe -Port $script:BPort
            if (-not $t.ok) {
                $again = [System.Windows.Forms.MessageBox]::Show(
                    "这个程序没能作为浏览器启动：`n`n$exe`n`n$($t.error)`n`n" +
                    "请确认选的是 chrome.exe / msedge.exe 这类浏览器，而不是别的程序。`n`n要重新选吗？",
                    'Fab 领取助手', 'YesNo', 'Warning')
                if ($again -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
                continue
            }
            # 验过了才记住 —— 记住一个起不来的路径，下次启动还要白等一轮
            # cdpPid 一起记：下次靠它认"端口上那个浏览器是我们的"
            Save-Settings @{ browser = $exe; cdpPort = $script:BPort; cdpPid = $t.proc.Id }
            Sync-CdpPort
            Add-Log "已记住这个浏览器，下次直接用：$exe" 'ok'
            Add-Log "浏览器：$($t.browser)" 'ok'
            Set-Status '浏览器已就绪' 'ok'
            return $true
        }

        return (Test-CdpBrowser -Port $script:BPort)
    }
}

# 结尾去重：Log[...] 里用
function Add-Log([string]$Text, [string]$Kind = 'info') {
    if ($script:Rtb.IsDisposed) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Kind) {
        'ok'    { [System.Drawing.Color]::FromArgb(22, 130, 60) }
        'warn'  { [System.Drawing.Color]::FromArgb(190, 110, 0) }
        'err'   { [System.Drawing.Color]::FromArgb(190, 45, 45) }
        'head'  { [System.Drawing.Color]::FromArgb(40, 80, 160) }
        default { [System.Drawing.Color]::FromArgb(70, 70, 70) }
    }
    $script:Rtb.SelectionStart = $script:Rtb.TextLength
    $script:Rtb.SelectionLength = 0
    $script:Rtb.SelectionColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $script:Rtb.AppendText("[$stamp] ")
    $script:Rtb.SelectionStart = $script:Rtb.TextLength
    $script:Rtb.SelectionColor = $color
    $script:Rtb.AppendText("$Text`r`n")
    $script:Rtb.SelectionStart = $script:Rtb.TextLength
    $script:Rtb.ScrollToCaret()
}

function Set-Status([string]$Text, [string]$Kind = 'info') {
    $script:LblStatus.Text = "● $Text"
    $script:LblStatus.ForeColor = switch ($Kind) {
        'ok'   { [System.Drawing.Color]::FromArgb(22, 130, 60) }
        'warn' { [System.Drawing.Color]::FromArgb(200, 110, 0) }
        'err'  { [System.Drawing.Color]::FromArgb(190, 45, 45) }
        'run'  { [System.Drawing.Color]::FromArgb(40, 80, 160) }
        default { [System.Drawing.Color]::FromArgb(90, 90, 90) }
    }
}

$StateText = @{
    owned    = '已拥有'
    todo     = '待领取'
    claiming = '领取中…'
    ok       = '✅ 已入库'
    fail     = '❌ 失败'
    skip     = '跳过'
    unknown  = '需要先登录'
}

function Update-Row([string]$Uid, [string]$Title, [string]$State, [string]$Reason) {
    $text = $StateText[$State]
    if (-not $text) { $text = $State }
    if ($State -eq 'fail' -and $Reason) { $text = '❌ ' + $Reason }
    if (-not $script:ListItems.ContainsKey($Uid)) {
        $lvi = New-Object System.Windows.Forms.ListViewItem($Title)
        [void]$lvi.SubItems.Add($text)
        $lvi.Tag = $Uid
        [void]$script:LstBatch.Items.Add($lvi)
        $script:ListItems[$Uid] = $lvi
    } else {
        $lvi = $script:ListItems[$Uid]
        $lvi.SubItems[1].Text = $text
    }
    $lvi = $script:ListItems[$Uid]
    switch ($State) {
        'owned'    { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 130) }
        'ok'       { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(22, 130, 60) }
        'fail'     { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(190, 45, 45) }
        'claiming' { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(40, 80, 160) }
        'todo'     { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30) }
        'unknown'  { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(160, 120, 30) }
        default    { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150) }
    }
}

function Update-BatchLabel {
    $n = $script:LstBatch.Items.Count
    if ($n -eq 0) { $script:LblBatch.Text = '当前批次：正在获取…'; return }
    $owned = 0; $unknown = 0
    foreach ($k in $script:Items.Keys) {
        if ($script:Items[$k].State -eq 'owned')   { $owned++ }
        if ($script:Items[$k].State -eq 'unknown') { $unknown++ }
    }
    if ($unknown -gt 0)     { $tail = '（登录后可确认是否已拥有）' }
    elseif ($owned -gt 0)   { $tail = "，其中 $owned 个已拥有" }
    else                    { $tail = '' }
    $dead = ''
    if ($script:Ends) {
        try { $dead = '　·　' + ([datetime]$script:Ends).ToLocalTime().ToString('M月d日 HH:mm') + ' 截止' } catch {}
    }
    $script:LblBatch.Text = "当前批次：$n 个限时免费资产$tail$dead"
}

function Set-Busy([bool]$Busy) {
    $script:Busy = $Busy
    $script:BtnScan.Enabled = -not $Busy
    $script:BtnBrowser.Enabled = -not $Busy
    if ($Busy) {
        $script:BtnClaim.Enabled = $false
        $script:BtnClaim.Text = '处理中…'
        return
    }
    if (-not $script:LoggedIn) {
        # 没登录时不允许点领取 —— 点了也只会失败，还给用户挫败感
        $script:BtnClaim.Enabled = $false
        $script:BtnClaim.Text = '需要先登录'
        return
    }
    $n = 0
    $total = $script:Items.Keys.Count
    foreach ($k in $script:Items.Keys) { if ($script:Items[$k].State -eq 'todo') { $n++ } }
    if ($n -eq 0 -and $total -gt 0) {
        # 这一批全领过了，按钮没有可做的事
        $script:BtnClaim.Enabled = $false
        $script:BtnClaim.Text = '本批已全部领取'
        return
    }
    $script:BtnClaim.Enabled = $true
    $script:BtnClaim.Text = if ($n -gt 0) { "一键领取 ($n)" } else { '一键领取' }
}

# ---------- 辅助 node 进程（登录检测 / 打开登录页）----------
# 都比主流程轻量，但同样是异步跑，避免卡住界面
function Start-AuxNode {
    param([string]$ScriptFile, [string]$Tag, [string]$ExtraArgs = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $NodeExe
    $psi.Arguments              = if ($ExtraArgs) { "`"$ScriptFile`" $ExtraArgs" } else { "`"$ScriptFile`"" }
    $psi.WorkingDirectory       = $Core
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['FAB_CDP'] = $CdpBase
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true
    # 同名 SourceIdentifier 重复注册会抛异常，先清掉上一轮的
    Unregister-Event -SourceIdentifier "$Tag`Out"  -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "$Tag`Exit" -ErrorAction SilentlyContinue
    Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -SourceIdentifier "$Tag`Out" | Out-Null
    Register-ObjectEvent -InputObject $p -EventName Exited             -SourceIdentifier "$Tag`Exit" | Out-Null
    [void]$p.Start()
    $p.BeginOutputReadLine()
    return $p
}

$script:LoginHintText = '请在弹出的浏览器窗口里登录 Epic（该窗口为本程序专用，登录一次即长期有效）'

# 提示条只有一条，"请登录"和"发现新版本"会抢它。规则：登录优先 ——
# 登录是挡在领取前面的，更新只是顺便。登录提示收起来的时候再把更新提示放回去。
function Show-LoginHint([string]$Text) {
    $script:HintIsUpdate = $false
    $script:LblHint.Text = $Text
    $script:LblHint.Visible = $true
}
function Hide-LoginHint {
    if ($script:HintIsUpdate) { return }    # 挂着的是更新提示，别顺手收掉
    $script:LblHint.Visible = $false
    if ($script:UpdVer) { Show-UpdateHint }
}
function Show-UpdateHint {
    if (-not $script:UpdVer) { return }
    $script:HintIsUpdate = $true
    $script:LblHint.Text = "发现新版本 v$($script:UpdVer)（当前 v$($script:UpdLocal)）" +
                           " —— 点这里更新，下载完程序会自己重启"
    $script:LblHint.Visible = $true
}

# 置顶和浏览器窗口天然打架：窗口一直压在最上面的话，用户切到浏览器后浏览器会藏在它后面，
# 不熟悉电脑的人就卡死在这一步了。所以登录/人机验证期间临时取消置顶，之后自动恢复。
# 只在我们自己取消过的时候才恢复 —— 用户自己关掉的置顶，不许我们替他打开。
$script:TopMostSuspended = $false
function Suspend-TopMostForLogin {
    if (-not $chkTop.Checked) { return }
    $script:TopMostSuspended = $true
    $chkTop.Checked = $false          # 勾选框跟着走，免得界面显示的和实际状态对不上
    Add-Log '已临时取消窗口置顶，免得挡住浏览器窗口；之后会自动恢复。'
}
function Restore-TopMostAfterLogin {
    if (-not $script:TopMostSuspended) { return }
    $script:TopMostSuspended = $false
    $chkTop.Checked = $true
    Add-Log '已恢复窗口置顶。'
}

# 把浏览器带到前台并打开 Epic 登录页
function Invoke-Login {
    if ($script:LoginProc -and -not $script:LoginProc.HasExited) { return }
    Suspend-TopMostForLogin
    Set-Status '未登录 —— 正在打开 Epic 登录页面…' 'run'
    Show-LoginHint $script:LoginHintText
    $script:LoginProc = Start-AuxNode -ScriptFile (Join-Path $Core 'open-login.mjs') -Tag 'FabLogin'
}

# 每 5 秒探一次登录态
function Check-LoginNow {
    if ($script:Busy -or $script:LoggedIn) { return }
    if (-not $script:AutoLoginDone) { return }   # 还没确认过要登录，先别改提示
    $script:LoginWaitSec += 5
    # 把"程序在自己检查"明写出来。不写的话用户不知道该等还是该点，
    # 大多数人的第一反应是去点「刷新批次」，然后以为程序坏了。
    Show-LoginHint ("还没登录 —— 请在刚打开的浏览器窗口里登录。程序每 5 秒自动检查一次，" +
                    "登录成功后会自动继续（已等待 $($script:LoginWaitSec) 秒）")
    if ($script:WhoProc -and -not $script:WhoProc.HasExited) { return }
    $script:WhoProc = Start-AuxNode -ScriptFile (Join-Path $Core 'whoami.mjs') -Tag 'FabWho'
}

# ---------- 自更新 ----------
# 只查、不自动装：查到新版本就在提示条上问一句，用户点了才下载。
# 全程用后台 node 进程跑，界面不卡；查不到（离线、GitHub 不通）就安静跳过 ——
# 绝不能因为"查更新失败"影响到正常领取。
function Start-UpdateCheck([switch]$Manual) {
    if ($script:UpdProc -and -not $script:UpdProc.HasExited) { return }
    $script:UpdManual = [bool]$Manual
    if ($Manual) {
        Set-Status '正在检查更新…' 'run'
        Add-Log '正在检查更新…'
    }
    $script:UpdProc = Start-AuxNode -ScriptFile (Join-Path $Core 'update.mjs') -Tag 'FabUpd' -ExtraArgs '--check'
}

function Invoke-Update {
    if ($script:Busy) { return }
    if ($script:UpdApplyProc -and -not $script:UpdApplyProc.HasExited) { return }
    $script:HintIsUpdate = $false
    $script:LblHint.Visible = $false
    Set-Status "正在下载新版本 v$($script:UpdVer)…" 'run'
    Add-Log "正在下载新版本 v$($script:UpdVer)…" 'head'
    Add-Log '  下载完程序会自己重启，界面会闪一下，属于正常。' 'head'
    # --parent 把自己这个进程号交给它：下载完由它拉起的独立进程等本界面退出，
    # 再覆盖文件、重新启动。覆盖自己正在跑的代码这一步，必须等界面退干净。
    $script:UpdApplyProc = Start-AuxNode -ScriptFile (Join-Path $Core 'update.mjs') -Tag 'FabUpdApply' -ExtraArgs "--apply --parent $PID"
}

# ================= 事件处理 =================

function Handle-Event($e) {
    $ev = $e.ev
    switch ($ev) {
        'phase' { Set-Status $e.text 'run' }
        'login' {
            if ($e.ok) {
                $script:LoggedIn = $true
                $script:LoginName = if ($e.name) { [string]$e.name } else { '已登录' }
                $script:LoginWaitSec = 0
                Hide-LoginHint
                Restore-TopMostAfterLogin
                $name = if ($e.name) { $e.name } else { '已登录' }
                Set-Status "已登录 Epic：$name" 'ok'
                Add-Log "已登录：$name" 'ok'
                $script:BtnBrowser.Text = '打开浏览器'
            } elseif ($e.blocked) {
                # 被 Cloudflare 拦了，不是没登录 —— 等会儿的 challenge 事件会给专门提示，
                # 这里不能按"未登录"处理（那会弹登录页，把用户带偏）
            } elseif ($e.checked -eq $false) {
                # 检查本身没成功（页面正在跳转/上下文被销毁），不是"未登录"。
                # 关键：不能在这里把 $script:LoggedIn 改成 false —— 那会把上一秒
                # 刚确认的已登录状态错误地降级，用户就会看到"登录了却还显示未登录"。
                Add-Log '这次没查到登录态（页面可能正在跳转），稍后自动重试' 'warn'
            } else {
                $script:LoggedIn = $false
                Set-Status '未登录 —— 需要先登录 Epic 账号' 'err'
                $script:BtnBrowser.Text = '去登录'
                # 自动打开登录页，但只在本次运行里自动一次，免得反复抢焦点
                if (-not $script:AutoLoginDone) {
                    $script:AutoLoginDone = $true
                    $script:LoginWaitSec = 0
                    # 把步骤一条条写清楚。这里的目标用户多半不熟悉电脑：
                    # 不写明白的话，他不知道要去哪儿登录、登完要不要回来点一下，
                    # 最常见的结局是坐那儿干等，然后以为程序坏了。
                    Add-Log '需要你先登录一次 Epic 账号（只需一次，以后会记住）。' 'err'
                    Add-Log '  ① 切到刚打开的那个浏览器窗口' 'head'
                    Add-Log '     （是本程序专用的独立窗口，不是你日常用的浏览器，' 'head'
                    Add-Log '       里面没有任何书签、扩展，这是正常的）' 'head'
                    Add-Log '  ② 在里面登录你的 Epic 账号' 'head'
                    Add-Log '  ③ 登录完就什么都不用做了 —— 程序每 5 秒自动检查一次，' 'head'
                    Add-Log '     一登录成功就会自己继续，并自动刷新资产列表' 'head'
                    Add-Log '  找不到那个窗口了？点「去登录」，会把它重新调到前面。' 'head'
                    Invoke-Login
                } else {
                    Show-LoginHint $script:LoginHintText
                }
            }
        }
        'batch' {
            Add-Log "发现当前批次共 $($e.count) 个限时免费资产" 'head'
        }
        'item' {
            $uid = [string]$e.uid
            $title = [string]$e.title
            if (-not $script:Items.Contains($uid)) {
                $script:Items[$uid] = @{ Title = $title; State = 'todo'; Reason = '' }
            }
            $script:Items[$uid].State = [string]$e.state
            if ($e.reason) { $script:Items[$uid].Reason = [string]$e.reason }
            if ($e.ends)   { $script:Ends = [string]$e.ends }
            Update-Row $uid $title ([string]$e.state) ([string]$e.reason)
            switch ($e.state) {
                'owned'    { Add-Log "已拥有，跳过：$title" }
                'todo'     { Add-Log "待领取：$title" }
                'unknown'  { Add-Log "未登录，无法确认是否已拥有：$title" 'warn' }
                'skip'     { Add-Log "跳过：$title（$($e.reason)）" 'warn' }
                'claiming' { Add-Log "正在领取：$title" 'head' }
                'ok'       { Add-Log "领取成功：$title" 'ok' }
                'fail'     { Add-Log "领取失败：$title —— $($e.reason)" 'err' }
            }
            Update-BatchLabel
        }
        'summary' {
            if ($e.scan) { return }
            if ($e.total -gt 0) {
                $ok = $e.ok; $total = $e.total
                if ($ok -eq $total) { Add-Log "全部完成：$ok/$total 个资产已入库" 'ok' }
                else { Add-Log "完成：$ok/$total 个成功，$($total - $ok) 个需要处理" 'warn' }
            } elseif ($e.note) {
                Add-Log $e.note
            }
        }
        'fatal' {
            Add-Log "出错：$($e.text)" 'err'
            Set-Status $e.text 'err'
            # FabExit 里靠这个标记避免把刚显示的错误状态盖成「就绪」——
            # 之前只读不写，等于白写：出错后状态栏一秒就被覆盖掉了
            $script:HadFatal = $true
        }
        'challenge' {
            # Cloudflare 人机验证。跟登录一样是「需要用户动一下手」，不是错误 ——
            # 主流程会在那边等着，过了自动继续，所以这里只负责把话说明白。
            if ($e.ok) {
                Hide-LoginHint
                Restore-TopMostAfterLogin
                Set-Status '人机验证已通过，继续…' 'run'
                Add-Log '人机验证已通过。' 'ok'
            } elseif ($e.timeout) {
                # 已经放弃了，置顶得还回去，否则界面永远浮在最上面
                Restore-TopMostAfterLogin
            } elseif ($e.sec) {
                # 等待中的心跳：只更新提示，不重复刷日志
                Show-LoginHint "等待人机验证 —— 请切到浏览器窗口点一下「确认您是真人」（已等待 $($e.sec) 秒）"
            } else {
                Suspend-TopMostForLogin
                Set-Status '等待人机验证 —— 请到浏览器窗口点一下' 'err'
                # 步骤同样一条条写清楚：这段文字出现的时刻，用户多半正一头雾水
                # （上一次操作还好好的，怎么突然就报错了）
                Add-Log 'Fab 的人机验证拦住了这次请求（不是你操作错了，也不是没登录）。' 'err'
                Add-Log '  ① 切到浏览器窗口（就是本程序打开的那个专用窗口）' 'head'
                Add-Log '  ② 页面上会出现「确认您是真人」的验证框，点一下' 'head'
                Add-Log '     如果只显示「请稍候…」，等几秒它自己会出来' 'head'
                Add-Log '  ③ 点完什么都不用做 —— 程序每 5 秒自动检查一次，' 'head'
                Add-Log '     一通过就会自己接着领取' 'head'
                Add-Log '  要是超过 5 分钟还没过，程序会先停下；验证完点「刷新批次」即可。' 'head'
                Show-LoginHint '等待人机验证 —— 请切到浏览器窗口点一下「确认您是真人」'
            }
        }
        'log' { }   # 详细日志已由脚本自身写入 logs\，界面不刷屏
    }
}

function Start-Run([string]$ExtraArgs, [string]$What) {
    if ($script:Busy) { return }
    if (-not (Test-Path $NodeExe)) { [System.Windows.Forms.MessageBox]::Show("缺少运行文件：`n$NodeExe", 'Fab 领取助手', 'OK', 'Error') | Out-Null; return }
    if (-not (Ensure-Browser)) { return }

    Set-Busy $true
    Set-Status "$What…" 'run'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $NodeExe
    $psi.Arguments              = "`"$ClaimJs`" --gui $ExtraArgs"
    $psi.WorkingDirectory       = $Core
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['FAB_DATA'] = $AppRoot
    $psi.EnvironmentVariables['FAB_CDP']  = $CdpBase

    $script:Proc = New-Object System.Diagnostics.Process
    $script:Proc.StartInfo = $psi
    $script:Proc.EnableRaisingEvents = $true

    Register-ObjectEvent -InputObject $script:Proc -EventName OutputDataReceived -SourceIdentifier 'FabOut' | Out-Null
    Register-ObjectEvent -InputObject $script:Proc -EventName ErrorDataReceived  -SourceIdentifier 'FabErr' | Out-Null
    Register-ObjectEvent -InputObject $script:Proc -EventName Exited             -SourceIdentifier 'FabExit' | Out-Null

    [void]$script:Proc.Start()
    $script:Proc.BeginOutputReadLine()
    $script:Proc.BeginErrorReadLine()
}

function Drain-ProcessEvents {
    # stdout → NDJSON 事件
    foreach ($e in @(Get-Event -SourceIdentifier 'FabOut' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $line) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if (-not $obj -or -not $obj.ev) { continue }
        try { Handle-Event $obj } catch { }
    }
    # stderr → 只在有内容时提示
    foreach ($e in @(Get-Event -SourceIdentifier 'FabErr' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if ($line) { Add-Log "内部错误：$line" 'err' }
    }
    # 退出
    foreach ($e in @(Get-Event -SourceIdentifier 'FabExit' -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'FabOut' -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'FabErr' -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier 'FabExit' -ErrorAction SilentlyContinue
        Set-Busy $false
        Update-BatchLabel
        # 运行结束回到待机状态；已登录就把用户名显示回来，别被「就绪」盖掉
        if (-not $script:HadFatal) {
            if ($script:LoggedIn) { Set-Status "已登录 Epic：$($script:LoginName)" 'ok' }
            elseif ($script:LoginProc -or $script:AutoLoginDone) { Set-Status '未登录 —— 请在弹出的浏览器窗口里登录 Epic 账号' 'err' }
            else { Set-Status '就绪' 'info' }
        }
        $script:HadFatal = $false
    }

    # ---- 辅助进程：登录检测（未登录时每 5 秒一次）----
    foreach ($e in @(Get-Event -SourceIdentifier 'FabWhoOut' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.ok) {
            $script:LoggedIn = $true
            $name = if ($o.name) { $o.name } else { '已登录' }
            $script:LoginWaitSec = 0
            Hide-LoginHint
            Restore-TopMostAfterLogin
            Set-Status "已登录 Epic：$name" 'ok'
            Add-Log "登录成功：$name" 'ok'
            $script:BtnBrowser.Text = '打开浏览器'
            Set-Busy $false
            # 登录成功后自动重扫一次，把「需要先登录」换成真实归属
            Start-Sleep -Milliseconds 300
            if (-not $script:Busy) { Start-Run '--scan' '正在刷新批次' }
        }
    }
    foreach ($e in @(Get-Event -SourceIdentifier 'FabWhoExit' -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }

    # ---- 辅助进程：打开登录页 ----
    foreach ($e in @(Get-Event -SourceIdentifier 'FabLoginOut' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o.ok -and $o.error) { Add-Log "打开登录页失败：$($o.error)" 'err' }
    }
    foreach ($e in @(Get-Event -SourceIdentifier 'FabLoginExit' -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }

    # ---- 辅助进程：检查更新 ----
    foreach ($e in @(Get-Event -SourceIdentifier 'FabUpdOut' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $manual = $script:UpdManual
        $script:UpdManual = $false
        if (-not $o.ok) {
            # 后台那次查不到就安静跳过（离线、GitHub 不通都算正常，不能吓用户）；
            # 用户自己点的那次要给个说法，否则他以为按钮坏了
            if ($manual) {
                Add-Log "检查更新失败：$($o.error)（不影响正常领取）" 'warn'
                Set-Status '检查更新失败（多半是网络不通或 GitHub 访问不了）' 'warn'
            }
        } elseif (-not $o.update) {
            $script:UpdLocal = [string]$o.local
            if ($manual) {
                Add-Log "已经是最新版本（v$($o.local)）" 'ok'
                Set-Status "已经是最新版本（v$($o.local)）" 'ok'
            }
        } else {
            $script:UpdVer   = [string]$o.remote
            $script:UpdLocal = [string]$o.local
            $script:UpdNotes = [string]$o.notes
            Add-Log "发现新版本 v$($o.remote)（当前 v$($o.local)）" 'head'
            if ($o.notes) { Add-Log "  更新内容：$($o.notes)" 'head' }
            Add-Log '  点上方黄色提示条即可更新，下载完程序会自己重启。' 'head'
            if (-not $script:LblHint.Visible) { Show-UpdateHint }
        }
    }
    foreach ($e in @(Get-Event -SourceIdentifier 'FabUpdExit' -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }

    # ---- 辅助进程：下载新版本 ----
    foreach ($e in @(Get-Event -SourceIdentifier 'FabUpdApplyOut' -ErrorAction SilentlyContinue)) {
        $line = $e.SourceEventArgs.Data
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.ok) {
            Add-Log "新版本 v$($o.version) 已下载（$($o.count) 个文件），正在重启程序…" 'ok'
            Set-Status '更新已就绪，正在重启程序…' 'ok'
            [System.Windows.Forms.Application]::DoEvents()
            # 剩下的交给它自己拉起的独立进程：等这个界面退出→覆盖文件→重开。
            $form.Close()
            return
        }
        Add-Log "更新失败：$($o.error)（不影响正常领取）" 'err'
        Set-Status '更新失败（不影响正常领取）' 'err'
        if ($script:UpdVer) { Show-UpdateHint }   # 让用户还能再点一次
    }
    foreach ($e in @(Get-Event -SourceIdentifier 'FabUpdApplyExit' -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }
}

# ================= 界面 =================

$fontUI  = New-Object System.Drawing.Font('微软雅黑', 9)
$fontBig = New-Object System.Drawing.Font('微软雅黑', 12, [System.Drawing.FontStyle]::Bold)
$fontHd  = New-Object System.Drawing.Font('微软雅黑', 10, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Fab 限时免费领取助手'
$form.ClientSize    = New-Object System.Drawing.Size(780, 660)
$form.MinimumSize   = New-Object System.Drawing.Size(680, 600)
$form.StartPosition = 'CenterScreen'
$form.Font          = $fontUI
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.BackColor     = [System.Drawing.Color]::White
# 图标缺失/损坏不能让整个程序起不来，读不到就退回系统默认
try {
    if (Test-Path $IconFile) { $form.Icon = New-Object System.Drawing.Icon($IconFile) }
    else { $form.Icon = [System.Drawing.SystemIcons]::Application }
} catch { $form.Icon = [System.Drawing.SystemIcons]::Application }

# --- 顶部：状态 + 按钮 ---
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Fab 限时免费领取助手'
$lblTitle.Font = $fontBig
$lblTitle.Location = New-Object System.Drawing.Point(18, 14)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '自动领取 fab.com 上轮换的限时免费资产（原价收费、限时 100% 折扣）'
if ($script:AppVer) { $lblSub.Text += "　　v$($script:AppVer)" }
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 130)
$lblSub.Location = New-Object System.Drawing.Point(20, 42)
$lblSub.AutoSize = $true
$form.Controls.Add($lblSub)

$script:BtnBrowser = New-Object System.Windows.Forms.Button
$script:BtnBrowser.Text = '打开浏览器'
$script:BtnBrowser.Size = New-Object System.Drawing.Size(96, 30)
$script:BtnBrowser.Anchor = 'Top,Right'
$script:BtnBrowser.FlatStyle = 'System'
$form.Controls.Add($script:BtnBrowser)

$btnDetail = New-Object System.Windows.Forms.Button
$btnDetail.Text = '详细日志'
$btnDetail.Size = New-Object System.Drawing.Size(96, 30)
$btnDetail.Anchor = 'Top,Right'
$form.Controls.Add($btnDetail)

$lblStatus = New-Object System.Windows.Forms.Label
$script:LblStatus = $lblStatus
$lblStatus.Text = '● 正在初始化…'
$lblStatus.Font = $fontHd
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblStatus.Location = New-Object System.Drawing.Point(20, 76)
$lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

$script:LblHint = New-Object System.Windows.Forms.Label
$script:LblHint.Text = ''
$script:LblHint.Font = $fontUI
$script:LblHint.ForeColor = [System.Drawing.Color]::FromArgb(120, 75, 0)
$script:LblHint.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 220)
$script:LblHint.BorderStyle = 'FixedSingle'
$script:LblHint.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
$script:LblHint.Anchor = 'Top,Left,Right'
$script:LblHint.AutoSize = $false
$script:LblHint.TextAlign = 'MiddleLeft'
$script:LblHint.Visible = $false
$form.Controls.Add($script:LblHint)
# 点提示条 = 把登录窗口重新调到前面。用户很容易把浏览器窗口弄丢，
# 而"点这条提示"比"去别处找某个按钮"更符合直觉。
# 挂着"发现新版本"的时候，点它就是更新 —— 同一块地方，一次只挂一件事。
$script:LblHint.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:LblHint.Add_Click({
    if ($script:HintIsUpdate) { Invoke-Update; return }
    if (-not $script:LoggedIn) { Invoke-Login }
})

# --- 批次列表 ---
$script:LblBatch = New-Object System.Windows.Forms.Label
$script:LblBatch.Text = '当前批次：正在获取…'
$script:LblBatch.Font = $fontHd
$script:LblBatch.Location = New-Object System.Drawing.Point(20, 134)
$script:LblBatch.AutoSize = $true
$form.Controls.Add($script:LblBatch)

$script:LstBatch = New-Object System.Windows.Forms.ListView
$script:LstBatch.View = 'Details'
$script:LstBatch.FullRowSelect = $true
$script:LstBatch.GridLines = $false
$script:LstBatch.HeaderStyle = 'Nonclickable'
$script:LstBatch.MultiSelect = $false
$script:LstBatch.HideSelection = $false
$script:LstBatch.Anchor = 'Top,Left,Right'
[void]$script:LstBatch.Columns.Add('资产名称', 480)
[void]$script:LstBatch.Columns.Add('状态', 210)
$form.Controls.Add($script:LstBatch)

# --- 领取按钮 ---
$script:BtnClaim = New-Object System.Windows.Forms.Button
$script:BtnClaim.Text = '一键领取'
$script:BtnClaim.Font = New-Object System.Drawing.Font('微软雅黑', 11, [System.Drawing.FontStyle]::Bold)
$script:BtnClaim.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$script:BtnClaim.ForeColor = [System.Drawing.Color]::White
$script:BtnClaim.FlatStyle = 'Flat'
$script:BtnClaim.FlatAppearance.BorderSize = 0
$script:BtnClaim.Anchor = 'Top'
$form.Controls.Add($script:BtnClaim)

$script:BtnScan = New-Object System.Windows.Forms.Button
$script:BtnScan.Text = '刷新批次'
$script:BtnScan.Anchor = 'Top'
$form.Controls.Add($script:BtnScan)

# --- 每天自动 ---
$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = '自动领取（换批时自动动手，平时不启动浏览器）'
$chk.Location = New-Object System.Drawing.Point(22, 0)
$chk.AutoSize = $true
$form.Controls.Add($chk)

# --- 开机自动检查 ---
# 现有的自动领取靠计划任务每天 22:35 跑一次。电脑那个点没开（比如下班就关机、
# 或者笔记本不在家）就永远轮不到，这批也就错过了。加一个"登录时"触发器补上：
# 开机后 auto-claim.cmd 会先问一句「到点了没」，没到点直接退出，无窗口无弹窗。
# 两个触发器同时存在，各管各的场景。
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '开机自动检查'
$chkAuto.AutoSize = $true
$chkAuto.Enabled = $false      # 没开自动领取时它没有意义，见 $chk 的勾选处理
$form.Controls.Add($chkAuto)

# --- 窗口置顶 ---
# 默认勾上：程序启动后有一段要等用户去浏览器里登录，窗口一旦被别的程序挡住，
# 不熟悉电脑的人就找不回来了。置顶能直接免掉这个问题。
# 但登录时它会反过来挡路（浏览器窗口会被压在置顶窗口后面），
# 所以登录期间会临时取消、登录成功后自动恢复，见 Suspend-TopMostForLogin。
$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = '窗口置顶'
$chkTop.AutoSize = $true
$chkTop.Checked = $true
$form.Controls.Add($chkTop)
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })
$form.TopMost = $true

# --- 运行记录 ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '运行记录'
$lblLog.Font = $fontHd
$lblLog.AutoSize = $true
$form.Controls.Add($lblLog)

$script:Rtb = New-Object System.Windows.Forms.RichTextBox
$script:Rtb.ReadOnly = $true
$script:Rtb.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 251)
$script:Rtb.BorderStyle = 'FixedSingle'
$script:Rtb.Font = $fontUI
$script:Rtb.Anchor = 'Top,Left,Right,Bottom'
$script:Rtb.WordWrap = $false
$script:Rtb.ScrollBars = 'Vertical'
$script:Rtb.DetectUrls = $false
$form.Controls.Add($script:Rtb)

$btnClaimed = New-Object System.Windows.Forms.Button
$btnClaimed.Text = '已领取记录'
$btnClaimed.Anchor = 'Bottom,Left'
$form.Controls.Add($btnClaimed)

# 手动查更新的入口。启动时那次自动检查是静默的 —— 国内直连 GitHub 经常不通，
# 静默失败的话这个功能等于不存在；留个按钮，至少点了能看到失败原因。
$btnUpdCheck = New-Object System.Windows.Forms.Button
$btnUpdCheck.Text = '检查更新'
$btnUpdCheck.Anchor = 'Bottom,Left'
$form.Controls.Add($btnUpdCheck)
$btnUpdCheck.Add_Click({ Start-UpdateCheck -Manual })

# --- 自适应布局 ---
function Update-Layout {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $pad = 20
    $inner = $w - $pad * 2

    $script:BtnBrowser.Location = New-Object System.Drawing.Point(($w - $pad - 200), 16)
    $btnDetail.Location         = New-Object System.Drawing.Point(($w - $pad - 96), 16)

    $script:LblHint.Location = New-Object System.Drawing.Point($pad, 100)
    $script:LblHint.Size     = New-Object System.Drawing.Size($inner, 26)

    $script:LstBatch.Location = New-Object System.Drawing.Point($pad, 158)
    $script:LstBatch.Size     = New-Object System.Drawing.Size($inner, 150)
    $script:LstBatch.Columns[0].Width = [Math]::Max(200, $inner - 230)
    $script:LstBatch.Columns[1].Width = 220

    $bw = 260
    $script:BtnClaim.Location = New-Object System.Drawing.Point((($w - $bw) / 2 - 60), 320)
    $script:BtnClaim.Size     = New-Object System.Drawing.Size($bw, 46)
    $script:BtnScan.Location  = New-Object System.Drawing.Point((($w - $bw) / 2 + 210), 324)
    $script:BtnScan.Size      = New-Object System.Drawing.Size(110, 38)

    $chk.Location = New-Object System.Drawing.Point(($pad + 2), 380)
    $chkTop.Location     = New-Object System.Drawing.Point(($w - $pad - 92), 380)
    $chkAuto.Location    = New-Object System.Drawing.Point(($w - $pad - 92 - 130), 380)

    $lblLog.Location  = New-Object System.Drawing.Point($pad, 414)
    $script:Rtb.Location = New-Object System.Drawing.Point($pad, 438)
    $logH = $h - 438 - 56
    if ($logH -lt 80) { $logH = 80 }
    $script:Rtb.Size     = New-Object System.Drawing.Size($inner, $logH)

    $btnClaimed.Location = New-Object System.Drawing.Point($pad, ($h - 44))
    $btnClaimed.Size     = New-Object System.Drawing.Size(120, 32)
    $btnUpdCheck.Location = New-Object System.Drawing.Point(($pad + 128), ($h - 44))
    $btnUpdCheck.Size     = New-Object System.Drawing.Size(120, 32)
}
$form.Add_Resize({ Update-Layout })
Update-Layout

# ================= 交互 =================

$script:HadFatal = $false

$script:BtnClaim.Add_Click({
    if ($script:Busy) { return }
    [void]$script:Rtb.Clear()
    $script:Items = [ordered]@{}
    $script:ListItems = @{}
    $script:LstBatch.Items.Clear()
    Add-Log '开始领取…' 'head'
    Start-Run '' '正在领取'
})

$script:BtnScan.Add_Click({
    if ($script:Busy) { return }
    [void]$script:Rtb.Clear()
    $script:Items = [ordered]@{}
    $script:ListItems = @{}
    $script:LstBatch.Items.Clear()
    $script:OkCount = 0
    Add-Log '正在刷新当前批次…' 'head'
    Start-Run '--scan' '正在刷新批次'
})

$script:BtnBrowser.Add_Click({
    if ($script:Busy) { return }
    if (-not (Ensure-Browser)) { return }
    if ($script:LoggedIn) {
        # 已登录：把 fab.com 打开。必须走 node 复用这个带调试端口的浏览器，
        # 不能用 Process.Start(url) —— 那会拉起系统默认浏览器，不是我们这个配置。
        if ($script:LoginProc -and -not $script:LoginProc.HasExited) { return }
        $script:LoginProc = Start-AuxNode -ScriptFile (Join-Path $Core 'open-login.mjs') -Tag 'FabLogin' -ExtraArgs '--fab'
        Set-Status '已在浏览器中打开 Fab' 'ok'
    } else {
        Invoke-Login
    }
})

$btnDetail.Add_Click({
    $latest = Get-ChildItem -Path $LogDir -Filter 'claim-*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Start-Process notepad.exe -ArgumentList "`"$($latest.FullName)`"" }
    elseif (Test-Path $RunLog) { Start-Process notepad.exe -ArgumentList "`"$RunLog`"" }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志。', 'Fab 领取助手', 'OK', 'Information') | Out-Null }
})

$btnClaimed.Add_Click({
    $f = New-Object System.Windows.Forms.Form
    $f.Text = '已领取记录'
    $f.ClientSize = New-Object System.Drawing.Size(560, 400)
    $f.StartPosition = 'CenterParent'
    $f.Font = $fontUI
    $f.Icon = $form.Icon

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.Dock = 'Fill'; $lv.FullRowSelect = $true
    [void]$lv.Columns.Add('资产名称', 300)
    [void]$lv.Columns.Add('领取时间', 150)
    [void]$lv.Columns.Add('授权', 90)
    $f.Controls.Add($lv)

    $rows = @()
    if (Test-Path $ClaimedJs) {
        try {
            $j = Get-Content $ClaimedJs -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $at = $p.Value.at
                $local = ''
                try { $local = ([datetime]$at).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $local = [string]$at }
                $rows += ,@([string]$p.Value.title, $local, [string]$p.Value.license)
            }
        } catch {}
    }
    $rows = $rows | Sort-Object { $_[1] } -Descending
    if (-not $rows.Count) {
        [void]$lv.Items.Add((New-Object System.Windows.Forms.ListViewItem('（还没有领取记录）')))
    } else {
        foreach ($r in $rows) {
            $lvi = New-Object System.Windows.Forms.ListViewItem($r[0])
            [void]$lvi.SubItems.Add($r[1])
            [void]$lvi.SubItems.Add($r[2])
            [void]$lv.Items.Add($lvi)
        }
    }
    [void]$f.ShowDialog($form)
})

# --- 每天自动领取：勾选即写计划任务 ---
$chk.Add_Click({
    if ($chk.Checked) {
        # 同名任务指向别处时先问一句，别默默把人家的旧任务顶掉
        $foreign = Get-TaskForeignPath
        if ($foreign) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "这台电脑上已经有一个同名的自动领取任务，它指向的是：`n`n$foreign`n`n" +
                "继续的话，会用本程序替换掉它（旧的就不再自动运行了）。`n`n要替换吗？",
                'Fab 领取助手', 'YesNo', 'Question')
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $chk.Checked = $false; return }
        }
        $out = & schtasks.exe /Create /TN $TaskName /TR "`"$AutoCmd`"" /SC DAILY /ST 22:35 /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            Add-Log '已开启自动领取（Windows 计划任务；平时只做一次秒级检查，换批后才真正动作）' 'ok'
            Set-Status '已开启自动领取' 'ok'
            $chkAuto.Enabled = $true
            # /F 重建会把触发器整个覆盖掉，所以开机自启得按用户的勾选状态补回去
            if ($chkAuto.Checked) { [void](Set-TaskLogonTrigger $true) }
        } else {
            $chk.Checked = $false
            Add-Log "开启自动领取失败：$out" 'err'
            [System.Windows.Forms.MessageBox]::Show("创建计划任务失败，可能需要管理员权限。`n`n$out", 'Fab 领取助手', 'OK', 'Warning') | Out-Null
        }
    } else {
        $null = & schtasks.exe /Delete /TN $TaskName /F 2>&1
        # 任务删了，触发器自然也没了。但保留勾选状态，重新开启时按它恢复。
        $chkAuto.Enabled = $false
        Add-Log '已关闭自动领取' 'warn'
        Set-Status '已关闭自动领取' 'warn'
    }
})

$chkAuto.Add_Click({
    if (-not (Set-TaskLogonTrigger $chkAuto.Checked)) {
        $chkAuto.Checked = -not $chkAuto.Checked   # 没成功就别让界面显示成已开启
        return
    }
    if ($chkAuto.Checked) {
        Add-Log '已开启开机自动检查：每次开机后做一次秒级检查，没到点就立刻退出，你感觉不到' 'ok'
        Set-Status '已开启开机自动检查' 'ok'
    } else {
        Add-Log '已关闭开机自动检查' 'warn'
        Set-Status '已关闭开机自动检查' 'warn'
    }
})

function Get-TaskEnabled {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $act = $t.Actions | Select-Object -First 1
        $exe = [string]$act.Execute
        # 只按名字判断会误判：旧版本可能在别的目录注册过同名任务（本机就是这样，
        # 指向 D:\111\fab-claimer\run-daily.cmd）。必须确认指向的是本程序。
        return ($exe -and $exe.StartsWith($AppRoot, [System.StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Get-TaskForeignPath {
    # 同名任务存在但指向别处时，返回那个路径，供提示用；否则返回 $null
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $exe = [string]($t.Actions | Select-Object -First 1).Execute
        if ($exe -and -not $exe.StartsWith($AppRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $exe }
    } catch {}
    return $null
}

# ---------- 开机自启：给计划任务加/摘一个「登录时」触发器 ----------
# 为什么不用 schtasks.exe：它一次只能建一种触发方式，选了登录触发就保不住每天 22:35 那次。
# 两个场景都要 —— 电脑常开的人靠每天那次，下班就关机的人靠开机这次 —— 所以走计划任务模块。
# 延迟 2 分钟：刚登录那会儿桌面和网络都还没就绪，这时去拉浏览器很容易失败。
function New-LogonTrigger {
    $t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    try { $t.Delay = 'PT2M' } catch {}   # 设不上也不影响用，只是可能早一点跑
    return $t
}

function Get-TaskLogonTrigger {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return [bool](@($task.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
    } catch { return $false }
}

function Set-TaskLogonTrigger([bool]$On) {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        # 先摘掉现存的登录触发器再按需加，免得反复开关堆出一串重复的
        $list = @(@($task.Triggers) | Where-Object { $_.CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' })
        if ($On) { $list += New-LogonTrigger }
        Set-ScheduledTask -TaskName $TaskName -Trigger @($list) -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Add-Log "设置开机自启失败：$($_.Exception.Message)" 'err'
        return $false
    }
}

# ---------- 自动领取的健康检查 ----------
# 计划任务是在没人看着的时候跑的，所以它失败必须能在下次打开界面时被发现。
# 以前它失败只往 logs\task.log 写一行，而那个文件除了「详细日志」按钮没人会点开，
# 于是自动领取可以静默失败几个月 —— "用户机器上没有浏览器"正是这样变成隐形故障的。
function Show-AutoClaimHealth {
    # 1) 上次是因为找不到/起不来浏览器而失败的。
    #    browser.ps1 在失败时留一张便条，成功时自己删掉，所以文件在即代表最近一次是坏的。
    $errFile = Join-Path $LogDir 'browser-error.txt'
    if (Test-Path -LiteralPath $errFile) {
        try {
            $t = [System.IO.File]::ReadAllText($errFile).Trim()
            if ($t) {
                Add-Log '上次自动领取没能启动浏览器：' 'err'
                foreach ($line in ($t -split "`r?`n")) { if ($line.Trim()) { Add-Log "  $line" 'err' } }
                Add-Log '自动领取目前是失效状态 —— 点「打开浏览器」按提示处理。' 'err'
            }
        } catch {}
    }

    # 2) 任务跑了但没正常结束（比如 claim.mjs 中途报错）。
    #    用 Get-ScheduledTaskInfo 拿类型化的整数，不要去解析 schtasks /V 的文本 ——
    #    那些标签是本地化的，中文系统上是「上次运行结果」，正则一碰就碎。
    try {
        $info = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Get-ScheduledTaskInfo -ErrorAction Stop
        $code = [int]$info.LastTaskResult
        # 0 = 成功；267011/0x41303 = 还没运行过；267009/0x41301 = 正在运行
        if ($code -ne 0 -and $code -ne 267011 -and $code -ne 267009) {
            Add-Log "注意：上次自动领取没有正常结束（结果码 $code）。点「详细日志」看 logs\task.log。" 'warn'
        }
    } catch {}
}

# --- 定时器：收事件、拖住 UI 直到结束 ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({ Drain-ProcessEvents })
$timer.Start()

# 未登录时每 5 秒探一次登录态；登录成功后 Check-LoginNow 自己就不再发起了
$loginTimer = New-Object System.Windows.Forms.Timer
$loginTimer.Interval = 5000
$loginTimer.Add_Tick({ Check-LoginNow })
$loginTimer.Start()

$form.Add_FormClosing({
    $timer.Stop()
    $loginTimer.Stop()
    # 必须清掉所有子进程，否则 node 会在后台留着（尤其 whoami 每 5 秒一次）
    # 注意**不要**把 --commit 那个进程算进来：它本来就该活过本进程，
    # 干的就是"等界面退出→覆盖文件→重开"这件事。
    foreach ($p in @($script:Proc, $script:WhoProc, $script:LoginProc, $script:UpdProc, $script:UpdApplyProc)) {
        if ($p -and $p.HasExited -eq $false) { try { $p.Kill() } catch {} }
    }
})

$form.Add_Shown({
    $chk.Checked = Get-TaskEnabled
    # 查更新放最前面：它是个后台进程，不挡后面的启动流程，早点发出去早点有结果
    Start-UpdateCheck
    $chkAuto.Enabled = $chk.Checked
    $chkAuto.Checked = Get-TaskLogonTrigger   # 按计划任务里实际有没有登录触发器来显示
    $foreign = Get-TaskForeignPath
    if ($foreign) {
        Add-Log "注意：本机已有同名的自动领取计划任务，但指向别的位置：$foreign" 'warn'
        Add-Log '勾选「每天自动领取」会用本程序替换它；取消勾选会把它删掉。' 'warn'
    }
    # 先看上次自动领取是不是悄悄失败了，再开始启动浏览器
    Show-AutoClaimHealth
    Set-Status '正在启动浏览器…' 'run'
    [System.Windows.Forms.Application]::DoEvents()
    # 用户可能在这里手动指定浏览器；指定成功就继续跑扫描，不用他再点一次
    if (-not (Ensure-Browser)) { return }
    Start-Run '--scan' '正在检查'
})

[void]$form.ShowDialog()
$timer.Stop()
$loginTimer.Stop()
