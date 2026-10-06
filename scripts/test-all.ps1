#!/usr/bin/env pwsh
# Runs every test this machine is able to run, and says plainly which ones it
# could not run and why.
#
#   pwsh scripts/test-all.ps1
#
# Exists because a test suite needs a genuinely different invocation per
# platform, and none of that difference is discoverable from the source: the
# Windows suite runs directly and binds through ws2_32, the Linux one binds
# through libc, and on a Windows host the Linux ELF cannot be executed and has
# to go through WSL. That difference is how a run gets quietly skipped -- which
# is how the whole Linux suite went unrun once already. One command, no
# guessing, and no silent omissions.
#
# A suite that cannot run here is printed as SKIPPED with its reason. A suite
# that goes missing without a reason is the failure mode this file exists to
# prevent, so a skip is never silent.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$failed = @()
$ran = @()
$skipped = @()

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

function Skip-Step([string]$name, [string]$why) {
    Write-Host "`n=== $name ===`nSKIPPED: $why" -ForegroundColor Yellow
    $script:skipped += "$name -- $why"
}

# Which OS is this? $IsWindows and friends are read-only in pwsh 7 but absent in
# Windows PowerShell 5.1, so the fallback reads the platform directly rather
# than trusting a variable that might not exist.
function Test-Os([string]$name) {
    $flag = "\$Is$name"
    if (Get-Variable -Name $flag -ErrorAction SilentlyContinue) { return [bool](Get-Variable -Name $flag).Value }
    $platform = switch ($name) {
        'Windows' { [System.Runtime.InteropServices.OSPlatform]::Windows }
        'Macos' { [System.Runtime.InteropServices.OSPlatform]::OSX }
        default { [System.Runtime.InteropServices.OSPlatform]::Linux }
    }
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform($platform)
}

$onWindows = Test-Os 'Windows'
$onMacos = Test-Os 'Macos'

# Neither $env:TEMP nor a backslash survives the trip to Linux. $env:TEMP is unset
# under pwsh on Unix, so "$env:TEMP\x" collapses to "\x" -- a write to the root of
# the filesystem, which fails as permission denied and reads like a broken build.
# Both helpers below are the portable spelling.
$tmp = [System.IO.Path]::GetTempPath()
$src = Join-Path $root 'src'

# --- OS-free: nothing here reaches the platform seam -------------------------
Invoke-Step 'formatting' {
    $bad = Get-ChildItem $src, $root -Filter *.zig -File |
        Where-Object { $_.Name -ne 'build.zig' -or $_.DirectoryName -eq $root } |
        Where-Object { zig fmt --check $_.FullName 2>&1 }
    if ($bad) { throw "not zig-fmt clean: $($bad.Name -join ', ')" }
}

# main.zig is reached by no test file, so nothing below compiles it. Without
# this a change that broke argument parsing, the table layout or an exit code
# would leave every suite green.
#
# Not on macOS. main.zig calls lookup(), which forces the platform switch in
# lookup.zig, which is a compile error there until the lsof lookup lands. That
# is the one thing on macOS that cannot be checked, and `zig build all-targets`
# below still proves every shipped target compiles.
if ($onMacos) {
    Skip-Step 'the binary compiles' 'main.zig calls lookup(), which is a compile error on macOS until the lsof lookup lands'
}
else {
    Invoke-Step 'the binary compiles' {
        $out = Join-Path $tmp 'which-port-buildcheck.bin'
        zig build-exe src/main.zig "-femit-bin=$out"
        Remove-Item $out -ErrorAction SilentlyContinue
    }
}

# The release build, built every run. It is slow only in the sense that it
# compiles four targets, and it is the step that catches a change which compiles
# on this machine and nowhere else.
Invoke-Step 'every shipped target compiles' {
    zig build all-targets
}

# main.zig's documented contract: four exit codes and the stdout/stderr split.
# Checked through the binary, because that is the interface a user meets and the
# one the README documents. Runs everywhere -- no platform calls.
Invoke-Step 'cli contract' {
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-cli.ps1')
}

# --- the vocabulary check, so glossary drift cannot land unnoticed -----------
Invoke-Step 'glossary vocabulary' {
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-vocabulary.ps1')
}

