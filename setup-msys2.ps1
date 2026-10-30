# setup-msys2.ps1  (v3)
# Install MSYS2 + MinGW-w64 toolchain inside the current Windows Sandbox session.
# Installs under %LOCALAPPDATA%\msys64 by default -> no elevation needed.
#
#   powershell -ExecutionPolicy Bypass -File .\setup-msys2.ps1
#   powershell -ExecutionPolicy Bypass -File .\setup-msys2.ps1 -Root D:\msys64
#
# Log next to this script: setup-log.txt (full transcript, survives the sandbox
# because that folder is the mapped host folder).
#
[CmdletBinding()]
param(
    [string] $Root         = (Join-Path $env:LOCALAPPDATA 'msys64'),
    [string] $InstallerUrl = 'https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-x86_64-latest.exe',
    # Optional pacman base mirror, e.g. https://mirrors.tuna.tsinghua.edu.cn/msys2
    # Prepended to the mirror lists so a slow official mirror can be bypassed.
    [string] $PacmanMirror = '',
    [switch] $NoProxy,
    [switch] $NoTranscript
)

# 'Continue', NOT 'Stop': in PowerShell 5.1 any native program that writes to
# stderr (curl's progress meter, pacman, gcc warnings) turns into a terminating
# NativeCommandError under Stop. We check $LASTEXITCODE explicitly instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---- UTF-8 console -----------------------------------------------------------
# Windows legacy tools (netsh, icacls, installer, ...) emit OEM bytes, MSYS2
# tools emit UTF-8, and PowerShell decodes native output with
# [Console]::OutputEncoding. When the two disagree you get mojibake (a CJK
# string encoded in GBK rendered as garbage). Force one encoding (UTF-8) for
# everything we print and capture.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding           = [Console]::OutputEncoding
} catch {
    Write-Host "UTF-8 console setup skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

function Convert-TranscriptToUtf8([string] $path) {
    # Start-Transcript on PS 5.1 writes UTF-16LE. Convert to UTF-8 **with BOM**
    # in every case: without the BOM, Notepad / cmd / Get-Content on a zh-CN
    # system decode the file as GBK and every Chinese character turns to garbage.
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 2) { return }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        else {
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        }
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- logs: .\log\setup-<yyyyMMdd-HHmmss>.txt, newest 20 kept ----------------
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $scriptDir 'log'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

Get-ChildItem -Path $logDir -Filter 'setup-*.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 20 |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

$logPath = Join-Path $logDir "setup-$stamp.txt"
$phase   = 'init'
$failed  = $false
$sw      = [System.Diagnostics.Stopwatch]::StartNew()

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Note($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }
function Fail($msg) { throw $msg }

function Invoke-Bash([string] $cmd) {
    Write-Host "`n$ $cmd" -ForegroundColor DarkYellow
    & $script:Bash -lc $cmd 2>&1 | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}

function Show-FailureInfo {
    param($err, [string]$hint = '')

    Write-Host "`n---------------- SETUP FAILED ----------------" -ForegroundColor Red
    Write-Host "phase      : $phase"                       -ForegroundColor Red
    Write-Host "message    : $($err.Exception.Message)"    -ForegroundColor Red
    if ($err.CategoryInfo) { Write-Host "category   : $($err.CategoryInfo.Category)" -ForegroundColor Red }
    if ($err.InvocationInfo) {
        Write-Host "location   : line $($err.InvocationInfo.ScriptLineNumber): $($err.InvocationInfo.Line.Trim())" -ForegroundColor Red
    }
    if ($err.ScriptStackTrace) { Write-Host "stack      :`n$($err.ScriptStackTrace)" -ForegroundColor DarkRed }
    Write-Host "elapsed    : $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min" -ForegroundColor Red
    if ($hint) { Write-Host "hint       : $hint" -ForegroundColor Yellow }

    Write-Host "`n--- diagnostics ---" -ForegroundColor Yellow
    Write-Host "install root : $Root $(if (Test-Path (Join-Path $Root 'usr\bin\bash.exe')) {'[bash ok]'} else {'[no bash.exe]'})"
    Write-Host "TEMP         : $env:TEMP $(if (Test-Path $env:TEMP) {'[ok]'} else {'[MISSING]'})"
    try { Write-Host "free C:      : $([math]::Round((Get-PSDrive C).Free / 1GB, 1)) GB" } catch { }
    Write-Host "HTTPS_PROXY  : $($env:HTTPS_PROXY)  HTTP_PROXY: $($env:HTTP_PROXY)  NO_PROXY: $($env:NO_PROXY)"
    Note "netsh winhttp output is skipped on purpose: it is localized (GBK on zh-CN) and not UTF-8 decodable"

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        Write-Host "`nconnectivity : curl -sS -o NUL -w '%{http_code}' https://github.com ..."
        try {
            $code = & $curl -sS --max-time 20 -o NUL -w '%{http_code}' 'https://github.com/' 2>&1
            Write-Host "               HTTP $code"
        } catch {
            Write-Host "               curl failed: $($_.Exception.Message)"
        }
    }

    Write-Host "`nlog: $logPath" -ForegroundColor Yellow
    Write-Host "Send this file back for analysis." -ForegroundColor Yellow
}

