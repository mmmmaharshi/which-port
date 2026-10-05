#!/usr/bin/env pwsh
# Runs every test, on every platform this machine can run.
#
#   pwsh scripts/test-all.ps1
#
# Exists because the two suites need genuinely different invocations and neither
# is discoverable from the source: the Windows suite runs directly, while the
# Linux one must be cross-compiled with --test-no-exec (the Windows host cannot
# execute a musl ELF) and then run inside WSL. That difference is how a test run
# gets quietly skipped -- which is how the whole Linux suite went unrun once
# already. One command, no guessing.
#
# Ticket #5 replaces this with a build.zig. Until then this is the entry point.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$failed = @()
$ran = @()

function Invoke-Step([string]$name, [scriptblock]$body) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    try {
        & $body
        if ($LASTEXITCODE -ne 0) { $script:failed += $name; Write-Host "FAILED ($LASTEXITCODE)" -ForegroundColor Red }
        else { Write-Host "ok" -ForegroundColor Green; $script:ran += $name }
    }
    catch {
        $script:failed += $name
        Write-Host "ERROR: $_" -ForegroundColor Red
    }
}

# --- shared: parser tests are OS-free, so run them once per target -----------
Invoke-Step 'formatting' {
    $bad = Get-ChildItem $root\src -Filter *.zig | Where-Object { zig fmt --check $_.FullName 2>&1 }
    if ($bad) { throw "not zig-fmt clean: $($bad.Name -join ', ')" }
}

Invoke-Step 'format + parser tests (windows)' {
    zig test src/addr.zig
    zig test src/parse_proc.zig
    zig test src/report.zig
}

# main.zig is reached by no test file, so nothing above compiles it. Without
# this a change that broke argument parsing, the table layout or an exit code
# would leave every suite green.
Invoke-Step 'the binary compiles' {
    zig build-exe src/main.zig -femit-bin="$env:TEMP\which-port-buildcheck.exe"
    Remove-Item "$env:TEMP\which-port-buildcheck.exe" -ErrorAction SilentlyContinue
}

Invoke-Step 'windows live round-trip' {
    zig test src/win_test.zig
}

# --- linux: cross-compile with --test-no-exec, then run it in WSL -----------
$haveWsl = $false
try { $null = wsl -l -v 2>$null; $haveWsl = $true } catch { $haveWsl = $false }

if (-not $haveWsl) {
    Write-Host "`n=== linux tests ===`nSKIPPED: no WSL on this machine." -ForegroundColor Yellow
}
else {
    $bin = Join-Path $env:TEMP 'which-port-linux-test'
    # Separators must become / before wsl sees the path. It strips backslashes
    # out of the argument, which collapses the path into one unopenable name and
    # fails the step with 127 -- looking like a missing binary, not a bad path.
    $wslBin = "/mnt/$($bin.Substring(0,1).ToLower())/$($bin.Substring(3).Replace('\','/'))"
    Invoke-Step 'linux suite (cross-compiled, run in WSL)' {
        # -lc because the suite binds its listener through extern "c": Zig 0.17
        # removed std.posix.socket. --test-no-exec because a musl ELF will not
        # run on a Windows host.
        zig test src/lin_test.zig -target x86_64-linux-musl -lc --test-no-exec "-femit-bin=$bin"
        if ($LASTEXITCODE -ne 0) { throw 'cross-compile failed' }
        wsl -d Ubuntu-24.04 -- chmod +x $wslBin
        wsl -d Ubuntu-24.04 -- $wslBin
    }
}

# --- the vocabulary check, so glossary drift cannot land unnoticed -----------
Invoke-Step 'glossary vocabulary' {
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-vocabulary.ps1')
}

Pop-Location

Write-Host "`n--- summary ---"
Write-Host ("passed: {0}" -f ($ran -join ', '))
if ($failed.Count -gt 0) {
    Write-Host ("FAILED: {0}" -f ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "all green" -ForegroundColor Green
exit 0