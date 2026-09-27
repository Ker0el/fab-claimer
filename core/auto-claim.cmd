@echo off
rem Auto claim entry for the Windows scheduled task. Must stay ASCII + CRLF.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "CORE=%~dp0"
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs"
set "LOG=%ROOT%\logs\task.log"

echo. >> "%LOG%"
echo [%date% %time%] === auto claim start === >> "%LOG%"

rem 0) Time gate: ask claim.mjs whether the next batch is due yet (exit 2 = not yet).
rem    Must run BEFORE any browser launch, so idle days stay completely silent.
set "FAB_DATA=%ROOT%"
"%CORE%node.exe" "%CORE%claim.mjs" --due >> "%LOG%" 2>&1
if errorlevel 2 exit /b 0

rem 1) Resolve and launch a browser.
rem    This used to be a hardcoded list of 5 Chrome/Edge paths copied into this
rem    very file. Two consequences, both bad:
rem      - it ignored settings.json, so a browser the user picked by hand in the
rem        GUI (Brave, Vivaldi, a portable Chrome) was invisible to the task;
rem      - when it found nothing it just logged one line here and exited 1, and
rem        nothing ever reads task.log, so auto-claim could fail silently for
rem        months without the user finding out.
rem    Now there is exactly one implementation, browser.ps1, shared with the GUI.
rem    On success it leaves a running browser and writes the port to cdp-port.txt;
rem    on failure it writes logs\browser-error.txt, which the GUI surfaces.
rem    -WindowStyle Hidden so the scheduled task never flashes a console window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%CORE%browser.ps1" -Ensure >> "%LOG%" 2>&1
if errorlevel 1 goto nobrowser

rem The port can move off 9222 if some other program was holding it.
set "PORT=9222"
if exist "%CORE%cdp-port.txt" set /p PORT=<"%CORE%cdp-port.txt"
set "FAB_CDP=http://127.0.0.1:%PORT%"
echo [%date% %time%] browser ready on port %PORT% >> "%LOG%"

"%CORE%node.exe" "%CORE%claim.mjs" >> "%LOG%" 2>&1
echo [%date% %time%] === done (exit %ERRORLEVEL%) === >> "%LOG%"
exit /b 0

:nobrowser
echo [%date% %time%] [x] no usable browser - see logs\browser-error.txt >> "%LOG%"
exit /b 1
