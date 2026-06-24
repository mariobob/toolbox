#!/usr/bin/env node
/**
 * add-to-gp-albums.js
 * --------------------------------------------------------------------------
 * Adds your "missing from Google Photos person-album" photos into per-contributor
 * DRY-RUN albums ("[Photos] X dry-run"), by exact-filename search. You then eyeball
 * each dry-run album in GP and bulk-merge it into the real "[Photos] X" album.
 *
 * Why this way: Google killed the personal Photos API and removed AND/OR search,
 * so the only path is driving the web UI, one exact-filename search at a time.
 *
 * Setup (already done):  npm i playwright  &&  npx playwright install chromium
 *
 * Run:
 *   node add-to-gp-albums.js                      # all photos, smallest -> largest
 *   node add-to-gp-albums.js --only "Contributor Three"   # one contributor (TEST FIRST)
 *   node add-to-gp-albums.js --only "Contributor One"     # tests create + add-to-existing
 *   node add-to-gp-albums.js --limit 3            # stop after N additions (testing)
 *   node add-to-gp-albums.js --headful-slow       # extra slow-mo to watch/debug
 *
 * VIDEOS: the same machinery adds videos too, via `--videos` (or the add-videos-to-gp-albums.js
 * launcher, which just sets that flag). Video mode reads the videos manifest, uses video-aware result
 * locators, and keeps its own progress + review files so it can't disturb a photo run:
 *   node add-videos-to-gp-albums.js --only "Contributor Two"   # smallest video set (TEST FIRST)
 *   node add-to-gp-albums.js --videos --only "Dino"         # equivalent, explicit flag
 * Without --videos, behavior is byte-for-byte the original photo flow.
 *
 * Safety: writes ONLY to "[Photos] X dry-run" albums. Resumable (progress file).
 * Throttled. Saves an error screenshot per failure and continues.
 * Multiple matches: if a filename matches several different photos in GP (e.g. DSC_0059.JPG), the
 * most-relevant match is added (best guess) — review each dry-run album by eye before merging;
 * wrong picks cluster by date, easy to spot + remove.
 * In PHOTO mode, videos & GIFs/animations (incl. Google Photos "Creations") are SKIPPED automatically
 * and listed in gp-manual-review.txt for manual adding — along with not-found files. In VIDEO mode they
 * ARE the job: each is searched, selected by its checkbox element, and added; a .MP4 that surfaces as a
 * motion-photo still (or nothing) is flagged for manual handling, never wrong-added.
 * --------------------------------------------------------------------------
 */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// ---- config ----
const args  = process.argv.slice(2);
const only  = args.includes('--only')  ? args[args.indexOf('--only')  + 1] : null;
const limit = args.includes('--limit') ? parseInt(args[args.indexOf('--limit') + 1], 10) : Infinity;
const slowMo = args.includes('--headful-slow') ? 250 : 60;
// VIDEOS mode (set by --videos, or by the add-videos-to-gp-albums.js launcher): process video/GIF files
// instead of skipping them, and use video-aware result locators (see "VIDEO MODE" notes below). When
// this flag is absent the script behaves byte-for-byte like the original photo flow.
const VIDEOS = args.includes('--videos');
// --data lets us point at a different list without editing the script; in --videos mode it defaults to
// the videos manifest instead of the photos one.
const DATA     = args.includes('--data') ? args[args.indexOf('--data') + 1]
               : VIDEOS ? '/Users/user/Pictures/Photos/z-PROJECT/gp_album_additions_videos.json'
                        : '/Users/user/Pictures/Photos/z-PROJECT/gp_album_additions.json';
const PROFILE  = path.join(__dirname, 'gp-profile');         // persistent login (created on first run)
// Separate progress + review files in video mode, so a video run can never corrupt the photo run's state.
const PROGRESS = path.join(__dirname, VIDEOS ? 'gp-add-progress-videos.json' : 'gp-add-progress.json');
const REVIEW   = path.join(__dirname, VIDEOS ? 'gp-manual-review-videos.txt' : 'gp-manual-review.txt');
const SHOTS    = path.join(__dirname, 'shots');

const sleep  = ms => new Promise(r => setTimeout(r, ms));
const jitter = (a, b) => Math.round(a + Math.random() * (b - a));
const ts     = () => new Date().toTimeString().slice(0, 8);   // HH:MM:SS prefix for log lines
// Hard cap per photo so a single problematic item (e.g. an odd video) can never stall the whole run.
const withTimeout = (p, ms) =>
  Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`item timeout after ${ms / 1000}s`)), ms))]);