if (-not $NoTranscript) {
    try { Start-Transcript -Path $logPath -Force | Out-Null } catch { Write-Host "transcript disabled: $($_.Exception.Message)" }
}

try {
    # ------------------------------------------------------------ preflight
    $phase = 'preflight'
    Step "0. host prerequisites"
    Write-Host "OS             : $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Host "PS             : $($PSVersionTable.PSVersion)"
    Write-Host "ExecutionPolicy: LocalMachine=$((Get-ExecutionPolicy -Scope LocalMachine)) Process=$((Get-ExecutionPolicy -Scope Process))"
    Write-Host "Install root   : $Root"
    if ($NoProxy) {
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY, `
                    Env:http_proxy, Env:https_proxy, Env:all_proxy -ErrorAction SilentlyContinue
        Write-Host "Proxy          : cleared by -NoProxy (direct connection)"
    }
    Note "A red 'NativeCommandError' line is often just pacman writing to stderr; the exit code decides."

    $script:Bash = Join-Path $Root 'usr\bin\bash.exe'

    # ---------------------------------------------------------------- install
    if (Test-Path $script:Bash) {
        $phase = 'detect existing install'
        Step "1. MSYS2 already installed"
        Note $script:Bash
    }
    else {
        $phase = 'download installer'
        Step "1. downloading MSYS2 installer"
        $exe = Join-Path $env:TEMP 'msys2-installer.exe'
        Note "trying several official sources; progress bar suppressed on purpose"

        # GitHub release assets sit behind a CDN that can reset connections
        # mid-transfer (curl: (56) Recv failure) on some networks. repo.msys2.org
        # serves the same Qt IFW installer directly, so it is a real fallback.
        $sources = @(
            @{ Name = 'github.com';      Url = $InstallerUrl },
            @{ Name = 'repo.msys2.org';  Url = 'https://repo.msys2.org/distrib/msys2-x86_64-latest.exe' }
        )

        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $downloaded = $false

        # Escape hatch: if the installer was copied into this folder (e.g. fetched
        # on the host with a download manager), use it instead of the network.
        # Validate before trusting it: a truncated download or an HTML error page
        # saved as .exe would otherwise fail deep inside the Qt installer.
        $localExe = Join-Path $scriptDir 'msys2-x86_64-latest.exe'
        if (Test-Path $localExe) {
            $lsize = (Get-Item $localExe).Length
            $magic = ''
            try {
                $fs = [System.IO.File]::OpenRead($localExe)
                $head = New-Object byte[] 2
                $null = $fs.Read($head, 0, 2)
                $fs.Close()
                $magic = [System.Text.Encoding]::ASCII.GetString($head)
            } catch { }

            if ($lsize -gt 30MB -and $magic -eq 'MZ') {
                Note "using pre-downloaded installer: $localExe ($([math]::Round($lsize / 1MB, 1)) MB)"
                Copy-Item $localExe $exe -Force
                # A file that came through a mapped folder may carry the
                # Mark-of-the-Web; without this, the silent install can stall on
                # a SmartScreen prompt that nobody can click.
                Unblock-File $exe -ErrorAction SilentlyContinue
                $downloaded = $true
            }
            else {
                Note "ignoring $localExe : $([math]::Round($lsize / 1MB, 1)) MB, header '$magic' (need >30 MB and 'MZ')"
            }
        }

        if (-not $downloaded) {
            foreach ($src in $sources) {
                Remove-Item $exe -ErrorAction SilentlyContinue
                Note "source: $($src.Name)"
                Write-Host "url   : $($src.Url)"

                if (Test-Path $curl) {
                    # --http1.1 avoids HTTP/2 resets behind middleboxes,
                    # --retry-all-errors also retries exit 56 (receive failure),
                    # -C - resumes a partially written file.
                    & $curl -fL --http1.1 -C - --retry 5 --retry-all-errors --retry-delay 2 `
                           --connect-timeout 30 --max-time 1800 --no-progress-meter -o $exe $($src.Url)
                    $rc = $LASTEXITCODE
                }
                else {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    try {
                        Invoke-WebRequest -Uri $src.Url -OutFile $exe -UseBasicParsing -ErrorAction Stop
                        $rc = 0
                    }
                    catch {
                        Write-Host "  Invoke-WebRequest failed: $($_.Exception.Message)"
                        $rc = 1
                    }
                }

                if ($rc -eq 0 -and (Test-Path $exe)) {
                    $size = (Get-Item $exe).Length
                    if ($size -gt 30MB) {
                        Write-Host "downloaded     : $exe ($([math]::Round($size / 1MB, 1)) MB)"
                        $downloaded = $true
                        break
                    }
                    Write-Host "  incomplete: only $([math]::Round($size / 1MB, 1)) MB, trying next source"
                }
                else {
                    Write-Host "  failed (curl exit $rc; 56 = connection reset mid-transfer, 28 = timeout)"
                }
            }
        }

        if (-not $downloaded) {
            Fail "could not download the MSYS2 installer from any source. Exit 56/28 means the network is resetting large transfers; retry later, or pass -InstallerUrl <your mirror>."
        }

        $phase = 'silent install'
        Step "2. installing MSYS2 silently into $Root"
        # A leftover partial directory makes the Qt IFW installer refuse to install.
        if ((Test-Path $Root) -and -not (Test-Path $script:Bash)) {
            Note "removing incomplete previous install at $Root"
            Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Qt IFW expects forward slashes in --root (MSYS2's own example uses C:/msys64).
        $rootArg = $Root.Replace('\', '/')
        $argLine = "in --confirm-command --accept-messages --root `"$rootArg`""
        Write-Host "command        : `"$exe`" $argLine"
        $p = Start-Process -FilePath $exe -ArgumentList $argLine -Wait -PassThru -NoNewWindow
        Write-Host "installer exit : $($p.ExitCode)"
        if ($p.ExitCode -ne 0) {
            Fail "MSYS2 installer exit code $($p.ExitCode). Common causes: leftover directory, %TEMP% not writable, blocked download."
        }
        if (-not (Test-Path $script:Bash)) { Fail "installer reported success but $script:Bash is missing" }
    }

    # ---------------------------------------------------------------- pacman
    if ($PacmanMirror) {
        $phase = 'configure pacman mirror'
        Step "3.0 pointing pacman at $PacmanMirror"
        $m = $PacmanMirror.TrimEnd('/')
        # Single-quoted PowerShell strings keep $repo / $arch literal for bash.
        $mingwCmd = 'for f in /etc/pacman.d/mirrorlist.mingw64 /etc/pacman.d/mirrorlist.ucrt64 /etc/pacman.d/mirrorlist.clang64; do [ -f "$f" ] || continue; { printf "Server = {M}/mingw/$repo/\n"; cat "$f"; } > "$f.new" && mv "$f.new" "$f"; done'
        $msysCmd  = '{ printf "Server = {M}/msys/$arch/\n"; cat /etc/pacman.d/mirrorlist.msys; } > /tmp/msys.mirror.new && mv /tmp/msys.mirror.new /etc/pacman.d/mirrorlist.msys'
        Invoke-Bash $mingwCmd.Replace('{M}', $m) | Out-Null
        Invoke-Bash $msysCmd.Replace('{M}', $m)  | Out-Null
        Invoke-Bash 'head -n 2 /etc/pacman.d/mirrorlist.mingw64; head -n 2 /etc/pacman.d/mirrorlist.msys' | Out-Null
    }

    $phase = 'pacman core update'
    Step "3. pacman core update"
    $updated = $false
    for ($i = 1; $i -le 3; $i++) {
        Note "attempt $i/3 - upgrading msys2-runtime can kill this shell; that exit code is expected"
        $code = Invoke-Bash 'pacman -Syuu --noconfirm --needed'
        Write-Host "pacman exit    : $code"
        if ($code -eq 0) { $updated = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $updated) {
        Note "core update did not converge; trying keyring repair"
        Invoke-Bash 'pacman-key --init && pacman-key --populate msys2 && pacman -Sy --noconfirm' | Out-Null
    }

    $phase = 'install toolchain'
    Step "4. installing toolchain"
    # No --disable-download-timeout on purpose: with pacman's default low-speed
    # timeout a dead mirror fails in seconds instead of hanging forever, and the
    # retry above then has something to work with.
    $pkgs = 'mingw-w64-x86_64-toolchain base-devel perl patch zip unzip curl wget'
    $code = Invoke-Bash "pacman -S --noconfirm --needed $pkgs"
    Write-Host "pacman exit    : $code"
    if ($code -ne 0) {
        Note "retrying after refreshing package databases"
        Invoke-Bash 'pacman -Sy --noconfirm' | Out-Null
        $code = Invoke-Bash "pacman -S --noconfirm --needed $pkgs"
        Write-Host "pacman exit    : $code"
        if ($code -ne 0) { Fail "package installation failed (exit $code) - see the pacman output above. If it timed out, retry with -PacmanMirror <mirror>." }
    }

    # ---------------------------------------------------------------- verify
    $phase = 'verify toolchain'
    Step "5. verifying MINGW64 toolchain"
    $env:MSYSTEM = 'MINGW64'
    Invoke-Bash 'echo MSYSTEM=$MSYSTEM; gcc --version | head -n1; make --version | head -n1; perl -e "print qq{perl $^O\n}"' | Out-Null
    $target = (& $script:Bash -lc 'gcc -dumpmachine' 2>&1) -join ''
    Write-Host "gcc target     : $target"
    if ($target -notmatch 'x86_64-w64-mingw32') { Fail "expected x86_64-w64-mingw32, got: $target (MSYS2 shell instead of MINGW64?)" }

    $phase = 'done'
    Step "READY"
    Write-Host "MSYS2 : $Root  ($([math]::Round($sw.Elapsed.TotalMinutes,1)) min)" -ForegroundColor Green
    Write-Host "log   : $logPath" -ForegroundColor Green
    Write-Host "next  : .\03-run-build.cmd -Jobs 4" -ForegroundColor Green
}
catch {
    $failed = $true
    $hint = switch -Regex ($_.Exception.Message) {
        'could not download'     { 'all official sources failed: GitHub CDN resets large transfers on some networks. Retry, or download msys2-x86_64-latest.exe by hand and pass -InstallerUrl file:///C:/path/to/msys2-x86_64-latest.exe' }
        'exit code 1'            { 'installer refused - leftover directory in the install root; delete it and retry' }
        'bash.exe is missing'    { 'antivirus or disk-full truncated the install; retry setup-msys2.ps1' }
        'package installation'   { 'pacman mirror issue - retry; if it persists run pacman-key --init inside MINGW64' }
        default                  { '' }
    }
    Show-FailureInfo -err $_ -hint $hint
}
finally {
    # Print the verdict while the transcript is still recording, so the log
    # file ends with a clear RESULT line instead of stopping at the last step.
    $code = 0
    if ($failed) { $code = 1 }

    if ($failed) {
        Write-Host "`nRESULT: FAILED (exit code $code)" -ForegroundColor Red
        Write-Host "Log   : $logPath" -ForegroundColor Yellow
    }
    else {
        Write-Host "`nRESULT: OK (exit code $code)" -ForegroundColor Green
        Write-Host "Log   : $logPath" -ForegroundColor Green
    }

    if (-not $NoTranscript) {
        try { Stop-Transcript | Out-Null } catch { }
        Convert-TranscriptToUtf8 $logPath
    }

    # Record the exit code for automation, but ONLY when the caller did not ask
    # for -NoExit: SetShouldExit also makes an interactive -NoExit host quit,
    # which is what closed the cmd window right after the run.
    $noExit = $false
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -ieq '-NoExit') { $noExit = $true; break }
    }
    if (-not $noExit) {
        try { $host.SetShouldExit($code) } catch { }
    }
    else {
        Write-Host "`n(window kept open by -NoExit; type 'exit' or close it when you are done)" -ForegroundColor DarkGray
    }
}
