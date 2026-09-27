@echo off
rem Fallback launcher -- use only if the main exe is blocked by security software.
rem Must stay ASCII + CRLF.
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gui.ps1"
exit
