#!/usr/bin/env pwsh
# Fails when a `pub` declaration in src/ is imported by nothing.
#
# Run from the repo root:  pwsh scripts/check-exports.ps1
#
# Why this exists, when the compiler already reports unused locals.
#
# `zig build` reports a local constant or variable that nothing reads. It does
# not report a `pub` one, because a library cannot know its callers. In a
# single-binary project the callers are all in src/ and readable, so an export
# nobody reads is dead weight, and a stale one is worse: it says a module
# offers something it no longer uses, and the next agent reads the interface
# rather than the implementation.
#
# Two ways this goes wrong, both found in review rather than by a tool:
#
#   - dead export. win.zig imported lookup.zig twice, for Occupier on one line
#     and withheld/named on another. Both are gone now that the contract has its
#     own file, but nothing would have said so.
#
#   - broken import. A renamed or misspelled symbol is a compile error, so that
#     half is covered. What is NOT covered is a file that imports a module and
#     uses nothing from it.
#
# Deliberately not covered: a `pub` referenced only by a `test` block in the same
# file. Those count as used, since the test is the reader.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'

if (-not (Test-Path $srcDir)) { Write-Host "no src/, nothing to check"; exit 0 }

$files = Get-ChildItem -Path $srcDir -Filter '*.zig' -File
if ($files.Count -eq 0) { Write-Host "no .zig files, nothing to check"; exit 0 }

# Every line of every file, so a reference anywhere counts -- including one inside
# a comment, which is a small false negative and worth it over a parser. The
# alternative is a real Zig AST walk, which is a much larger thing to maintain
# for a check that should stay readable.
$allText = ($files | ForEach-Object { Get-Content $_.FullName }) -join "`n"

# `pub const X`, `pub fn x`, `pub var X`. Not `pub inline` or `pub extern`, of
# which this project has none; adding one means adding it here too.
$declarations = @()
foreach ($file in $files) {
    $lines = Get-Content $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = $lines[$i]
        if ($text -notmatch '^\s*pub\s+(const|fn|var)\s+([A-Za-z_][A-Za-z0-9_]*)') { continue }
        $declarations += [pscustomobject]@{
            File   = $file.Name
            Line   = $i + 1
            Kind   = $Matches[1]
            Name   = $Matches[2]
        }
    }
}

# main is the entry point. The runtime calls it and no source file does, so it is
# always dead by this check's definition.
$declarations = $declarations | Where-Object { -not ($_.File -eq 'main.zig' -and $_.Name -eq 'main') }

if ($declarations.Count -eq 0) { Write-Host "no pub declarations found"; exit 0 }

$failures = @()
foreach ($d in $declarations) {
    $pattern = '\b' + [regex]::Escape($d.Name) + '\b'

    # Count references in every file EXCEPT the declaring one, then separately
    # within it. The two cases are different problems and get different fixes.
    $outside = 0
    $inside = 0
    foreach ($file in $files) {
        $hits = ([regex]::Matches((Get-Content $file.FullName) -join "`n", $pattern)).Count
        if ($file.Name -eq $d.File) { $inside = $hits } else { $outside += $hits }
    }

    if ($outside -gt 0) { continue }

    if ($inside -le 1) {
        # The declaration is the only mention: nothing reads it at all.
        $failures += ("{0}:{1} pub {2} {3} is read by nothing -- delete it" -f $d.File, $d.Line, $d.Kind, $d.Name)
    }
    else {
        # Used by its own file only, so `pub` buys nothing. Not dead, just wider
        # than it needs to be.
        $failures += ("{0}:{1} pub {2} {3} is used only in this file -- drop the pub" -f $d.File, $d.Line, $d.Kind, $d.Name)
    }
}

if ($failures.Count -gt 0) {
    Write-Host "exports that should not be public:`n"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ("exports ok ({0} pub declarations, all referenced)" -f $declarations.Count)
exit 0