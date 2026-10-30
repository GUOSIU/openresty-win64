# build-all.ps1  (v2)
# Run the OpenResty 1.31.8.1 x64 build inside the sandbox.
# Wraps build-openresty.sh so it runs in the MSYS2 MINGW64 environment and
# drops the finished zip into .\dist (mapped back to the host).
#
#   powershell -ExecutionPolicy Bypass -File .\build-all.ps1
#   powershell -ExecutionPolicy Bypass -File .\build-all.ps1 -Jobs 4 -OutDir .\dist
#   powershell -ExecutionPolicy Bypass -File .\build-all.ps1 -MsysRoot C:\msys64
#
# Logs next to this script:
#   build-log.txt      full transcript (all Write-Host output)
#   build-output.log   raw stdout/stderr of the build script, last run
#
[CmdletBinding()]
param(
    [int]    $Jobs       = 0,
    [string] $OutDir     = '',
    # Where MSYS2 lives. Default: %LOCALAPPDATA%\msys64 (what 02-run-setup.cmd
    # installs). CI uses C:\msys64, which msys2/setup-msys2@v2 provides.
    [string] $MsysRoot   = '',
    # Version knobs for a new release. Leave empty to use the defaults baked
    # into build-openresty.sh (currently openresty 1.31.8.1 / openssl 3.5.9).
    [string] $Version    = '',
    [string] $OpenSSLVer = '',
    [string] $Pcre2Ver   = '',
    [string] $ZlibVer    = '',
    # Reuse an existing build tree: skips unpack/patch/configure and only reruns
    # make (a no-op if nothing changed) + install + package. ~40 s instead of ~15 min.
    [switch] $Reuse,
    [switch] $NoTranscript
)

# Label used only for console output; the real work is done by the .sh file.
$buildLabel = 'OpenResty'
if ($Version) { $buildLabel = "OpenResty $Version" }

# $PSScriptRoot is STILL EMPTY while param() defaults are evaluated, so the
# output directory must be resolved here instead. Doing it in the param block
# produced "Join-Path : Cannot bind argument to parameter 'Path' because it is
# an empty string" before the transcript (hence any log file) could even start.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)    { $OutDir    = Join-Path $scriptDir 'dist' }

