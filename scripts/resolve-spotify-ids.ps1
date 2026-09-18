<#
.SYNOPSIS
One-off data-authoring script -- NOT part of the deployed page.

Looks up a candidate Spotify album ID for every ALBUMS entry in index.html
that doesn't already have one, and writes the candidates to
scripts/spotify-matches.json for manual review before merging.

Safe to interrupt and re-run: progress is checkpointed to
scripts/spotify-matches.json as it goes (via a temp-file-then-rename so the
file is never left half-written), and on startup any entry already recorded
there with status "ok" is skipped rather than re-queried. Entries that
previously failed (status "error") are retried.

.PARAMETER DelayMilliseconds
Flat pause between successful requests, to stay under Spotify's rate limit.

.PARAMETER CheckpointEvery
Write progress to disk after this many albums are processed (in addition to
the final write at the end).

.PARAMETER MaxRetries
Max retry attempts for a single album lookup on 429 / 502 / 503 / 504 /
network errors before giving up and marking it "error" for the next run.

.PARAMETER RetryBaseSeconds
Base for the exponential backoff used on retries (doubles each attempt,
capped at 30s), except when Spotify sends a Retry-After header on a 429, in
which case that value is used instead.

.EXAMPLE
$env:SPOTIFY_CLIENT_ID = "xxx"
$env:SPOTIFY_CLIENT_SECRET = "yyy"
.\scripts\resolve-spotify-ids.ps1

.EXAMPLE
.\scripts\resolve-spotify-ids.ps1 -ClientId xxx -ClientSecret yyy -DelayMilliseconds 600

See scripts/README.md for how to get a client id/secret.
#>

param(
    [string]$ClientId = $env:SPOTIFY_CLIENT_ID,
    [string]$ClientSecret = $env:SPOTIFY_CLIENT_SECRET,
    [int]$DelayMilliseconds = 400,
    [int]$CheckpointEvery = 10,
    [int]$MaxRetries = 5,
    [int]$RetryBaseSeconds = 2
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

function Read-Checkpoint {
    $checkpoint = @{}
    if (-not (Test-Path $OutputFile)) { return $checkpoint }

    try {
        $raw = [System.IO.File]::ReadAllText($OutputFile) | ConvertFrom-Json
        if ($raw -isnot [array]) { $raw = @($raw) }
        foreach ($entry in $raw) {
            $checkpoint[[int]$entry.rank] = $entry
        }
        Write-Host "Resuming from checkpoint: $($checkpoint.Count) entries already recorded in $OutputFile"
    } catch {
        Write-Warning "Could not parse existing $OutputFile as a checkpoint -- starting fresh. ($($_.Exception.Message))"
    }
    return $checkpoint
}

function Save-Results {
    param([array]$Results)
    $tmpFile = "$OutputFile.tmp"
    $json = $Results | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tmpFile, $json, $Utf8NoBom)
    Move-Item -Path $tmpFile -Destination $OutputFile -Force
}

