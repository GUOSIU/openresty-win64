@echo off
rem ---------------------------------------------------------------------------
rem  03-run-build.cmd - STEP 3 of 3: compile and package OpenResty for x64.
rem
rem    03-run-build.cmd                    (jobs = CPU count)
rem    03-run-build.cmd -Jobs 4            (options are passed to build-all.ps1)
rem    03-run-build.cmd -Version 1.32.1.1 -OpenSSLVer 3.6.0   (new release)
rem
rem  Full log: build-log.txt / build-output.log (written by the script itself).
rem  Requires STEP 2 in the SAME sandbox session (MSYS2 lives in the VM only).
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"
rem UTF-8 code page so Chinese never turns into mojibake
chcp 65001 >nul

echo ============================================================
echo  OpenResty 1.31.8.1 x64 - STEP 3/3: build
echo  Full log: %~dp0log\build-<timestamp>.txt
echo  Expect 15-40 minutes. Do not close the sandbox window.
echo ============================================================
echo.

rem ---- checks that run BEFORE PowerShell, so they are visible even if the
rem ---- script itself is blocked by the execution policy
if not exist "%~dp0build-all.ps1" (echo [ERROR] build-all.ps1 is missing next to this .cmd & echo. & pause & exit /b 1)
if not exist "%~dp0build-openresty.sh" (echo [ERROR] build-openresty.sh is missing next to this .cmd & echo. & pause & exit /b 1)
if not exist "%LOCALAPPDATA%\msys64\usr\bin\bash.exe" (echo [ERROR] MSYS2 is not installed in THIS sandbox session. & echo         Windows Sandbox is disposable: the msys64 folder died with the last window. & echo         Run 02-run-setup.cmd first, then 03-run-build.cmd, without closing the sandbox. & echo. & pause & exit /b 1)

rem Optional proxy helper. Either file name works, so renaming it to
rem 00-set-clash-proxy.cmd is fine.
set "PROXY=%~dp0set-clash-proxy.cmd"
if exist "%~dp000-set-clash-proxy.cmd" set "PROXY=%~dp000-set-clash-proxy.cmd"
if exist "%PROXY%" call "%PROXY%"
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0build-all.ps1" %*

rem Backstop: if PowerShell did exit (fatal error before the script ran, or you
rem typed 'exit'), keep this window open so the output can still be read.
echo.
echo [cmd] PowerShell has exited. Press any key to close this window.
pause >nul
