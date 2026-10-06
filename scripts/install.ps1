#!/usr/bin/env pwsh
# Installs which-port on Windows: downloads the release, verifies it, and puts
# it somewhere on your PATH.
#
#   pwsh scripts/install.ps1
#   pwsh scripts/install.ps1 -Version v0.1.1
#   pwsh scripts/install.ps1 -Dir C:\tools        # skip the PATH change
#
# Four steps, each announced before it happens, so a run that hangs tells you
# where. A script run from the internet that prints nothing until it finishes is
# indistinguishable from one that is stuck, and a list of all four steps up front
# is a list of all four steps up front.
#
# The count is in the header so a pasted log reads against this list, and a
# failure names the step it died on.
#
# Everything here exists because of something Windows does that surprises people:
#
#   * A downloaded .exe is blocked until it is unblocked, and the message says
#     "Windows protected your PC", which reads like the file is malicious rather
#     than unsigned. Unblock-File is a documented cmdlet for exactly this.
#   * The 32-bit build is not on PATH for a normal install, and picking the
#     wrong one produces a binary that cannot run at all.
#   * Editing the machine PATH needs an elevated shell. The user PATH does not,
#     so that is what this writes: no elevation, no UAC prompt, and it affects
#     only the person running it.
#
# Verifies the download against SHA256SUMS from the same release, so a corrupted
# or substituted download fails here rather than at the next port check.
param(
    [string] $Version = '',
    [string] $Dir = ''
)

$ErrorActionPreference = 'Stop'

$repo = 'mmmmaharshi/which-port'
$script:step = 0
$Total = 4

# Under LOCALAPPDATA rather than Program Files, because writing to Program Files
# needs an elevated shell and this tool asks for none anywhere else.
$DefaultDir = Join-Path $env:LOCALAPPDATA 'Programs\which-port'

function Step([string] $what) {
    $script:step++
    Write-Host ''
    Write-Host "[$script:step/$Total] $what" -ForegroundColor Cyan
}

function Note([string] $what) {
    Write-Host "      $what"
}

function Get-File([string] $url, [string] $into) {
    # A wrong version is the common failure, and Invoke-WebRequest's own error for
    # a 404 includes the entire HTML of GitHub's "Page not found" -- hundreds of
    # lines that bury the one fact that matters. The status code is what a reader
    # can act on, so pull that out and throw something short instead.
    try {
        Invoke-WebRequest $url -OutFile $into
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 404) { throw "not on the $repo releases page: $url" }
        if ($status) { throw "download failed with HTTP ${status}: $url" }
        throw "download failed: $url -- $_"
    }
}

if ($Version -eq '') {
    # Latest means GitHub's latest: newest published, non-prerelease. A -rc tag
    # is deliberately skipped so this never installs a candidate by accident.
    $Version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}

# x64 and arm64 are the two Windows builds a release attaches. Anything else --
# a 32-bit Windows, or an unusual architecture -- is refused rather than handed
# a binary that cannot start.
$machine = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$arch = switch -RegEx ($machine) {
    'X64'   { 'x86_64' }
    'Arm64' { 'aarch64' }
    default { throw "this machine is $machine, and there is no Windows build for it; this script handles x64 and arm64" }
}

$base = "https://github.com/$repo/releases/download/$Version"
$asset = "which-port-$arch-windows.exe"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "which-port-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Step "fetching $Version for windows-$arch"
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Get-File "$base/$asset" (Join-Path $work $asset)
    # GitHub serves this as application/octet-stream, so .Content is a byte[] and
    # splitting it directly matches nothing -- which reads as "SHA256SUMS does
    # not list the asset" and sends you looking for a problem in the release
    # rather than in the parsing. Decode it first, and split on CRLF as well as
    # LF because the file is written by a Linux tool.
    $sumsFile = Join-Path $work 'SHA256SUMS'
    Get-File "$base/SHA256SUMS" $sumsFile
    $sums = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($sumsFile))
    $line = ($sums -split "`r?`n") | Where-Object { $_ -match "\s$([regex]::Escape($asset))\s*$" } | Select-Object -First 1
    if (-not $line) { throw "SHA256SUMS on $Version does not list $asset" }

    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash (Join-Path $work $asset) -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "checksum mismatch for ${asset}: the download does not match the published digest"
    }

    Step 'verified against the published checksum'

    # Clears the Mark of the Web the download left behind. Without this the file
    # is blocked on first run and Windows blames the file rather than the missing
    # signature. Silently fine either way, so it is not worth failing over.
    Unblock-File -Path (Join-Path $work $asset) -ErrorAction SilentlyContinue

    if ($Dir -eq '') { $Dir = $DefaultDir }
    Step "installing to $Dir"
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $target = Join-Path $Dir 'which-port.exe'
    Move-Item (Join-Path $work $asset) $target -Force

    if ($Dir -eq $DefaultDir) {
        # Compared entry by entry rather than with -like, because -like treats
        # [ and ] in a path as wildcard character classes. A user profile with
        # a bracket in it would otherwise read as "already on PATH" and never be
        # added. Trailing separators are trimmed because C:\tools and C:\tools\
        # are the same directory written two ways.
        $onPath = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
            Where-Object { $_ } |
            Where-Object { $_.Trim().TrimEnd('\') -ieq $Dir.TrimEnd('\') }

        if (-not $onPath) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            # User scope, so no elevation is needed and nothing outside this
            # account's PATH changes.
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$Dir", 'User')
        }
    }

    # The installed path rather than the bare name, so this reports on the install
    # and not on whatever older which-port happens to be on PATH already.
    & $target --help | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the installed binary exited $LASTEXITCODE on --help" }

    Step 'done'
    # A new shell is needed to see a PATH change made by a process that has
    # already exited. Say so, because "it still says not recognised" after a
    # successful install is the confusing part.
    if ($Dir -eq $DefaultDir) {
        Note 'open a new terminal, then: which-port 8080'
    }
    else {
        Note '-Dir was given, so PATH is unchanged. Add it yourself:'
        Note "[Environment]::SetEnvironmentVariable('Path', `$([Environment]::GetEnvironmentVariable('Path','User'));$Dir, 'User')"
    }
}
catch {
    # Names the step that failed, because a bare error tells you nothing about
    # where you were. ${script:step} rather than $script:step, since the colon
    # would otherwise be read as the start of a scope.
    Write-Host ''
    Write-Host "failed at step ${script:step}: $_" -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
