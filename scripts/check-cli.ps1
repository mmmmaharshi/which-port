#!/usr/bin/env pwsh
# Checks the CLI contract README.md documents, by running the built binary.
#
#   pwsh -NoProfile -File scripts/check-cli.ps1
#
# main.zig holds four exit codes, the port parser, the usage text and the
# stdout/stderr split. Nothing tested any of it: the suite's only contact with
# main.zig was `zig build-exe`, which proves it compiles and nothing else. A
# change that broke argument parsing, an exit code or the stream split would
# have left every suite green.
#
# The test surface is the process, not parsePort. main.zig's bugs live in which
# stream a line went to and which code came back, and neither shows up in a unit
# test of the parser. `which-port 8080 > out.txt` captures data and never prose
# is the contract, so that is what gets checked.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

$tmp = [System.IO.Path]::GetTempPath()
$exe = if ($IsWindows) { Join-Path $tmp 'which-port-cli-check.exe' } else { Join-Path $tmp 'which-port-cli-check' }
$errFile = Join-Path $tmp 'which-port-cli-check.err'

zig build-exe src/main.zig "-femit-bin=$exe"
if ($LASTEXITCODE -ne 0) { throw 'could not build the binary to check' }

$failures = @()
$checks = 0

# Assert the exit status and which stream carried what. `$Stdout` empty is as much
# a part of the contract as the text in it.
function Assert-Run(
    [string]$label,
    [int]$wantExit,
    [string]$wantStdout,
    [string]$wantStderr,
    [string[]]$argv
) {
    $script:checks++
    Remove-Item $errFile -ErrorAction SilentlyContinue

    $stdout = (& $exe @argv 2>$errFile) -join "`n"
    $code = $LASTEXITCODE
    $stderr = if (Test-Path $errFile) { [System.IO.File]::ReadAllText($errFile) } else { '' }

    $problems = @()
    if ($code -ne $wantExit) { $problems += "exit $code, wanted $wantExit" }
    if ($stdout -notmatch $wantStdout) { $problems += "stdout is '$stdout', wanted to match '$wantStdout'" }
    if ($stderr -notmatch $wantStderr) { $problems += "stderr is '$stderr', wanted to match '$wantStderr'" }
    # A redirect that captures prose instead of data is the failure the README
    # promises cannot happen, so an empty stream has to be asserted too.
    if ($wantStdout -eq '' -and $stdout -ne '') { $problems += "stdout should have been empty, got '$stdout'" }
    if ($wantStderr -eq '' -and $stderr -ne '') { $problems += "stderr should have been empty, got '$stderr'" }

    if ($problems.Count -gt 0) {
        $script:failures += $label
        Write-Host ("  {0}: {1}" -f $label, ($problems -join '; ')) -ForegroundColor Red
    }
    else {
        Write-Host "  $label ok" -ForegroundColor Green
    }
}

# A listener held open for the duration, so the Occupied case is not a race
# against whatever else on the machine grabs the port. Port 0 asks the kernel for
# one, which also means the two checks cannot collide with each other.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$busy = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

try {
    Assert-Run 'exit 0, usage on stdout, nothing on stderr' 0 'usage: which-port' '' @('--help')
    Assert-Run 'exit 2, no argument' 2 '' 'expected a port' @()
    Assert-Run 'exit 2, not a number' 2 '' 'is not a number' @('eighty')
    Assert-Run 'exit 2, out of range' 2 '' 'not between 1 and 65535' @('70000')
    Assert-Run 'exit 2, zero is not a port' 2 '' 'not between 1 and 65535' @('0')
    Assert-Run 'exit 2, unknown option' 2 '' 'unknown option' @('--bogus')
    Assert-Run 'exit 2, too many arguments' 2 '' 'expected one port' @('80', '81')
    # The contract a script depends on: data on stdout, prose on stderr.
    Assert-Run 'exit 0, Occupancy table on stdout, no prose' 0 'ADDRESS\s+PID\s+PROCESS\s+PATH' '' @("$busy")
}
finally {
    $listener.Stop()

    # Released, so the same port is now a Free port. Checked after Stop() so the
    # Occupied case above ran against a live listener.
    Assert-Run 'exit 1, Free port says so on stderr, stdout empty' 1 '' "port $busy is free" @("$busy")
}

Pop-Location
Remove-Item $exe, $errFile -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host ("FAILED: {0}" -f ($failures -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "all $checks CLI checks passed" -ForegroundColor Green
exit 0