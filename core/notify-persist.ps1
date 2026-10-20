# Fab 领取助手：右下角常驻通知窗口
#
# 系统 toast 几秒就自己消失，验证码提示很容易错过（用户 2026-10-20 要求常驻）。
# 这个脚本画一个右下角的小窗口：不点就一直留着；点一下关掉；
# 点「打开浏览器」把浏览器窗口调回前台。
#
# 由 claim.mjs 用 `cmd /c start` 拉起（必须是脱离父进程的，否则 Node 一退出窗口就没了）：
#   -Payload <json>     一次性的参数文件（UTF-8 JSON），字段：
#                         title / text / group / parentPid / settings / token
#                       用文件传参是为了绕开命令行引号和中文转义；
#                       脚本读完就把它删掉。
#   -Close              只关闭指定 Group 的通知，不显示窗口（程序判断"验证码过了"时用）
#   -Group              同组通知只留一个（新通知会先关掉旧的）
#   -ParentPid          给了就盯着这个进程：它一退出，窗口自动关闭
#                       （验证码那种"过程中提示"用；最终汇总不传，让它一直留着）
#   -Token              关闭信号的文件名后缀：%TEMP%\fab-notify-<token>.dismiss 一出现就关
#   -Title / -Text / -Settings   也可以直接传，调试用
#
# 注意：本文件必须是 UTF-8 with BOM，PS 5.1 才会按 UTF-8 读中文。

