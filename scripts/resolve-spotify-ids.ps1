<#
.SYNOPSIS
One-off data-authoring script -- NOT part of the deployed page.

Looks up a candidate Spotify album ID for every ALBUMS entry in index.html
that doesn't already have one, and writes the candidates to
scripts/spotify-matches.json for manual review before merging.

.EXAMPLE
$env:SPOTIFY_CLIENT_ID = "xxx"
$env:SPOTIFY_CLIENT_SECRET = "yyy"
.\scripts\resolve-spotify-ids.ps1

.EXAMPLE
.\scripts\resolve-spotify-ids.ps1 -ClientId xxx -ClientSecret yyy

See scripts/README.md for how to get a client id/secret.
#>

param(
    [string]$ClientId = $env:SPOTIFY_CLIENT_ID,
    [string]$ClientSecret = $env:SPOTIFY_CLIENT_SECRET
)

$ErrorActionPreference = 'Stop'

if (-not $ClientId -or -not $ClientSecret) {
    Write-Error 'Set SPOTIFY_CLIENT_ID/SPOTIFY_CLIENT_SECRET (from a Spotify Developer app), or pass -ClientId/-ClientSecret, and re-run.'
    exit 1
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$IndexHtml = Join-Path $RepoRoot 'index.html'
$OutputFile = Join-Path $PSScriptRoot 'spotify-matches.json'

function Read-Albums {
    # [System.IO.File]::ReadAllText auto-detects a BOM and otherwise assumes
    # UTF-8 -- unlike Get-Content -Raw, which on Windows PowerShell falls
    # back to the system ANSI codepage for a BOM-less file and silently
    # mangles any non-ASCII character (accents, em dashes, ...).
    $html = [System.IO.File]::ReadAllText($IndexHtml)
    $marker = $html.IndexOf('const ALBUMS = [')
    if ($marker -eq -1) { throw 'Could not find "const ALBUMS = [" in index.html' }
    $arrayStart = $html.IndexOf('[', $marker)
    $arrayEnd = $html.IndexOf("`n];", $arrayStart)
    if ($arrayEnd -eq -1) { throw 'Could not find end of ALBUMS array in index.html' }
    $json = $html.Substring($arrayStart, $arrayEnd - $arrayStart + 2)

    # ConvertFrom-Json on top-level JSON array text returns it as a single
    # Object[] here -- plain assignment preserves that correctly. Wrapping
    # the expression in @(...) or ,(...) adds an *extra* nesting level in
    # that case (verified against this repo's real 500-entry ALBUMS array),
    # so only coerce to an array in the case it isn't one already.
    $albums = $json | ConvertFrom-Json
    if ($albums -isnot [array]) { $albums = @($albums) }
    if ($albums.Count -lt 2) { throw "Parsed only $($albums.Count) album(s) from index.html -- expected ~500." }
    return $albums
}

function Get-AccessToken {
    $pair = "${ClientId}:${ClientSecret}"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $res = Invoke-RestMethod -Uri 'https://accounts.spotify.com/api/token' -Method Post `
        -Headers @{ Authorization = "Basic $basic" } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body 'grant_type=client_credentials'
    return $res.access_token
}

function Search-Album {
    param([string]$Token, [string]$Artist, [string]$Album)

    $q = "album:$Album artist:$Artist"
    $url = 'https://api.spotify.com/v1/search?type=album&limit=5&q=' + [Uri]::EscapeDataString($q)

    try {
        $res = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $Token" }
        return @($res.albums.items)
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 429) {
            $retryAfter = 2
            try { $retryAfter = [int]($resp.Headers['Retry-After']) } catch {}
            Start-Sleep -Seconds $retryAfter
            return Search-Album -Token $Token -Artist $Artist -Album $Album
        }
        throw
    }
}

$albums = Read-Albums
$token = Get-AccessToken
$results = @()
$skippedExisting = 0

foreach ($a in $albums) {
    if ($a.links -and $a.links.spotify) {
        $skippedExisting++
        continue
    }

    $items = @()
    try {
        $items = Search-Album -Token $token -Artist $a.artist -Album $a.album
    } catch {
        Write-Error ("  ! #{0} {1} - {2}: {3}" -f $a.rank, $a.artist, $a.album, $_.Exception.Message)
    }

    $candidates = @($items | ForEach-Object {
        [pscustomobject]@{
            id          = $_.id
            name        = $_.name
            artists     = ($_.artists | ForEach-Object { $_.name }) -join ', '
            releaseDate = $_.release_date
            url         = $_.external_urls.spotify
        }
    })

    $best = $null
    if ($candidates.Count -gt 0) { $best = $candidates[0].id }

    $results += [pscustomobject]@{
        rank       = $a.rank
        artist     = $a.artist
        album      = $a.album
        year       = $a.year
        candidates = $candidates
        # Best guess only -- REVIEW before running merge-spotify-ids.ps1.
        # Set to $null (or leave candidates empty) to skip an entry.
        best       = $best
    }

    if ($candidates.Count -gt 0) {
        $top = $candidates[0]
        Write-Host ("#{0} {1} - {2} -> {3} ({4}, {5})" -f $a.rank, $a.artist, $a.album, $top.name, $top.artists, $top.releaseDate)
    } else {
        Write-Host ("#{0} {1} - {2} -> NO MATCH" -f $a.rank, $a.artist, $a.album)
    }

    Start-Sleep -Milliseconds 150 # stay comfortably under Spotify's rate limit
}

$outJson = $results | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($OutputFile, $outJson, $Utf8NoBom)

Write-Host ""
Write-Host "Skipped $skippedExisting entries that already had links.spotify."
Write-Host "Wrote $($results.Count) entries to $OutputFile"
Write-Host 'Review each "best" field (and "candidates") before running merge-spotify-ids.ps1 --'
Write-Host 'search is fuzzy and will misfire on compilations, reissues, and "Various Artists" entries.'
