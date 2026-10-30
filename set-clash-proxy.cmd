@echo off
rem ---------------------------------------------------------------------------
rem  set-clash-proxy.cmd - point THIS console at Clash, whether we run on the
rem  host or inside a Windows Sandbox VM.
rem
rem    host    : Clash listens on 127.0.0.1:7890
rem    sandbox : 127.0.0.1 is the sandbox itself; the host is the default
rem              gateway of the sandbox NAT (usually 172.x.x.1)
rem
rem  Probes 127.0.0.1 first, then the gateway, and exports HTTP_PROXY /
rem  HTTPS_PROXY / ALL_PROXY for this console only. Never fails the caller:
rem  an unreachable Clash just means "use the direct connection".
rem
rem  The WinINET (registry) proxy is written ONLY in the sandbox case, where it
rem  disappears with the VM. On the host your Internet Settings stay untouched.
rem
rem  NOTE: deliberately written as flat single-line `if` statements - batch
rem  files with LF-only line endings misparse multi-line ( ... ) blocks.
rem ---------------------------------------------------------------------------
set "CP_PORT=7890"
set "CP_ADDR="
set "CP_SANDBOX=0"

rem ---- 1) host case: 127.0.0.1 ------------------------------------------------
powershell.exe -NoProfile -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $a = $c.BeginConnect('127.0.0.1', %CP_PORT%, $null, $null); if (-not $a.AsyncWaitHandle.WaitOne(800)) { exit 1 }; $c.EndConnect($a); $c.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if not errorlevel 1 set "CP_ADDR=127.0.0.1"

rem ---- 2) sandbox case: default gateway ---------------------------------------
set "CP_GW="
powershell.exe -NoProfile -Command "Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1 | ForEach-Object { $_.NextHop }" > "%TEMP%\dsh-clash-gw.txt" 2>nul
set /p CP_GW=<"%TEMP%\dsh-clash-gw.txt"
del "%TEMP%\dsh-clash-gw.txt" >nul 2>&1

if defined CP_GW powershell.exe -NoProfile -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $a = $c.BeginConnect('%CP_GW%', %CP_PORT%, $null, $null); if (-not $a.AsyncWaitHandle.WaitOne(1500)) { exit 1 }; $c.EndConnect($a); $c.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if not defined CP_ADDR if defined CP_GW if not errorlevel 1 set "CP_ADDR=%CP_GW%"
if not "%CP_ADDR%"=="" if not "%CP_ADDR%"=="127.0.0.1" set "CP_SANDBOX=1"

if not defined CP_ADDR echo [proxy] WARN: Clash is not reachable on 127.0.0.1:%CP_PORT% or %CP_GW%:%CP_PORT% - direct connection.
if not defined CP_ADDR echo [proxy]       Sandbox users: enable Clash "Allow LAN" and allow inbound TCP %CP_PORT% from 172.16.0.0/12.
if not defined CP_ADDR exit /b 0

set "HTTP_PROXY=http://%CP_ADDR%:%CP_PORT%"
set "HTTPS_PROXY=%HTTP_PROXY%"
set "ALL_PROXY=socks5h://%CP_ADDR%:%CP_PORT%"
set "NO_PROXY=localhost,127.0.0.1,::1"
set "http_proxy=%HTTP_PROXY%"
set "https_proxy=%HTTPS_PROXY%"
set "all_proxy=%ALL_PROXY%"
set "no_proxy=%NO_PROXY%"

rem WinINET/IE proxy: makes Invoke-WebRequest and other .NET/WinINET clients
rem (the curl fallback in setup-msys2.ps1) honour the proxy. Sandbox only.
if "%CP_SANDBOX%"=="1" reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f >nul 2>&1
if "%CP_SANDBOX%"=="1" reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /t REG_SZ /d "%CP_ADDR%:%CP_PORT%" /f >nul 2>&1
if "%CP_SANDBOX%"=="1" reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyOverride /t REG_SZ /d "localhost;127.0.0.1;::1" /f >nul 2>&1

if "%CP_SANDBOX%"=="1" (echo [proxy] Clash at %CP_ADDR%:%CP_PORT% via the sandbox gateway, HTTP + SOCKS5) else (echo [proxy] Clash at %CP_ADDR%:%CP_PORT% on this machine, HTTP + SOCKS5, registry untouched)
exit /b 0
