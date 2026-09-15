// One-off data-authoring script — NOT part of the deployed page.
//
// Merges reviewed Spotify matches (scripts/spotify-matches.json) into the
// ALBUMS array in index.html. Run this only after reviewing each entry's
// "best" field in that file — resolve-spotify-ids.js's guesses are not
// trustworthy on their own.
//
// Usage: node scripts/merge-spotify-ids.js
//
// Note: this rewrites the whole ALBUMS array with consistent JSON
// formatting, so expect a full-array diff even though only some entries
// actually change.

const fs = require('fs');
const path = require('path');

const INDEX_HTML = path.join(__dirname, '..', 'index.html');
const MATCHES_FILE = path.join(__dirname, 'spotify-matches.json');

function readAlbums(html) {
  const marker = html.indexOf('const ALBUMS = [');
  if (marker === -1) throw new Error('Could not find "const ALBUMS = [" in index.html');
  const arrayStart = html.indexOf('[', marker);
  const arrayEnd = html.indexOf('\n];', arrayStart);
  if (arrayEnd === -1) throw new Error('Could not find end of ALBUMS array in index.html');
  const json = html.slice(arrayStart, arrayEnd + 2);
  return { albums: JSON.parse(json), arrayStart, arrayEnd: arrayEnd + 2 };
}

function main() {
  if (!fs.existsSync(MATCHES_FILE)) {
    console.error('No ' + MATCHES_FILE + ' found. Run resolve-spotify-ids.js first.');
    process.exit(1);
  }

  const matches = JSON.parse(fs.readFileSync(MATCHES_FILE, 'utf8'));
  const byRank = new Map(matches.map(m => [m.rank, m]));

  const html = fs.readFileSync(INDEX_HTML, 'utf8');
  const { albums, arrayStart, arrayEnd } = readAlbums(html);

  let merged = 0;
  let skipped = 0;
  for (const a of albums) {
    const m = byRank.get(a.rank);
    if (!m || !m.best) {
      skipped++;
      continue;
    }
    a.links = Object.assign({}, a.links, { spotify: m.best });
    merged++;
  }

  const newArrayText = JSON.stringify(albums, null, 4);
  const newHtml = html.slice(0, arrayStart) + newArrayText + html.slice(arrayEnd);
  fs.writeFileSync(INDEX_HTML, newHtml);

  console.log('Merged ' + merged + ' Spotify links into index.html (' + skipped + ' skipped / no match).');
}

main();
