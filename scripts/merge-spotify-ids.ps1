<#
.SYNOPSIS
One-off data-authoring script -- NOT part of the deployed page.

Merges reviewed Spotify matches (scripts/spotify-matches.json) into the
ALBUMS array in index.html. Run this only after reviewing each entry's
"best" field in that file -- resolve-spotify-ids.ps1's guesses are not
trustworthy on their own.

.EXAMPLE
.\scripts\merge-spotify-ids.ps1
#>

$ErrorActionPreference = 'Stop'

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$IndexHtml = Join-Path $RepoRoot 'index.html'
$MatchesFile = Join-Path $PSScriptRoot 'spotify-matches.json'

if (-not (Test-Path $MatchesFile)) {
    Write-Error "No $MatchesFile found. Run resolve-spotify-ids.ps1 first."
    exit 1
}

# [System.IO.File]::ReadAllText auto-detects a BOM and otherwise assumes
# UTF-8 -- unlike Get-Content -Raw, which on Windows PowerShell falls back
# to the system ANSI codepage for a BOM-less file and silently mangles any
# non-ASCII character (accents, em dashes, ...).
$matches_ = [System.IO.File]::ReadAllText($MatchesFile) | ConvertFrom-Json
$byRank = @{}
foreach ($m in $matches_) { $byRank[[int]$m.rank] = $m }

$html = [System.IO.File]::ReadAllText($IndexHtml)
$marker = $html.IndexOf('const ALBUMS = [')
if ($marker -eq -1) { throw 'Could not find "const ALBUMS = [" in index.html' }
$arrayStart = $html.IndexOf('[', $marker)
$arrayEnd = $html.IndexOf("`n];", $arrayStart)
if ($arrayEnd -eq -1) { throw 'Could not find end of ALBUMS array in index.html' }
$arrayEnd = $arrayEnd + 2 # include the closing ']'
$json = $html.Substring($arrayStart, $arrayEnd - $arrayStart)

# ConvertFrom-Json on top-level JSON array text returns it as a single
# Object[] here -- plain assignment preserves that correctly. Wrapping the
# expression in @(...) or ,(...) adds an *extra* nesting level in that case
# (verified against this repo's real 500-entry ALBUMS array), so only
# coerce to an array in the (untested-in-practice) case it isn't one already.
$albums = $json | ConvertFrom-Json
if ($albums -isnot [array]) { $albums = @($albums) }
if ($albums.Count -lt 2) { throw "Parsed only $($albums.Count) album(s) from index.html -- expected ~500. Aborting without writing." }

$merged = 0
$skipped = 0
foreach ($a in $albums) {
    $m = $byRank[[int]$a.rank]
    if (-not $m -or -not $m.best) {
        $skipped++
        continue
    }

    if (-not $a.links) {
        $a | Add-Member -NotePropertyName links -NotePropertyValue ([pscustomobject]@{ spotify = $m.best }) -Force
    } elseif ($a.links.PSObject.Properties.Name -contains 'spotify') {
        $a.links.spotify = $m.best
    } else {
        $a.links | Add-Member -NotePropertyName spotify -NotePropertyValue $m.best
    }
    $merged++
}

$newArrayText = $albums | ConvertTo-Json -Depth 6
$newArrayText = $newArrayText -replace '\\u0026', '&' -replace '\\u0027', "'"

$newHtml = $html.Substring(0, $arrayStart) + $newArrayText + $html.Substring($arrayEnd)
[System.IO.File]::WriteAllText($IndexHtml, $newHtml, $Utf8NoBom)

Write-Host "Merged $merged Spotify links into index.html ($skipped skipped / no match)."
