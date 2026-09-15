# Spotify link resolution

One-off scripts for populating `links.spotify` on `ALBUMS` entries in
`index.html`. These run locally, once in a while, by hand — they are not
part of the deployed page and add no runtime dependency to it.

## Setup

1. Create a Spotify Developer app at https://developer.spotify.com/dashboard
   (free, just needs a Spotify account) to get a `Client ID` and
   `Client Secret`.
2. Requires Node 18+ (uses the built-in `fetch`, no `npm install`).

## Usage

```sh
SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy node scripts/resolve-spotify-ids.js
```

This searches Spotify for every album that doesn't yet have a
`links.spotify` value and writes candidates to `scripts/spotify-matches.json`
(git-ignored — it's a scratch file, not checked in).

**Review that file before merging.** Search is fuzzy and will misfire on
compilations, reissues, and albums with punctuation/diacritics differences
(e.g. "Dónde Están los Ladrones") or ambiguous "Various Artists" credits.
For each entry, check the `best` id against its `candidates` list and the
matched `name`/`artists`/`releaseDate`, and fix or null out anything wrong.

Once you're happy with the file:

```sh
node scripts/merge-spotify-ids.js
```

This writes the reviewed `links.spotify` values into `index.html`'s
`ALBUMS` array and reformats that array to consistent JSON spacing — expect
a full-array diff even though only some entries actually changed. Review
the diff, then delete `scripts/spotify-matches.json` (or leave it — it's
git-ignored) and commit.