const MOD = process.platform === 'darwin' ? 'Meta' : 'Control';
// Videos and GIFs/animations (incl. Google Photos "Creations") have tile UIs the checkbox-select can't
// reliably hit (center play button / sparkles). We SKIP them and list them for manual adding.
const MOVING = /\.(mp4|mov|m4v|3gp|3g2|avi|mkv|webm|wmv|flv|mpg|mpeg|mts|m2ts|insv|gif)$/i;

// VIDEO MODE notes (verified read-only with inspect-gp-tile.js against a real result):
//  • A video's VISIBLE search-result tile is labelled "Video – …" (photos are "Photo – …"); the hidden
//    home-grid tiles that also linger in the DOM are the "Photo – …" ones with a 0×0 rect. So the
//    result/locator regex MUST accept "Video", or every video would look like "not found".
//  • Its selection checkbox is the same div[role="checkbox"].ckGgle whose aria-label == the tile label,
//    sitting at the tile's TOP-LEFT — so the existing checkbox-element click + top-left pixel fallback
//    select videos correctly (never the centre play button). No checkbox change needed.
//  • Don't trust a "Video"/duration heuristic on the label: "…, 15:49:39" makes \d+:\d\d match the time.
//    The clean discriminator is the "Video" vs "Photo" tile-label PREFIX.
//  • Motion photos: a .MP4 that is the video half of a motion photo surfaces as a "Photo – …" still (or
//    nothing). We never auto-add those — they're flagged 'motion' for manual handling.
const TILE_RE = VIDEOS ? /^Video/ : /^Photo/;   // which result tiles this run drives/selects

(async () => {
  if (!fs.existsSync(SHOTS)) fs.mkdirSync(SHOTS, { recursive: true });
  const data = JSON.parse(fs.readFileSync(DATA, 'utf8'));
  const progress = fs.existsSync(PROGRESS) ? JSON.parse(fs.readFileSync(PROGRESS, 'utf8')) : {};
  const save = () => fs.writeFileSync(PROGRESS, JSON.stringify(progress, null, 1));

  // Ctrl+C: still flush progress + the not-found review list before quitting.
  process.on('SIGINT', () => {
    console.log('\n[interrupted] saving progress + review list…');
    try { save(); writeManualReview(progress, data); } catch {}
    process.exit(130);
  });

  let names = Object.keys(data).sort((a, b) => data[a].count - data[b].count); // smallest first
  if (only) names = names.filter(n => n === only);
  if (!names.length) { console.log('No matching contributors. --only must match a name exactly.'); process.exit(1); }

  // Attach to your REAL Chrome (already logged into Google) over the DevTools protocol.
  // Google blocks sign-in inside automation-launched browsers, so we never log in here —
  // we drive an already-authenticated real-Chrome session. Start Chrome first (see README):
  //   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  //       --remote-debugging-port=9222 --user-data-dir="$HOME/chrome-gp-automation"
  const CDP = process.env.CDP_URL || 'http://localhost:9222';
  let browser;
  try {
    browser = await chromium.connectOverCDP(CDP);
  } catch (e) {
    console.error(`\nCan't reach Chrome at ${CDP}.\nStart it with remote debugging first (see toolbox/README.md).\n  ${e.message}`);
    process.exit(1);
  }
  const ctx = browser.contexts()[0] || await browser.newContext();
  let page = ctx.pages().find(p => p.url().includes('photos.google.com')) || ctx.pages()[0] || await ctx.newPage();

  await page.goto('https://photos.google.com/', { waitUntil: 'domcontentloaded' });
  await ensureLoggedIn(page);
  page.setDefaultTimeout(20000); // snappier failures than Playwright's 30s default
  // NOTE: never browser.close() — it's your real Chrome.

  let added = 0;
  for (const name of names) {
    const album = data[name].dryrun_album;
    progress[name]          = progress[name] || {};
    progress[name].done     = progress[name].done     || [];
    progress[name].notFound = progress[name].notFound || [];
    progress[name].skipped  = progress[name].skipped  || [];   // videos/GIFs -> add by hand (photo runs)
    progress[name].failed   = progress[name].failed   || [];   // errored -> recorded, handle by hand
    progress[name].motion   = progress[name].motion   || [];   // .MP4 that surfaced as a still -> by hand
    console.log(`\n[${ts()}] === ${name}  ->  "${album}"  (${data[name].count} ${VIDEOS ? 'videos' : 'photos'}) ===`);
    for (const filename of data[name].filenames) {
      if (added >= limit) { console.log('Reached --limit.'); save(); writeManualReview(progress, data); return; }
      if (progress[name].done.includes(filename) ||
          progress[name].notFound.includes(filename) ||
          progress[name].skipped.includes(filename) ||
          progress[name].motion.includes(filename) ||
          progress[name].failed.includes(filename)) continue;
      if (!VIDEOS && MOVING.test(filename)) {                   // photo runs: video/GIF -> skip for manual add
        progress[name].skipped.push(filename); save();
        console.log(`  [${ts()}]  ⊘  skipped (video/GIF — add manually): ${filename}`);
        continue;
      }
      try {
        const r = await withTimeout(addOne(page, filename, album), 75000); // never hang on one item
        if (r === 'notfound') {
          progress[name].notFound.push(filename);
          console.log(`  [${ts()}]  –  not in GP search: ${filename}`);
        } else if (r === 'motion') {
          progress[name].motion.push(filename);
          console.log(`  [${ts()}]  ◐  motion-photo still / not a video — add manually: ${filename}`);
        } else {
          progress[name].done.push(filename); added++;
          console.log(`  [${ts()}]  +  added:  ${filename}`);
        }
        save();
      } catch (e) {
        progress[name].failed.push(filename); save();   // record so it shows up + isn't retried each run
        const shot = path.join(SHOTS, `${name}__${filename.replace(/[^\w.-]/g, '_')}.png`);
        try { await page.screenshot({ path: shot }); } catch {}
        console.log(`  [${ts()}]  !  ERROR (recorded) ${filename}: ${e.message}\n     screenshot -> ${shot}`);
      }
      await sleep(jitter(700, 1600)); // throttle (be polite, avoid rate-limit)
    }
  }
  writeManualReview(progress, data);
  const tot = k => Object.values(progress).reduce((s, v) => s + (v[k] || []).length, 0);
  console.log(`\n[${ts()}] Done this run. Added ${added} this run. Manual-attention totals: ${tot('skipped')} video/GIF skipped, ${tot('motion')} motion/still, ${tot('failed')} errored, ${tot('notFound')} not-found.`);
  console.log(`Manual list: ${REVIEW}  ·  Progress: ${PROGRESS}.`);
  console.log('Browser left open for review.');
})();