# ---- logs: .\log\build-<yyyyMMdd-HHmmss>.txt, newest 20 kept ----------------
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $scriptDir 'log'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Remove-OldLogs([string] $dir, [string] $filter, [int] $keep = 20) {
    Get-ChildItem -Path $dir -Filter $filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $keep |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
Remove-OldLogs $logDir 'build-*.txt'
Remove-OldLogs $logDir 'build-output-*.log'

$logPath   = Join-Path $logDir "build-$stamp.txt"
$rawLog    = Join-Path $logDir "build-output-$stamp.log"

# 'Continue', NOT 'Stop': in PowerShell 5.1 any native program that writes to
# stderr (bash, gcc warnings, configure output) becomes a terminating
# NativeCommandError under Stop. Exit codes are checked explicitly instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---- UTF-8 console -----------------------------------------------------------
# MSYS2 tools print UTF-8, Windows legacy tools print OEM bytes; PowerShell
# decodes native output with [Console]::OutputEncoding. Pin it to UTF-8 so both
# the window and the captured logs show CJK text correctly instead of mojibake.
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

$buildSh   = Join-Path $scriptDir 'build-openresty.sh'
$phase     = 'init'
$failed    = $false
$sw        = [System.Diagnostics.Stopwatch]::StartNew()

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Note($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "WARN: $msg" -ForegroundColor Yellow }

function Show-FailureInfo {
    param($err, [string]$hint = '')

    Write-Host "`n---------------- BUILD FAILED ----------------" -ForegroundColor Red
    Write-Host "phase      : $phase"                                  -ForegroundColor Red
    Write-Host "message    : $($err.Exception.Message)"               -ForegroundColor Red
    if ($err.CategoryInfo) { Write-Host "category   : $($err.CategoryInfo.Category)" -ForegroundColor Red }
    if ($err.InvocationInfo) {
        Write-Host "location   : line $($err.InvocationInfo.ScriptLineNumber): $($err.InvocationInfo.Line.Trim())" -ForegroundColor Red
    }
    if ($err.ScriptStackTrace) { Write-Host "stack      :`n$($err.ScriptStackTrace)" -ForegroundColor DarkRed }
    Write-Host "elapsed    : $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min" -ForegroundColor Red
    if ($hint) { Write-Host "hint       : $hint" -ForegroundColor Yellow }

    Write-Host "`n--- diagnostics ---" -ForegroundColor Yellow
    foreach ($drive in @('C')) {
        try { Write-Host "free $drive     : $([math]::Round((Get-PSDrive $drive).Free / 1GB, 1)) GB" } catch { }
    }
    Write-Host "MSYS2      : $script:MsysRoot $(if (Test-Path $script:Bash) {'[ok]'} else {'[MISSING - run 02-run-setup.cmd]'})"
    Write-Host "build sh   : $buildSh $(if (Test-Path $buildSh) {'[ok]'} else {'[MISSING]'})"
    Write-Host "out dir    : $OutDir"
    if (Test-Path $rawLog) {
        Write-Host "`n--- last 40 lines of build-output.log ---" -ForegroundColor Yellow
        Get-Content $rawLog -Tail 40 | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "`nlogs: $logPath" -ForegroundColor Yellow
    Write-Host "      $rawLog"  -ForegroundColor Yellow
}

if (-not $NoTranscript) {
    try { Start-Transcript -Path $logPath -Force | Out-Null } catch { Write-Host "transcript disabled: $($_.Exception.Message)" }
}

try {
    # ------------------------------------------------------------ preflight
    $phase = 'preflight'
    Step "0. preflight"

    if ($MsysRoot) { $script:MsysRoot = $MsysRoot }
    else           { $script:MsysRoot = Join-Path $env:LOCALAPPDATA 'msys64' }
    $script:Bash     = Join-Path $script:MsysRoot 'usr\bin\bash.exe'

    Write-Host "OS        : $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Host "PS        : $($PSVersionTable.PSVersion)"
    Write-Host "CPU       : $([Environment]::ProcessorCount) logical cores"
    Write-Host "MSYS2     : $script:MsysRoot"
    Write-Host "out dir   : $OutDir"

    if (-not (Test-Path $script:Bash)) {
        throw "MSYS2 not found at $($script:MsysRoot). Run .\02-run-setup.cmd first (it installs to %LOCALAPPDATA%\msys64)."
    }
    if (-not (Test-Path $buildSh)) {
        throw "missing build script: $buildSh"
    }
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null
    }

    # Windows path -> MSYS2 path (C:\a\b -> /c/a/b), any drive letter
    function To-MsysPath([string] $p) {
        $full = [System.IO.Path]::GetFullPath($p)
        if ($full -notmatch '^[A-Za-z]:\\') { throw "not an absolute local path: $p" }
        $drive = $full.Substring(0, 1).ToLower()
        return ('/' + $drive + '/' + $full.Substring(3).Replace('\', '/'))
    }

    $fullOut  = [System.IO.Path]::GetFullPath($OutDir)
    $driveId  = $fullOut.Substring(0, 1)
    $freeGB   = [math]::Round((Get-PSDrive $driveId).Free / 1GB, 1)
    Write-Host "free space: $freeGB GB on drive $driveId"
    if ($freeGB -lt 4) { Warn "less than 4 GB free - the build (OpenSSL + LuaJIT + nginx) needs roughly 3-4 GB" }

    $scriptMsys = To-MsysPath $buildSh
    $outMsys    = To-MsysPath $OutDir

    $env:MSYSTEM        = 'MINGW64'
    $env:CHERE_INVOKING = '1'
    if ($Jobs -le 0) { $env:JOBS = "$([Environment]::ProcessorCount)" } else { $env:JOBS = "$Jobs" }
    $env:OUT_DIR        = $outMsys

    # Forward the version knobs; unset ones fall back to the .sh defaults.
    if ($Version)    { $env:VERSION     = $Version }
    if ($OpenSSLVer) { $env:OPENSSL_VER = $OpenSSLVer }
    if ($Pcre2Ver)   { $env:PCRE2_VER   = $Pcre2Ver }
    if ($ZlibVer)    { $env:ZLIB_VER    = $ZlibVer }
    if ($Reuse)      { $env:REUSE       = '1' }

    Step "1. build configuration"
    Write-Host "script : $scriptMsys"
    Write-Host "out    : $outMsys"
    Write-Host "jobs   : $env:JOBS"
    Write-Host "logs   : $logDir"
    if ($Version)    { Write-Host "version: $Version" }
    if ($OpenSSLVer) { Write-Host "openssl: $OpenSSLVer" }
    if ($Pcre2Ver)   { Write-Host "pcre2  : $Pcre2Ver" }
    if ($ZlibVer)    { Write-Host "zlib   : $ZlibVer" }
    Write-Host "started: $(Get-Date -Format o)"
    if ($Version) { Note "new release requested - make sure -OpenSSLVer / -Pcre2Ver / -ZlibVer match that release" }
    if ($Reuse)   { Note "REUSE: keeping the existing build tree (fast repackage)" }

    # ---------------------------------------------------------------- build
    $phase = 'build (bash build-openresty.sh)'
    Step "2. compiling $buildLabel (OpenSSL + PCRE2 + zlib + LuaJIT + nginx)"
    if ($Reuse) {
        Note "reusing objs/ -> make should be a no-op; expect well under a minute"
    } else {
        Note "expect 15-40 minutes; do not close the sandbox window"
    }

    $captured = New-Object System.Collections.Generic.List[string]
    & $script:Bash -lc "bash '$scriptMsys'" 2>&1 | ForEach-Object {
        $line = "$_"
        $captured.Add($line)
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $captured | Set-Content -Path $rawLog -Encoding UTF8 -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        $tail = ($captured | Select-Object -Last 25) -join "`n"
        throw "build script exited with code $code. Last lines:`n$tail"
    }

    # -------------------------------------------------------------- verify
    $phase = 'verify artifacts'
    Step "3. verifying artifacts"

    $zip = Get-ChildItem $OutDir -Filter 'openresty-*-win64.*' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $zip) {
        throw "build reported success but no openresty-*-win64.zip/.tar.gz found in $OutDir"
    }
    $mb = [math]::Round($zip.Length / 1MB, 1)
    if ($mb -lt 5) { throw "artifact $($zip.Name) is only $mb MB - expected 15+ MB, the build did not really succeed" }

    $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash
    Write-Host "artifact : $($zip.Name)"
    Write-Host "size     : $mb MB"
    Write-Host "sha256   : $sha"

    $phase = 'done'
    Step "READY"
    Write-Host "$buildLabel win64 built in $([math]::Round($sw.Elapsed.TotalMinutes,1)) min" -ForegroundColor Green
    Write-Host "artifact : $($zip.FullName)" -ForegroundColor Green
    Write-Host "log      : $logPath" -ForegroundColor Green
    Write-Host "next     : Expand-Archive '$($zip.Name)' -DestinationPath C:\openresty -Force" -ForegroundColor Green
}
catch {
    $failed = $true
    $hint = switch -Regex ($_.Exception.Message) {
        'exited with code 127'            { 'command not found inside bash - is build-openresty.sh saved with LF line endings?' }
        'exited with code 1'              { 'see build-output.log; the bash script prints "ERROR: ..." right before exiting' }
        'No space left'                   { 'sandbox VHD is full - delete ~/orbuild-* or give the sandbox more disk' }
        'not found at'                    { 'run .\02-run-setup.cmd first' }
        default                           { '' }
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
        Write-Host "Logs  : $logPath" -ForegroundColor Yellow
        Write-Host "        $rawLog" -ForegroundColor Yellow
    }
    else {
        Write-Host "`nRESULT: OK (exit code $code)" -ForegroundColor Green
        Write-Host "Logs  : $logPath" -ForegroundColor Green
    }

    if (-not $NoTranscript) {
        try { Stop-Transcript | Out-Null } catch { }
        Convert-TranscriptToUtf8 $logPath
    }

    # Record the exit code for automation, but ONLY when the caller did not ask
    # for -NoExit: SetShouldExit also makes an interactive -NoExit host quit,
    # which is what closed the cmd window right after the build.
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