param(
    [string]$Payload = '',
    [switch]$Close,
    [string]$Title = 'Fab 领取',
    [string]$Text = '',
    [string]$Group = 'default',
    [int]$ParentPid = 0,
    [string]$Settings = '',
    [string]$Token = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 不抢焦点、不进 Alt-Tab 的小窗口
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;

public class FabNotifyForm : Form
{
    // 有公开成员才不会被 PS 警告"生成的类型未定义公共方法或属性"（无实际用途）
    public static void Noop() { }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}
"@

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class FabWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte b, byte s, uint f, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }

    // 关掉标题完全相同的窗口：同组通知不叠罗汉
    public static void CloseByTitle(string title)
    {
        EnumWindows((h, l) =>
        {
            var sb = new StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (sb.ToString() == title) PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
    }

    // 按进程号找它的主窗口（Chrome 的类名是 Chrome_WidgetWin_1）
    public static IntPtr FindMainWindow(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((h, l) =>
        {
            uint wp;
            GetWindowThreadProcessId(h, out wp);
            if (wp != pid || !IsWindowVisible(h)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
            if (area <= 0) return true;
            var cs = new StringBuilder(128);
            GetClassNameW(h, cs, 128);
            if (cs.ToString().StartsWith("Chrome_WidgetWin"))
            {
                found = h;
                return false;
            }
            if (found == IntPtr.Zero && area > bestArea) { found = h; bestArea = area; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

$myTitle = "FabNotifier|$Group"

# 参数文件：命令行只传一个 ASCII 路径，中文/换行/引号都在 JSON 里，不会被打散
if ($Payload -and (Test-Path -LiteralPath $Payload)) {
    try {
        $j = Get-Content -LiteralPath $Payload -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $j.title)     { $Title = [string]$j.title }
        if ($null -ne $j.text)      { $Text = [string]$j.text }
        if ($null -ne $j.group)     { $Group = [string]$j.group; $myTitle = "FabNotifier|$Group" }
        if ($null -ne $j.parentPid) { $ParentPid = [int]$j.parentPid }
        if ($null -ne $j.settings)  { $Settings = [string]$j.settings }
        if ($null -ne $j.token)     { $Token = [string]$j.token }
    } catch {}
    Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
}

if ($Close) {
    [FabWin32]::CloseByTitle($myTitle)
    exit
}

[FabWin32]::CloseByTitle($myTitle)   # 同组旧通知先关掉

# 正文太长就截断，别把窗口撑得满屏
$showText = [string]$Text
if ($showText.Length -gt 420) { $showText = $showText.Substring(0, 420) + '…' }

# 粗略估一下行数（9pt 微软雅黑，440 宽大约一行 26 个汉字）
$lineCount = 0
foreach ($seg in ($showText -split "`n")) {
    $lineCount += [Math]::Max(1, [Math]::Ceiling($seg.Length / 26))
}
$lineCount = [Math]::Min([Math]::Max($lineCount, 2), 8)

$form = New-Object FabNotifyForm
$form.Text = $myTitle
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$form.Width = 440
$form.Height = 44 + (18 * $lineCount) + 40

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = [string]$Title
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(255, 183, 77)
$lblTitle.AutoSize = $false
$lblTitle.SetBounds(16, 12, 408, 24)

$lblText = New-Object System.Windows.Forms.Label
$lblText.Text = $showText
$lblText.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblText.ForeColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
$lblText.AutoSize = $false
$lblText.SetBounds(16, 40, 408, 18 * $lineCount)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '点窗口关闭'
$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
$hint.AutoSize = $false
$hint.SetBounds(16, $form.Height - 38, 140, 22)

$btnBrowser = New-Object System.Windows.Forms.Button
$btnBrowser.Text = '打开浏览器'
$btnBrowser.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$btnBrowser.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnBrowser.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$btnBrowser.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$btnBrowser.ForeColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$btnBrowser.SetBounds($form.Width - 16 - 100 - 8 - 76, $form.Height - 42, 100, 28)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '知道了'
$btnClose.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$btnClose.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$btnClose.ForeColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$btnClose.SetBounds($form.Width - 16 - 76, $form.Height - 42, 76, 28)

$form.Controls.Add($lblTitle)
$form.Controls.Add($lblText)
$form.Controls.Add($hint)
$form.Controls.Add($btnBrowser)
$form.Controls.Add($btnClose)

# 找浏览器窗口：既用来决定窗口放哪块屏，也用来实现「打开浏览器」
$browserWnd = [IntPtr]::Zero
if ($Settings -and (Test-Path $Settings)) {
    try {
        $sj = Get-Content $Settings -Raw | ConvertFrom-Json
        if ($sj.cdpPid) { $browserWnd = [FabWin32]::FindMainWindow([uint32]$sj.cdpPid) }
    } catch {}
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen
if ($browserWnd -ne [IntPtr]::Zero) {
    try { $screen = [System.Windows.Forms.Screen]::FromHandle($browserWnd) } catch {}
}
$wa = $screen.WorkingArea
$form.Left = $wa.Right - $form.Width - 16
$form.Top = $wa.Bottom - $form.Height - 16

# 点窗口任何地方都关掉
$form.Add_Click({ $form.Close() })
$lblTitle.Add_Click({ $form.Close() })
$lblText.Add_Click({ $form.Close() })
$hint.Add_Click({ $form.Close() })
$btnClose.Add_Click({ $form.Close() })

$btnBrowser.Add_Click({
    if ($browserWnd -ne [IntPtr]::Zero) {
        # 从后台进程调 SetForegroundWindow 会被前台锁挡掉，先补一次 Alt 上/下解锁
        [FabWin32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
        [FabWin32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [FabWin32]::SetForegroundWindow($browserWnd) | Out-Null
    }
    $form.Close()
})

# 自动关闭的两个条件：
#   ① 父进程（claim.mjs）退出 —— 正常结束、崩溃、被杀都适用（只有"过程中提示"才传 ParentPid）
#   ② 出现关闭信号文件 —— 验证码已经过了，程序主动让窗口收起来
$script:watchPid = $ParentPid
$script:dismissPath = ''
if ($Token) { $script:dismissPath = Join-Path $env:TEMP "fab-notify-$Token.dismiss" }
$script:formRef = $form

if ($ParentPid -gt 0 -or $script:dismissPath) {
    $watch = New-Object System.Windows.Forms.Timer
    $watch.Interval = 1000
    $watch.Add_Tick({
        $keep = $true
        if ($script:watchPid -gt 0) {
            try { [void][System.Diagnostics.Process]::GetProcessById($script:watchPid) }
            catch { $keep = $false }
        }
        if ($keep -and $script:dismissPath -and (Test-Path -LiteralPath $script:dismissPath)) { $keep = $false }
        if (-not $keep) { $script:formRef.Close() }
    })
    $watch.Start()
}

$form.Add_FormClosed({
    if ($script:dismissPath) { Remove-Item -LiteralPath $script:dismissPath -Force -ErrorAction SilentlyContinue }
})

[System.Windows.Forms.Application]::Run($form)