function Get-AccessToken {
    $pair = "${ClientId}:${ClientSecret}"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $res = Invoke-RestMethod -Uri 'https://accounts.spotify.com/api/token' -Method Post `
        -Headers @{ Authorization = "Basic $basic" } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body 'grant_type=client_credentials'
    return [pscustomobject]@{
        Token     = $res.access_token
        # Refresh a little early rather than racing the exact expiry.
        ExpiresAt = (Get-Date).AddSeconds([int]$res.expires_in - 60)
    }
}

function Search-Album {
    param(
        [string]$Token,
        [string]$Artist,
        [string]$Album,
        [int]$Rank,
        [int]$MaxRetries,
        [int]$RetryBaseSeconds
    )

    $label = "#$Rank $Artist - $Album"
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $q = "album:$Album artist:$Artist"
            $url = 'https://api.spotify.com/v1/search?type=album&limit=5&q=' + [Uri]::EscapeDataString($q)
            $res = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $Token" }
            return @($res.albums.items)
        } catch {
            $resp = $_.Exception.Response
            $status = $null
            if ($resp) { try { $status = [int]$resp.StatusCode } catch {} }

            $isRetryable = ($status -eq 429) -or ($status -in 502, 503, 504) -or (-not $status)
            if (-not $isRetryable -or $attempt -gt $MaxRetries) {
                throw
            }

            $wait = [Math]::Min($RetryBaseSeconds * [Math]::Pow(2, $attempt - 1), 30)

            if ($status -eq 429) {
                $retryAfter = $null
                try { $retryAfter = [int]($resp.Headers['Retry-After']) } catch {}
                if ($retryAfter) { $wait = $retryAfter }
                $resumeAt = (Get-Date).AddSeconds($wait).ToString('HH:mm:ss')
                Write-Host ("  [RATE LIMIT] {0}: got 429 (Retry-After={1}s), attempt {2}/{3}, resuming at {4}..." -f $label, $wait, $attempt, $MaxRetries, $resumeAt) -ForegroundColor Yellow
            } else {
                $reason = if ($status) { "HTTP $status" } else { $_.Exception.Message }
                Write-Host ("  [RETRY] {0}: {1}, attempt {2}/{3}, waiting {4}s..." -f $label, $reason, $attempt, $MaxRetries, $wait) -ForegroundColor Yellow
            }

            Start-Sleep -Seconds $wait
        }
    }
}

$albums = Read-Albums
$checkpoint = Read-Checkpoint
$tokenInfo = Get-AccessToken

$results = @()
$skippedExisting = 0
$resumedFromCheckpoint = 0
$processedThisRun = 0

foreach ($a in $albums) {
    if ($a.links -and $a.links.spotify) {
        $skippedExisting++
        continue
    }

    $rank = [int]$a.rank
    $cached = $checkpoint[$rank]
    if ($cached -and $cached.status -eq 'ok') {
        $results += $cached
        $resumedFromCheckpoint++
        continue
    }

    if ((Get-Date) -ge $tokenInfo.ExpiresAt) {
        Write-Host 'Access token nearing expiry -- refreshing...' -ForegroundColor Cyan
        $tokenInfo = Get-AccessToken
    }

    $items = @()
    $status = 'ok'
    try {
        $items = Search-Album -Token $tokenInfo.Token -Artist $a.artist -Album $a.album -Rank $rank -MaxRetries $MaxRetries -RetryBaseSeconds $RetryBaseSeconds
    } catch {
        $status = 'error'
        Write-Warning ("  [FAILED] #{0} {1} - {2}: {3} (will retry on next run)" -f $rank, $a.artist, $a.album, $_.Exception.Message)
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
        rank       = $rank
        artist     = $a.artist
        album      = $a.album
        year       = $a.year
        candidates = $candidates
        # Best guess only -- REVIEW before running merge-spotify-ids.ps1.
        # Set to $null (or leave candidates empty) to skip an entry.
        best       = $best
        status     = $status
    }

    if ($status -eq 'error') {
        # already logged above
    } elseif ($candidates.Count -gt 0) {
        $top = $candidates[0]
        Write-Host ("#{0} {1} - {2} -> {3} ({4}, {5})" -f $rank, $a.artist, $a.album, $top.name, $top.artists, $top.releaseDate)
    } else {
        Write-Host ("#{0} {1} - {2} -> NO MATCH" -f $rank, $a.artist, $a.album)
    }

    $processedThisRun++
    if ($processedThisRun % $CheckpointEvery -eq 0) {
        Save-Results -Results $results
        Write-Host ("  -- checkpoint saved ({0} entries) --" -f $results.Count) -ForegroundColor DarkGray
    }

    Start-Sleep -Milliseconds $DelayMilliseconds
}

Save-Results -Results $results

Write-Host ""
Write-Host "Skipped $skippedExisting entries that already had links.spotify."
if ($resumedFromCheckpoint -gt 0) {
    Write-Host "Reused $resumedFromCheckpoint entries already resolved in a previous run."
}
Write-Host "Wrote $($results.Count) entries to $OutputFile"
$errorCount = @($results | Where-Object { $_.status -eq 'error' }).Count
if ($errorCount -gt 0) {
    Write-Host "$errorCount entries failed and are marked status=error -- re-run this script to retry just those." -ForegroundColor Yellow
}
Write-Host 'Review each "best" field (and "candidates") before running merge-spotify-ids.ps1 --'
Write-Host 'search is fuzzy and will misfire on compilations, reissues, and "Various Artists" entries.'
