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
 *   node add-to-gp-albums.js                      # all, smallest -> largest
 *   node add-to-gp-albums.js --only "Contributor Three"   # one contributor (TEST FIRST)
 *   node add-to-gp-albums.js --only "Contributor One"     # tests create + add-to-existing
 *   node add-to-gp-albums.js --limit 3            # stop after N additions (testing)
 *   node add-to-gp-albums.js --headful-slow       # extra slow-mo to watch/debug
 *
 * Safety: writes ONLY to "[Photos] X dry-run" albums. Resumable (progress file).
 * Throttled. Saves an error screenshot per failure and continues.
 * Multiple matches: if a filename matches several different photos in GP (e.g. DSC_0059.JPG), the
 * most-relevant match is added (best guess) — review each dry-run album by eye before merging;
 * wrong picks cluster by date, easy to spot + remove.
 * Videos & GIFs/animations (incl. Google Photos "Creations") are SKIPPED automatically (their tiles
 * can't be reliably checkbox-selected) and listed in gp-manual-review.txt for manual adding — along
 * with not-found files. Photos are the script's job; moving images are yours.
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
// --data lets us point at a different list (e.g. the videos file) without editing the script.
const DATA     = args.includes('--data') ? args[args.indexOf('--data') + 1]
                                         : '/Users/user/Pictures/Photos/z-PROJECT/gp_album_additions.json';
const PROFILE  = path.join(__dirname, 'gp-profile');         // persistent login (created on first run)
const PROGRESS = path.join(__dirname, 'gp-add-progress.json');
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
    progress[name].skipped  = progress[name].skipped  || [];   // videos/GIFs -> add by hand
    console.log(`\n[${ts()}] === ${name}  ->  "${album}"  (${data[name].count} photos) ===`);
    for (const filename of data[name].filenames) {
      if (added >= limit) { console.log('Reached --limit.'); save(); writeManualReview(progress, data); return; }
      if (progress[name].done.includes(filename) ||
          progress[name].notFound.includes(filename) ||
          progress[name].skipped.includes(filename)) continue;
      if (MOVING.test(filename)) {                              // video/GIF -> skip, list for manual add
        progress[name].skipped.push(filename); save();
        console.log(`  [${ts()}]  ⊘  skipped (video/GIF — add manually): ${filename}`);
        continue;
      }
      try {
        const r = await withTimeout(addOne(page, filename, album), 75000); // never hang on one item
        if (r === 'notfound') {
          progress[name].notFound.push(filename);
          console.log(`  [${ts()}]  –  not in GP search: ${filename}`);
        } else {
          progress[name].done.push(filename); added++;
          console.log(`  [${ts()}]  +  added:  ${filename}`);
        }
        save();
      } catch (e) {
        const shot = path.join(SHOTS, `${name}__${filename.replace(/[^\w.-]/g, '_')}.png`);
        try { await page.screenshot({ path: shot }); } catch {}
        console.log(`  [${ts()}]  !  ERROR ${filename}: ${e.message}\n     screenshot -> ${shot}`);
      }
      await sleep(jitter(700, 1600)); // throttle (be polite, avoid rate-limit)
    }
  }
  writeManualReview(progress, data);
  const skTot = Object.values(progress).reduce((s, v) => s + (v.skipped  || []).length, 0);
  const nfTot = Object.values(progress).reduce((s, v) => s + (v.notFound || []).length, 0);
  console.log(`\n[${ts()}] Done this run. Added ${added} this run. Manual-attention totals: ${skTot} video/GIF skipped, ${nfTot} not-found.`);
  console.log(`Manual list: ${path.join(__dirname, 'gp-manual-review.txt')}  ·  Progress: ${PROGRESS}.`);
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
  const total = await waitForResults(page);
  if (!total) return 'notfound';

  // Select GP's first (most-relevant) match and add it. If a filename matches several different
  // photos (DSC_0059.JPG etc.), this adds the best guess — wrong picks land in a different date
  // cluster in the dry-run album, easy to spot + remove on review. (We don't try to auto-detect
  // ambiguity: GP leaves the whole library grid in the page DOM behind the results, so a reliable
  // match count isn't possible from the page — and a counter that flags everything is just noise.)
  if (!(await selectFirstPhoto(page))) throw new Error('could not select the photo (checkbox never registered)');

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
async function selectFirstPhoto(page) {
  const onResults = () => page.url().includes('/search/') && !page.url().includes('/photo/');
  const link = page.getByRole('link', { name: /^Photo/ }).first();
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
  // fallback: "+" is in the top-right icon cluster
  const vw = page.viewportSize().width;
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
async function waitForResults(page) {
  const tiles = () => page.getByRole('link', { name: /^Photo/ }).count();
  for (let i = 0; i < 20; i++) {                                        // up to ~10s for results
    if (await tiles() > 0) return 1;
    if (i >= 5 && await page.getByText('No results').count()) return 0; // genuinely none (after ~3s)
    await sleep(500);
  }
  return 0;
}

// List the NOT-FOUND files (quoted-filename search returned nothing) so you can handle them by hand.
function writeManualReview(progress, data) {
  const body = [];
  let nfT = 0, skT = 0;
  for (const name of Object.keys(progress)) {
    const nf = progress[name].notFound || [];
    const sk = progress[name].skipped  || [];
    if (!nf.length && !sk.length) continue;
    const album = data[name] ? data[name].dryrun_album : '';
    body.push(`## ${name}  ->  "${album}"`);
    for (const f of sk) body.push(`   [video/GIF — add manually] ${f}`);
    for (const f of nf) body.push(`   [not found in GP]          ${f}`);
    body.push('');
    nfT += nf.length; skT += sk.length;
  }
  const head = [
    `MANUAL ATTENTION — ${skT} video/GIF skipped + ${nfT} not-found.`,
    'video/GIF  = intentionally skipped (videos & animations/Creations need manual adding); search the',
    '             quoted "filename" in GP, pick it, add to its dry-run album.',
    'not found  = quoted-filename search returned nothing (different name in GP, or never uploaded; the',
    '             latter belong to the separate "upload to GP" set).',
    '',
  ];
  try { fs.writeFileSync(path.join(__dirname, 'gp-manual-review.txt'), head.concat(body).join('\n')); } catch {}
}
