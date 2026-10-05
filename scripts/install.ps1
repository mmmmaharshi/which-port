#!/usr/bin/env pwsh
# Installs which-port on Windows: downloads the release, verifies it, and puts
# it somewhere on your PATH.
#
#   pwsh scripts/install.ps1
#   pwsh scripts/install.ps1 -Version v0.1.1
#   pwsh scripts/install.ps1 -Dir C:\tools        # skip the PATH change
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

# Under LOCALAPPDATA rather than Program Files, because writing to Program Files
# needs an elevated shell and this tool asks for none anywhere else.
$DefaultDir = Join-Path $env:LOCALAPPDATA 'Programs\which-port'

# x64 and arm64 are the two Windows builds a release attaches. Anything else --
# a 32-bit Windows, or an unusual architecture -- is refused rather than handed
# a binary that cannot start.
$arch = switch -RegEx ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64'   { 'x86_64' }
    'Arm64' { 'aarch64' }
    default { throw "no which-port build for $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture); this script handles x64 and arm64" }
}

if ($Version -eq '') {
    $Version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}
Write-Host "installing $Version for windows-$arch"

$base = "https://github.com/$repo/releases/download/$Version"
$asset = "which-port-$arch-windows.exe"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "which-port-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    Write-Host "downloading $asset"
    Invoke-WebRequest "$base/$asset" -OutFile (Join-Path $work $asset)

    # Verified before it is put anywhere. A digest that does not match means the
    # download was truncated or replaced, and an unverified binary on PATH is
    # worse than no binary at all.
    #
    # GitHub serves this as application/octet-stream, so .Content is a byte[] and
    # splitting it directly matches nothing -- which reads as "SHA256SUMS does
    # not list the asset" and sends you looking for a problem in the release
    # rather than in the parsing. Decode it first, and split on CRLF as well as
    # LF because the file is written by a Linux tool.
    $sums = [System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest "$base/SHA256SUMS").Content)
    $line = ($sums -split "`r?`n") | Where-Object { $_ -match "\s$([regex]::Escape($asset))\s*$" } | Select-Object -First 1
    if (-not $line) { throw "SHA256SUMS on $Version does not list $asset" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash (Join-Path $work $asset) -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        throw "checksum mismatch for ${asset}: expected $expected, got $actual"
    }
    Write-Host "checksum ok"

    # Clears the Mark of the Web that the download left behind. Without this the
    # file is blocked on first run and Windows blames the file rather than the
    # missing signature.
    Unblock-File -Path (Join-Path $work $asset) -ErrorAction SilentlyContinue

    # Captured before $Dir is defaulted, so the PATH branch can still tell an
    # install into the default location from an install into one the caller chose.
    # A caller who names a directory is choosing where it goes and does not want
    # their PATH rewritten behind their back.
    if ($Dir -eq '') { $Dir = $DefaultDir }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $target = Join-Path $Dir 'which-port.exe'
    Move-Item (Join-Path $work $asset) $target -Force
    Write-Host "installed $target"

    if ($Dir -eq $DefaultDir) {
        # Compared entry by entry rather than with -like, because -like treats
        # [ and ] in the path as wildcard character classes. A user profile with
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
            Write-Host "added $Dir to your PATH"
        }
        else {
            Write-Host "$Dir is already on your PATH"
        }
        # A new shell is needed to see a PATH change made by a process that has
        # already exited. Say so, because "it still says not recognised" after a
        # successful install is the confusing part.
        Write-Host ''
        Write-Host 'open a new terminal, then run: which-port 8080'
    }
    else {
        Write-Host "add $Dir to your PATH yourself"
    }

    # Runs the copy that was just installed rather than anything already on PATH,
    # so this reports on the install and not on a previous version.
    & $target --help | Out-Null
    Write-Host "verified: $target --help exits $LASTEXITCODE"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
