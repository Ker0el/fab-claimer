; ============================================================================
;  Fab 限时免费领取助手 —— Inno Setup 打包脚本
;
;  ★ 不要直接编译本文件。入口是 installer\build.ps1：
;    它先把要发布的文件挑到一个干净的暂存目录 _stage\（profile\ 绝不在里面），
;    再调 ISCC 编译本脚本。直接编译会从 ..\ 取材，把作者的登录态一起打进去。
; ============================================================================

#define AppName "Fab 限时免费领取助手"
#define AppExeName "Fab领取助手.exe"
#define AppPublisher "Ker0el"
#define AppURL "https://github.com/Ker0el/fab-claimer"
; 版本号由 build.ps1 用 /DAppVersion=1.0.2 传进来（它从 version.json 读）
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; ---------------------------------------------------------------------------
;  ★★ 编译期硬闸 ★★
;  暂存目录里一旦出现这些东西，直接让编译失败，而不是打出一个"能装但有毒"的包。
;  profile\ 里是**真实的 Epic 登录凭据**（Default\Network\Cookies、
;  Default\Login Data、Default\Web Data）—— 和"绝不能进公开仓库"是同一件事：
;  安装包一旦发出去，任何人都能拿着这份登录态登进账号，而且撤不回来。
;  这些检查放在这里，是因为"我改了排除规则"和"排除规则真的生效了"是两回事 ——
;  必须让机器来判，不能靠人记得看一眼。
; ---------------------------------------------------------------------------
#if DirExists(AddBackslash(SourcePath) + "_stage\profile")
  #error 暂存目录里出现了 profile\ —— 里面有 Epic 登录凭据，停下，别打包
#endif
#if FileExists(AddBackslash(SourcePath) + "_stage\core\settings.json")
  #error 暂存目录里出现了 core\settings.json（用户指定的浏览器 / 端口），不该发
#endif
#if FileExists(AddBackslash(SourcePath) + "_stage\core\cdp-port.txt")
  #error 暂存目录里出现了 core\cdp-port.txt（运行期状态），不该发
#endif
#if !FileExists(AddBackslash(SourcePath) + "_stage\version.json")
  #error 暂存目录里没有 version.json —— 程序靠它判断版本、做自更新
#endif

[Setup]
; AppId 一旦发布就不能再改 —— 它决定"这是升级"还是"又装了一个"
AppId={{8F3C1D62-5A7E-4B9C-9E21-7D4A6F0B2C58}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} 安装程序

; ★ 装到 %LOCALAPPDATA%\Programs，不装 Program Files。三个原因，缺一不可：
;   1. 程序把浏览器 profile、日志、领取记录都写在程序目录**旁边**。装到
;      Program Files 的话这些位置不可写 —— Chrome 存不下登录态，程序直接废掉。
;   2. 自更新要往 core\ 里写文件。装 Program Files 就得每次 UAC 提权，
;      而自更新是后台跑的，弹不出提权框，等于永远更新不了。
;   3. 不需要管理员权限，双击就能装完 —— 目标用户多半不熟悉电脑。
;   （升级时也要守住这一点：绝对不要为了"更规范"改成 {autopf}。）
DefaultDirName={localappdata}\Programs\FabClaimer
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=FabClaimer-Setup-{#AppVersion}
SetupIconFile=_stage\core\fab.ico
UninstallDisplayIcon={app}\core\fab.ico
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 装/升级时程序若在运行，让 Inno 直接把它关掉（靠下面的 AppMutex 认人）
CloseApplications=yes
RestartApplications=no
; 和 gui.ps1 里那个互斥体**必须完全一致**，否则认不出"程序正在运行"
AppMutex=FabClaimerGui
MinVersion=10.0

[Languages]
Name: "cn"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; 只搬暂存目录。它是 build.ps1 挑出来的白名单副本，
; 所以这里不需要（也不该）再写一堆 Excludes —— 排除规则的真正落实点在 build.ps1。
Source: "_stage\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";          Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}";    Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只清我们自己产生的日志。profile\ / claimed.json 是用户的东西，
; 留还是删交给下面的卸载提示问用户，别擅自处理。
Type: filesandordirs; Name: "{app}\logs"

[Code]
// 卸载时问一句要不要连登录状态一起删。
// 默认不删：profile\ 里有登录态，删了下次装回来还得重新登一次 Epic。
// 但不问就默默留一个几百兆的文件夹，用户也会觉得"卸载没卸干净"。
// 注意：这个钩子必须是 function ... : Boolean（返回 False 会中止卸载），
// 不是 procedure —— 写成 procedure 编译器会报 Invalid prototype。
function InitializeUninstall(): Boolean;
var
  Reply: Integer;
begin
  Result := True;

  // ★ 静默卸载（/SILENT、/VERYSILENT）绝不能弹窗。
  // 实测踩过：/VERYSILENT 下 MsgBox 照样会显示，没人点它就永远停在那儿 ——
  // 卸载进程挂着不动，用户以为"卸载坏了"。
  // 静默时一律保留用户数据：不删总比误删安全，反正一个安装包能覆盖回去。
  if UninstallSilent() then
    exit;

  if not DirExists(ExpandConstant('{app}\profile')) then
    exit;

  Reply := MsgBox('是否连登录状态和领取记录一起删除？' + #13#10 + #13#10 +
                  '选「是」：删掉 profile 文件夹，下次装上要重新登录 Epic。' + #13#10 +
                  '选「否」：保留登录状态，下次装回来不用重新登录。',
                  // ★ 默认按钮要放在「否」上。
                  // Inno 的 MsgBox 默认选中第一个按钮，而 /SUPPRESSMSGBOXES 静默卸载时
                  // 就是直接采用默认值 —— 默认「是」等于"静默卸载会顺手删掉用户的登录态"。
                  // 删用户数据必须是用户主动选的，不能是默认。
                  mbConfirmation, MB_YESNO or MB_DEFBUTTON2);
  if Reply = IDYES then
  begin
    DelTree(ExpandConstant('{app}\profile'), True, True, True);
    DelTree(ExpandConstant('{app}\logs'), True, True, True);
    DeleteFile(ExpandConstant('{app}\claimed.json'));
    DeleteFile(ExpandConstant('{app}\next-check.json'));
  end;
end;
