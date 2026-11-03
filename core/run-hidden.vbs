' run-hidden.vbs -- start auto-claim.cmd without any console window.
'
' Why this exists: a scheduled task whose action is a .cmd gets a console window
' in the user's session, so it flashes once per trigger. wscript.exe is a
' GUI-subsystem host with no console of its own, and WScript.Shell.Run with
' window style 0 (SW_HIDE) starts the child with no window either -- the whole
' chain (cmd -> powershell -> node) stays invisible.
'
' bWaitOnReturn = True, so auto-claim.cmd's exit code reaches Task Scheduler
' unchanged and the GUI's health check (LastTaskResult) keeps working.
'
' Keep this file ASCII + CRLF, exactly like auto-claim.cmd.

Option Explicit

Dim fso, sh, here, cmd, rc

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd  = """" & fso.BuildPath(here, "auto-claim.cmd") & """"

rc = sh.Run(cmd, 0, True)
WScript.Quit rc
