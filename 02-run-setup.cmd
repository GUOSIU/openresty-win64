@echo off
rem ---------------------------------------------------------------------------
rem  02-run-setup.cmd - STEP 2 of 3: install MSYS2 + MinGW toolchain in THIS
rem  sandbox session.
rem
rem  Why not double-click setup-msys2.ps1?
rem    * the Windows client default execution policy is Restricted -> a plain
rem      .ps1 launch is refused and the window closes before you can read it;
rem    * a script that ends with `exit` terminates the whole PowerShell host.
rem
rem  This wrapper uses -ExecutionPolicy Bypass and -NoExit; setup-msys2.ps1
rem  keeps a full transcript in setup-log.txt next to it. Arguments are
rem  forwarded, e.g.
rem      02-run-setup.cmd -PacmanMirror https://mirrors.tuna.tsinghua.edu.cn/msys2
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"
rem UTF-8 code page so Chinese never turns into mojibake
chcp 65001 >nul

echo ============================================================
echo  OpenResty 1.31.8.1 x64 - STEP 2/3: MSYS2 setup
echo  Full log: %~dp0log\setup-<timestamp>.txt
echo  The window stays open when it finishes; close it manually.
echo ============================================================
echo.

rem Optional proxy helper. Either file name works, so renaming it to
rem 00-set-clash-proxy.cmd is fine.
set "PROXY=%~dp0set-clash-proxy.cmd"
if exist "%~dp000-set-clash-proxy.cmd" set "PROXY=%~dp000-set-clash-proxy.cmd"
if exist "%PROXY%" call "%PROXY%"
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0setup-msys2.ps1" %*

rem Backstop: if PowerShell did exit (fatal error before the script ran, or you
rem typed 'exit'), keep this window open so the output can still be read.
echo.
echo [cmd] PowerShell has exited. Press any key to close this window.
pause >nul
