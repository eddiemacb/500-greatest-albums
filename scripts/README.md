# Spotify link resolution

One-off scripts for populating `links.spotify` on `ALBUMS` entries in
`index.html`. These run locally, once in a while, by hand — they are not
part of the deployed page and add no runtime dependency to it.

## Setup

1. Create a Spotify Developer app at https://developer.spotify.com/dashboard
   (free, just needs a Spotify account) to get a `Client ID` and
   `Client Secret`.
2. Requires PowerShell (ships with Windows) — no install needed.

## Usage

```powershell
$env:SPOTIFY_CLIENT_ID = "xxx"
$env:SPOTIFY_CLIENT_SECRET = "yyy"
.\scripts\resolve-spotify-ids.ps1
```

(or pass `-ClientId`/`-ClientSecret` directly instead of using env vars).

This searches Spotify for every album that doesn't yet have a
`links.spotify` value and writes candidates to `scripts/spotify-matches.json`
(git-ignored — it's a scratch file, not checked in).

**Review that file before merging.** Search is fuzzy and will misfire on
compilations, reissues, and albums with punctuation/diacritics differences
(e.g. "Dónde Están los Ladrones") or ambiguous "Various Artists" credits.
For each entry, check the `best` id against its `candidates` list and the
matched `name`/`artists`/`releaseDate`, and fix or null out anything wrong.

Once you're happy with the file:

```powershell
.\scripts\merge-spotify-ids.ps1
```

This writes the reviewed `links.spotify` values into `index.html`'s
`ALBUMS` array. It round-trips the whole array through PowerShell's JSON
cmdlets, which happens to match the file's existing formatting almost
exactly (that's how it was originally authored), so the diff should stay
small and limited to entries that actually changed. Review the diff, then
delete `scripts/spotify-matches.json` (or leave it — it's git-ignored) and
commit.
