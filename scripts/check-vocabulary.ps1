#!/usr/bin/env pwsh
# Fails when the code has drifted from CONTEXT.md's vocabulary.
#
# Every `_Avoid_:` list in the glossary names synonyms the project has decided
# against. Nothing stops a new one creeping back in, and it is invisible in
# review unless someone reads the glossary first. So check it mechanically.
#
# Run from the repo root:  pwsh scripts/check-vocabulary.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$glossary = Join-Path $root 'CONTEXT.md'
$srcDir = Join-Path $root 'src'

if (-not (Test-Path $glossary)) { Write-Host "no CONTEXT.md, nothing to check"; exit 0 }
if (-not (Test-Path $srcDir)) { Write-Host "no src/, nothing to check"; exit 0 }

# An `_Avoid_:` term only means "don't use this word" for the concept it sits
# under -- not everywhere. `socket` is avoided under *Port* (a port is not a
# socket), yet "Listening socket" is itself a defined term, so the word is
# correct in the sense the glossary blesses. Flagging it everywhere buries the
# real drift in noise, so drop any avoided term that is also part of a term the
# glossary *defines*.
$defined = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content $glossary) {
    if ($line -match '^\*\*(.+?)\*\*:') { $defined.Add($Matches[1].ToLowerInvariant()) }
}

$avoided = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content $glossary) {
    if ($line -match '_Avoid_:\s*(.+)$') {
        foreach ($term in $Matches[1] -split ',') {
            $t = $term.Trim().Trim('"', "'", '`').ToLowerInvariant()
            # Single words only: a multi-word phrase is a judgement call, and
            # this check can only be mechanical about tokens.
            if ($t.Length -lt 4 -or $t -notmatch '^[a-z]+$') { continue }
            if ($defined | Where-Object { $_ -like "*$t*" }) { continue }
            $avoided.Add($t)
        }
    }
}

if ($avoided.Count -eq 0) { Write-Host "glossary declares no avoided terms"; exit 0 }

$failures = @()
foreach ($file in Get-ChildItem -Path $srcDir -Filter '*.zig' -File) {
    $lines = Get-Content $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = $lines[$i]
        foreach ($term in $avoided) {
            if ($text -match ('\b' + [regex]::Escape($term) + '\b')) {
                $failures += "{0}:{1} uses '{2}' (CONTEXT.md _Avoid_ list) -- {3}" -f `
                    $file.Name, ($i + 1), $term, $text.Trim()
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "glossary drift:`n"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ("vocabulary ok ({0} avoided terms checked)" -f $avoided.Count)
exit 0