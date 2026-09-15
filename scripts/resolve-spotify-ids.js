// One-off data-authoring script — NOT part of the deployed page.
//
// Looks up a candidate Spotify album ID for every ALBUMS entry in
// index.html that doesn't already have one, and writes the candidates to
// scripts/spotify-matches.json for manual review before merging.
//
// Usage:
//   SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy node scripts/resolve-spotify-ids.js
//
// Requires Node 18+ (uses the built-in fetch — no npm install needed).
// See scripts/README.md for how to get a client id/secret.

const fs = require('fs');
const path = require('path');

const INDEX_HTML = path.join(__dirname, '..', 'index.html');
const OUTPUT_FILE = path.join(__dirname, 'spotify-matches.json');

const CLIENT_ID = process.env.SPOTIFY_CLIENT_ID;
const CLIENT_SECRET = process.env.SPOTIFY_CLIENT_SECRET;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error('Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET (from a Spotify Developer app) and re-run.');
  process.exit(1);
}

function readAlbums() {
  const html = fs.readFileSync(INDEX_HTML, 'utf8');
  const marker = html.indexOf('const ALBUMS = [');
  if (marker === -1) throw new Error('Could not find "const ALBUMS = [" in index.html');
  const arrayStart = html.indexOf('[', marker);
  const arrayEnd = html.indexOf('\n];', arrayStart);
  if (arrayEnd === -1) throw new Error('Could not find end of ALBUMS array in index.html');
  return JSON.parse(html.slice(arrayStart, arrayEnd + 2));
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function getAccessToken() {
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Authorization: 'Basic ' + Buffer.from(CLIENT_ID + ':' + CLIENT_SECRET).toString('base64')
    },
    body: 'grant_type=client_credentials'
  });
  if (!res.ok) throw new Error('Spotify auth failed: ' + res.status + ' ' + await res.text());
  const data = await res.json();
  return data.access_token;
}

async function searchAlbum(token, artist, album) {
  const q = 'album:' + album + ' artist:' + artist;
  const url = 'https://api.spotify.com/v1/search?type=album&limit=5&q=' + encodeURIComponent(q);
  const res = await fetch(url, { headers: { Authorization: 'Bearer ' + token } });

  if (res.status === 429) {
    const waitMs = Number(res.headers.get('retry-after') || '2') * 1000;
    await sleep(waitMs);
    return searchAlbum(token, artist, album);
  }
  if (!res.ok) throw new Error('Search failed (' + res.status + ')');

  const data = await res.json();
  return (data.albums && data.albums.items) || [];
}

async function main() {
  const albums = readAlbums();
  const token = await getAccessToken();
  const results = [];
  let skippedExisting = 0;

  for (const a of albums) {
    if (a.links && a.links.spotify) {
      skippedExisting++;
      continue;
    }

    let items = [];
    try {
      items = await searchAlbum(token, a.artist, a.album);
    } catch (err) {
      console.error('  ! #' + a.rank, a.artist, '-', a.album, ':', err.message);
    }

    const candidates = items.map(it => ({
      id: it.id,
      name: it.name,
      artists: it.artists.map(x => x.name).join(', '),
      releaseDate: it.release_date,
      url: it.external_urls && it.external_urls.spotify
    }));

    results.push({
      rank: a.rank,
      artist: a.artist,
      album: a.album,
      year: a.year,
      candidates,
      // Best guess only — REVIEW before running merge-spotify-ids.js.
      // Set to null (or leave candidates empty) to skip an entry.
      best: candidates.length ? candidates[0].id : null
    });

    const top = candidates[0];
    console.log(
      '#' + a.rank, a.artist, '-', a.album, '->',
      top ? top.name + ' (' + top.artists + ', ' + top.releaseDate + ')' : 'NO MATCH'
    );

    await sleep(120); // stay comfortably under Spotify's rate limit
  }

  fs.writeFileSync(OUTPUT_FILE, JSON.stringify(results, null, 2));
  console.log('\nSkipped ' + skippedExisting + ' entries that already had links.spotify.');
  console.log('Wrote ' + results.length + ' entries to ' + OUTPUT_FILE);
  console.log('Review each "best" field (and "candidates") before running merge-spotify-ids.js —');
  console.log('search is fuzzy and will misfire on compilations, reissues, and "Various Artists" entries.');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