// Logged in only when the search combobox exists.
async function ensureLoggedIn(page) {
  for (let i = 0; i < 90; i++) {
    if (await searchBox(page).count()) return;
    if (i === 0) console.log('Log into Google Photos in the opened window if prompted…');
    await sleep(2000);
  }
  throw new Error('Not logged into Google Photos.');
}

const searchBox = page => page.getByRole('combobox', { name: /search your photos/i });

async function addOne(page, filename, album) {
  // clean state each photo
  await page.goto('https://photos.google.com/', { waitUntil: 'domcontentloaded' });
  const box = searchBox(page);
  await box.click();
  await page.keyboard.press(`${MOD}+A`);
  await page.keyboard.type(`"${filename}"`, { delay: 8 });
  await page.keyboard.press('Enter');

  // Wait for the search to actually navigate (URL -> /search/...) and the results grid to render,
  // or a genuine "No results". GP transiently shows an empty/"No results" state while loading, so we
  // never conclude "not found" until results are really absent (that false-negative bit us before).
  await page.waitForURL(/\/search\//, { timeout: 8000 }).catch(() => {});
  const total = await waitForResults(page, TILE_RE);
  if (!total) {
    // VIDEO MODE: a .MP4 search that surfaces a "Photo – …" still (motion photo) but no "Video – …" tile
    // must NEVER be auto-added. Flag it 'motion' for manual handling; "nothing at all" stays 'notfound'.
    if (VIDEOS && await page.getByRole('link', { name: /^Photo/ }).count()) return 'motion';
    return 'notfound';
  }

  // Select GP's first (most-relevant) match and add it. If a filename matches several different
  // photos (DSC_0059.JPG etc.), this adds the best guess — wrong picks land in a different date
  // cluster in the dry-run album, easy to spot + remove on review. (We don't try to auto-detect
  // ambiguity: GP leaves the whole library grid in the page DOM behind the results, so a reliable
  // match count isn't possible from the page — and a counter that flags everything is just noise.)
  if (!(await selectFirstPhoto(page, TILE_RE))) throw new Error('could not select the photo (checkbox never registered)');

  // "+" (Add to) -> "Album"
  await clickAddTo(page);
  await firstThatWorks(page, [
    () => page.getByRole('menuitem', { name: 'Album' }).click({ timeout: 3000 }),
    () => page.getByText('Album', { exact: true }).first().click({ timeout: 3000 }),
  ]);

  // dialog: pick existing dry-run album (pre-create them => instant), else create it
  const dlg = page.getByPlaceholder(/search albums/i);
  await dlg.waitFor({ timeout: 8000 });
  await dlg.fill(album);

  // The album list is a set of <li role="option">. Wait for our album to render, then click the
  // actual option element (not the inner <span>, which gets intercepted by the loading shimmer).
  const albumOpt = page.getByRole('option', { name: album }); // substring match on the option
  await albumOpt.first().waitFor({ state: 'visible', timeout: 25000 }).catch(() => {});

  if (await albumOpt.count()) {
    await clickOption(page, albumOpt.first());
  } else {
    // fallback: create it
    await clickOption(page, page.getByRole('option', { name: 'New album' }).first());
    await page.getByText('Add a title').click({ timeout: 5000 });
    await page.keyboard.type(album, { delay: 8 });
    await sleep(400);
    await firstThatWorks(page, [
      () => page.getByRole('button', { name: /^(Done|Save)$/i }).first().click({ timeout: 2500 }),
      () => page.mouse.click(24, 24),
    ]);
  }
  await sleep(1500);
  return 'added';
}

// Select the first SEARCH-RESULT photo via its hover-checkbox (top-left of the tile).
// HARD SAFETY: only ever act while on the results grid — URL contains "/search/" and NOT "/photo/".
// If a click opens the viewer (URL gains /photo/) or navigates anywhere else (e.g. back to the home
// library), we ABORT (return false) instead of clicking whatever is on screen. This is what prevents
// the catastrophic bug of selecting an unrelated photo (the home library's most-recent) and adding it.
// We never try to "recover" by pressing Escape / going back — that's exactly what jumped to home.
async function selectFirstPhoto(page, tileRe = /^Photo/) {
  const onResults = () => page.url().includes('/search/') && !page.url().includes('/photo/');
  const link = page.getByRole('link', { name: tileRe }).first();
  const selected = page.getByText(/\b\d+ selected\b/).first();
  for (let attempt = 0; attempt < 3; attempt++) {
    if (!onResults()) return false;                                  // never act off the results grid

    // PRIMARY: click the result's own selection checkbox ELEMENT. GP renders a div[role="checkbox"]
    // whose aria-label == the photo's label; clicking it selects reliably for photos AND videos (the
    // checkbox is separate from a video's center play button). Selector found via inspect-gp-tile.js.
    let label = null;
    try {
      await link.scrollIntoViewIfNeeded({ timeout: 3000 });
      await link.hover({ timeout: 3000 });                          // reveal the checkbox
      label = await link.getAttribute('aria-label');
    } catch {}
    if (label && onResults()) {
      const cb = page.getByRole('checkbox', { name: label, exact: true }).first();
      try { await cb.click({ timeout: 3000 }); await selected.waitFor({ timeout: 2500 }); return onResults(); } catch {}
    }
    if (!onResults()) return false;

    // FALLBACK: pixel-click the checkmark at the tile's top-left (proven for photos), top-left so we
    // never hit a video's center play button.
    const b = await link.boundingBox().catch(() => null);
    if (b) {
      await page.mouse.move(b.x + 16, b.y + 16);
      await sleep(300);
      await page.mouse.click(b.x + 16, b.y + 16);
      try { await selected.waitFor({ timeout: 2000 }); return onResults(); } catch {}
    }
    if (!onResults()) return false;              // a click opened the viewer / left the grid -> bail
    await sleep(300);
  }
  return false;
}

// the "+"/Add-to button in the selection toolbar (top-right). Try selectors, then positional fallback.
async function clickAddTo(page) {
  const tries = [
    () => page.getByRole('button', { name: /add to album|^add to|^add$/i }).first().click({ timeout: 2500 }),
    () => page.getByLabel(/add to/i).first().click({ timeout: 2500 }),
  ];
  for (const t of tries) { try { await t(); return; } catch {} }
  // fallback: "+" is in the top-right icon cluster. viewportSize() is null on CDP-attached real
  // Chrome, so read the width from the page instead (that null was the "reading 'width'" crash).
  const vw = await page.evaluate(() => window.innerWidth).catch(() => 1280);
  await page.mouse.click(vw - 116, 24);
}

async function firstThatWorks(page, fns) {
  let last;
  for (const f of fns) { try { await f(); return; } catch (e) { last = e; } }
  throw last;
}

// Click a dialog <li role="option">, waiting out the album-list loading shimmer that otherwise
// "intercepts pointer events". Retries, then force-clicks as a last resort.
async function clickOption(page, locator) {
  await page.locator('[role="progressbar"]').first().waitFor({ state: 'hidden', timeout: 12000 }).catch(() => {});
  await locator.scrollIntoViewIfNeeded().catch(() => {});
  for (let i = 0; i < 6; i++) {
    try { await locator.click({ timeout: 4000 }); return; }
    catch { await page.waitForTimeout(700); }
  }
  await locator.click({ force: true });
}

// Wait until search results render (>=1 photo) or GP genuinely shows "No results". CRITICAL: never
// conclude 0 just because the grid hasn't painted yet — GP transiently shows an empty / "No results"
// state while loading, and treating that as "no match" caused false "not in GP" misses. Returns 1
// (results present) or 0 (truly none). selectFirstPhoto settles the tile position itself.
async function waitForResults(page, tileRe = /^Photo/) {
  const tiles = () => page.getByRole('link', { name: tileRe }).count();
  const max = VIDEOS ? 24 : 20;                                        // videos: a touch more patience
  for (let i = 0; i < max; i++) {                                      // up to ~10s (photos) / ~12s (videos)
    if (await tiles() > 0) return 1;
    if (i >= (VIDEOS ? 8 : 5) && await page.getByText('No results').count()) {
      // PHOTO mode: original behavior — after ~3s, "No results" => genuinely none.
      // VIDEO mode: GP shows a stray "No results" facet WHILE the real video tile is still painting, so
      // only trust it once NO result tile of EITHER type ("Photo"/"Video") is present.
      if (!VIDEOS) return 0;
      if (!(await page.getByRole('link', { name: /^(Photo|Video)/ }).count())) return 0;
    }
    await sleep(500);
  }
  return 0;
}

// List everything needing a hand — skipped videos/GIFs, errored files, and not-found — by contributor.
function writeManualReview(progress, data) {
  const body = [];
  let nfT = 0, skT = 0, faT = 0, moT = 0;
  for (const name of Object.keys(progress)) {
    const nf = progress[name].notFound || [];
    const sk = progress[name].skipped  || [];
    const fa = progress[name].failed   || [];
    const mo = progress[name].motion   || [];
    if (!nf.length && !sk.length && !fa.length && !mo.length) continue;
    const album = data[name] ? data[name].dryrun_album : '';
    body.push(`## ${name}  ->  "${album}"`);
    for (const f of sk) body.push(`   [video/GIF — add manually]    ${f}`);
    for (const f of mo) body.push(`   [motion/still — add manually] ${f}`);
    for (const f of fa) body.push(`   [errored — add manually]      ${f}`);
    for (const f of nf) body.push(`   [not found in GP]             ${f}`);
    body.push('');
    nfT += nf.length; skT += sk.length; faT += fa.length; moT += mo.length;
  }
  const head = [
    `MANUAL ATTENTION — ${skT} video/GIF skipped + ${moT} motion/still + ${faT} errored + ${nfT} not-found.`,
    'video/GIF  = skipped in PHOTO runs (videos & animations/Creations are handled by the --videos run, or',
    '             add by hand); search the quoted "filename" in GP, pick it, add to its dry-run album.',
    'motion     = a .MP4 search surfaced a still (likely a motion photo) or a non-video tile; NOT auto-added',
    '             so we never wrong-add — find it in GP and add it by hand.',
    'errored    = the script could not select/add it (GP quirk, e.g. stacked photos); add it by hand.',
    '             Remove it from progress.failed if you want a re-run to retry it.',
    'not found  = quoted-filename search returned nothing (different name in GP, or never uploaded; the',
    '             latter belong to the separate "upload to GP" set).',
    '',
  ];
  try { fs.writeFileSync(REVIEW, head.concat(body).join('\n')); } catch {}
}