# --- the seam and the suites behind it ---------------------------------------
#
# These four run on all three platforms, macOS included, and that surprised me
# enough to be worth checking rather than assuming. lookup.zig does select its
# implementation at module scope:
#
#     const impl = switch (builtin.os.tag) { ... .macos => @compileError(...) };
#
# but Zig analyses a container-level declaration only when something refers to
# it. Occupier, unresolved and lessThan never touch impl, so report.zig compiles
# and passes on macOS today. Only lookup() and LookupError force the switch, and
# only main.zig calls those.
#
# So the earlier version of this file was wrong to skip these on macOS, and the
# macOS job was wrong to name them by hand. An unverified belief about what the
# compiler does is the same defect as the WSL path bug this file was written to
# catch: something skipped, quietly, for a reason nobody had tested.
Invoke-Step 'format + parser tests' {
    zig test src/addr.zig
    zig test src/parse_proc.zig
    zig test src/report.zig
    # Named rather than reached through lookup.zig, which reports zero tests:
    # Zig registers a file's tests only when something forces it to be analysed,
    # and lookup refers to all of occupier from inside function bodies.
    zig test src/occupier.zig
    zig test src/lookup.zig
}

# The live round-trip from the spec: bind a Listening socket, look it up, assert
# the Occupier is this very process.
if ($onWindows) {
    Invoke-Step 'windows live round-trip' {
        zig test src/win_test.zig
    }
}
else {
    Skip-Step 'windows live round-trip' 'ws2_32 links only on Windows'
}

# --- linux: run natively where Linux, cross-compile into WSL where Windows ----
#
# On Linux the suite builds and runs directly, the way every other suite here
# does. Only a Windows machine needs the cross-compile, because only a Windows
# machine cannot execute the ELF it produces.
#
# The earlier version keyed this on WSL alone, so a Linux runner -- where WSL
# never exists -- reported the suite SKIPPED and the run green. That is the same
# quiet skip this file exists to prevent.
if (-not $onWindows -and $onMacos) {
    Skip-Step 'linux suite' 'nothing on this machine can execute the ELF'
}
elseif (-not $onWindows) {
    Invoke-Step 'linux suite (native)' {
        # -lc because the suite binds its listener through extern "c": Zig 0.17
        # removed std.posix.socket.
        zig test src/lin_test.zig -target x86_64-linux-musl -lc
    }
}
else {
    $haveWsl = $false
    try { $null = wsl -l -v 2>$null; $haveWsl = $true } catch { $haveWsl = $false }

    if (-not $haveWsl) {
        Skip-Step 'linux suite' 'a Windows host cannot execute a musl ELF and this machine has no WSL'
    }
    else {
        $bin = Join-Path $tmp 'which-port-linux-test'

        # Hand the path over in an environment variable, not as an argument.
        # wsl.exe strips backslashes out of its arguments, so a Windows path
        # arrives inside WSL as one unopenable name and the step dies with 127 --
        # which reads like a missing binary rather than a mangled path. stdin is
        # not forwarded either. WSLENV with the /p flag is the mechanism built
        # for exactly this: wslpath does the conversion at the boundary, so the
        # path is right for any drive letter instead of any one guessed layout.
        #
        # Saved and restored, because WSLENV may already carry a caller's own
        # path-translated variables and clobbering it would break those too.
        #
        # Built with -f, not "$saved:WP_TEST_BIN/p". PowerShell reads a colon in a
        # double-quoted string as a scope operator, so $saved:WP_TEST_BIN is the
        # variable WP_TEST_BIN in scope `saved` -- empty, silently, leaving WSLENV
        # set to "/p" and the path never handed over at all.
        #
        # Trailing colons are trimmed first. Windows Terminal leaves WSLENV as
        # "WT_SESSION:WT_PROFILE_ID:", and appending produces a "::" separator that
        # names an empty variable.
        $savedWslenv = $env:WSLENV
        $env:WP_TEST_BIN = $bin
        $base = ($savedWslenv -replace ':+$', '')
        $env:WSLENV = if ($base) { '{0}:WP_TEST_BIN/p' -f $base } else { 'WP_TEST_BIN/p' }

        try {
            Invoke-Step 'linux suite (cross-compiled, run in WSL)' {
                # --test-no-exec because a musl ELF will not run on a Windows host.
                zig test src/lin_test.zig -target x86_64-linux-musl -lc --test-no-exec "-femit-bin=$bin"
                if ($LASTEXITCODE -ne 0) { throw 'cross-compile failed' }
                wsl -d Ubuntu-24.04 -- bash -lc 'chmod +x "$WP_TEST_BIN" && "$WP_TEST_BIN"'
            }
        }
        finally {
            $env:WSLENV = $savedWslenv
            Remove-Item Env:\WP_TEST_BIN -ErrorAction SilentlyContinue
        }
    }
}

Pop-Location

Write-Host "`n--- summary ---"
Write-Host ("passed: {0}" -f ($ran -join ', '))
if ($skipped.Count -gt 0) {
    Write-Host "skipped:" -ForegroundColor Yellow
    $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
if ($failed.Count -gt 0) {
    Write-Host ("FAILED: {0}" -f ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "all green" -ForegroundColor Green
exit 0