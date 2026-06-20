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
 *   node add-to-gp-albums.js --skip-ambiguous     # flag multi-match files instead of adding a best-guess
 *
 * Safety: writes ONLY to "[Photos] X dry-run" albums. Resumable (progress file).
 * Throttled. Saves an error screenshot per failure and continues.
 * Ambiguity guard: if a filename matches >1 DIFFERENT photo in GP (e.g. DSC_0059.JPG,
 * MOVIE.mp4), by DEFAULT the most-relevant match is still ADDED but flagged "verify" (wrong
 * picks cluster by date in the dry-run album = easy to spot + delete; right picks save you the
 * manual add). Use --skip-ambiguous to flag WITHOUT adding. Every ambiguous + not-found file is
 * listed in gp-manual-review.txt to resolve by hand.
 * --------------------------------------------------------------------------
 */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// ---- config ----
const DATA     = '/Users/user/Pictures/Photos/z-PROJECT/gp_album_additions.json';
const PROFILE  = path.join(__dirname, 'gp-profile');         // persistent login (created on first run)
const PROGRESS = path.join(__dirname, 'gp-add-progress.json');
const SHOTS    = path.join(__dirname, 'shots');

const args  = process.argv.slice(2);
const only  = args.includes('--only')  ? args[args.indexOf('--only')  + 1] : null;
const limit = args.includes('--limit') ? parseInt(args[args.indexOf('--limit') + 1], 10) : Infinity;
const slowMo = args.includes('--headful-slow') ? 250 : 60;
const skipAmbiguous = args.includes('--skip-ambiguous'); // default: ADD GP's best match + flag it

const sleep  = ms => new Promise(r => setTimeout(r, ms));
const jitter = (a, b) => Math.round(a + Math.random() * (b - a));
const MOD = process.platform === 'darwin' ? 'Meta' : 'Control';

(async () => {
  if (!fs.existsSync(SHOTS)) fs.mkdirSync(SHOTS, { recursive: true });
  const data = JSON.parse(fs.readFileSync(DATA, 'utf8'));
  const progress = fs.existsSync(PROGRESS) ? JSON.parse(fs.readFileSync(PROGRESS, 'utf8')) : {};
  const save = () => fs.writeFileSync(PROGRESS, JSON.stringify(progress, null, 1));

  // Ctrl+C: still flush progress + the ambiguous-review list before quitting.
  process.on('SIGINT', () => {
    console.log('\n[interrupted] saving progress + ambiguous review…');
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
  // NOTE: never browser.close() — it's your real Chrome.

  let added = 0, addedAmbiguous = 0, skippedAmbiguous = 0;
  for (const name of names) {
    const album = data[name].dryrun_album;
    progress[name]                = progress[name] || {};
    progress[name].done           = progress[name].done           || [];
    progress[name].notFound       = progress[name].notFound       || [];
    progress[name].ambiguous      = progress[name].ambiguous      || [];   // >1 GP match -> verify
    progress[name].ambiguousN     = progress[name].ambiguousN     || {};   // filename -> #matches
    progress[name].ambiguousAdded = progress[name].ambiguousAdded || {};   // filename -> best-guess added?
    console.log(`\n=== ${name}  ->  "${album}"  (${data[name].count} photos) ===`);
    for (const filename of data[name].filenames) {
      if (added >= limit) { console.log('Reached --limit.'); save(); writeManualReview(progress, data); return; }
      if (progress[name].done.includes(filename) ||
          progress[name].notFound.includes(filename) ||
          progress[name].ambiguous.includes(filename)) continue;
      try {
        const r = await addOne(page, filename, album);
        if (r === 'notfound') {
          progress[name].notFound.push(filename);
          console.log(`  –  not in GP search: ${filename}`);
        } else if (r && r.status === 'ambiguous') {
          progress[name].ambiguous.push(filename);
          progress[name].ambiguousN[filename] = r.n;
          progress[name].ambiguousAdded[filename] = !!r.added;
          if (r.added) { added++; addedAmbiguous++; console.log(`  +? added BEST-GUESS (${r.n} matches — verify): ${filename}`); }
          else         { skippedAmbiguous++;        console.log(`  ?  AMBIGUOUS (${r.n} matches) — skipped:          ${filename}`); }
        } else {
          progress[name].done.push(filename); added++;
          console.log(`  +  added:            ${filename}`);
        }
        save();
      } catch (e) {
        const shot = path.join(SHOTS, `${name}__${filename.replace(/[^\w.-]/g, '_')}.png`);
        try { await page.screenshot({ path: shot }); } catch {}
        console.log(`  !  ERROR ${filename}: ${e.message}\n     screenshot -> ${shot}`);
      }
      await sleep(jitter(700, 1600)); // throttle (be polite, avoid rate-limit)
    }
  }
  writeManualReview(progress, data);
  console.log(`\nDone this run. Added ${added} (incl. ${addedAmbiguous} ambiguous best-guesses), skipped-ambiguous ${skippedAmbiguous}. Progress: ${PROGRESS}.`);
  console.log(`Needs-manual-attention list (verify auto-added + not-found): ${path.join(__dirname, 'gp-manual-review.txt')}`);
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

  // Make sure the search actually navigated (URL -> /search/...) before reading results: right after
  // goto() the main library is still on screen, and counting THOSE tiles is what made DSC_0006 look
  // like "32 matches". Then wait for the results grid to truly render (or a genuine "No results").
  await page.waitForURL(/\/search\//, { timeout: 8000 }).catch(() => {});
  const total = await waitForResults(page);
  if (!total) return 'notfound';

  // AMBIGUITY GUARD: a filename like DSC_0059.JPG / MOVIE.mp4 can match several DIFFERENT photos.
  // GP duplicates tiles across a "Most relevant" strip + dated groups, so we count DISTINCT photos
  // (by media key). >1 distinct => don't guess which one; flag it for your manual review instead.
  const m = await analyzeMatches(page);
  const isAmbiguous = (m.unique > 1 || (m.multiUI && m.unique !== 1));
  // Default: still ADD GP's most-relevant match (right ones get auto-added; wrong ones land in a
  // different date-cluster in the dry-run album = easy to spot + remove) but FLAG it for verification.
  // With --skip-ambiguous: don't add, just flag.
  if (isAmbiguous && skipAmbiguous) return { status: 'ambiguous', n: m.unique || m.raw, added: false };

  // select GP's first (most-relevant) match — robust: settle, hover-reveal the checkbox, retry,
  // and back out if a click accidentally opens the photo instead of selecting it.
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
  return isAmbiguous ? { status: 'ambiguous', n: m.unique || m.raw, added: true } : 'added';
}

// Select the first result via its hover-checkbox (top-left corner of the tile). Instead of fixed
// sleeps, we POLL: wait only until the tile stops moving (so the checkbox is where we aim), click,
// then quickly check for "N selected"; on a miss we retry fast (a stray click can OPEN the photo, so
// we back out of that first). Fast on a hit (~1s), cheap on a miss — no 4-5s dead time per photo.
async function selectFirstPhoto(page) {
  const photo = page.getByRole('link', { name: /^Photo/ }).first();
  const selected = page.getByText(/\b\d+ selected\b/).first();
  await photo.scrollIntoViewIfNeeded().catch(() => {});
  for (let attempt = 0; attempt < 6; attempt++) {
    // poll until the tile's position is stable (fast when it's already settled)
    let b = null, prev = null;
    for (let i = 0; i < 10; i++) {
      b = await photo.boundingBox().catch(() => null);
      if (b && prev && Math.abs(b.x - prev.x) < 2 && Math.abs(b.y - prev.y) < 2) break;
      prev = b;
      await sleep(200);
    }
    if (b) {
      await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);  // hover reveals the checkbox
      await sleep(300);
      await page.mouse.click(b.x + 16, b.y + 16);                    // click the checkmark
      try { await selected.waitFor({ timeout: 1500 }); return true; } catch {} // quick check, not a long wait
    }
    // a click can accidentally OPEN the photo instead of selecting -> return to results, then retry
    if (!page.url().includes('/search/')) {
      await page.goBack({ waitUntil: 'domcontentloaded' }).catch(() => {});
      await page.waitForURL(/\/search\//, { timeout: 4000 }).catch(() => {});
    }
    await sleep(250);
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

// Wait until the search results grid actually renders (>=1 photo tile) or GP genuinely shows
// "No results". CRITICAL: never conclude 0 just because the grid hasn't painted yet — GP transiently
// shows an empty / "No results" state while loading, and treating that as "no match" caused false
// "not in GP" misses on photos that were really there. Once photos appear, let the count settle so
// the ambiguity check is accurate. Returns the settled count (0 => truly none).
async function waitForResults(page) {
  const tiles = () => page.getByRole('link', { name: /^Photo/ }).count();
  for (let i = 0; i < 20; i++) {              // up to ~12s for results to load
    const n = await tiles();
    if (n > 0) {                              // photos present -> let the count stop growing
      let stable = n;
      for (let j = 0; j < 6; j++) {
        await sleep(300);
        const n2 = await tiles();
        if (n2 === stable) return stable;     // two equal reads => settled (min ~300ms)
        stable = n2;
      }
      return stable;
    }
    if (i >= 5 && await page.getByText('No results').count()) return 0; // genuinely none (after ~3s)
    await sleep(600);
  }
  return 0;
}

// How many DISTINCT photos match the current search? GP repeats the SAME photo across a
// "Most relevant to your search" strip and the dated groups, so we dedupe tiles by their stable
// media key (the AF1Qip… token in href/jslog, else the per-photo aria-label). multiUI = GP showed
// its multi-result ranking header (a strong "more than one match" signal on its own).
async function analyzeMatches(page) {
  return await page.evaluate(() => {
    const tiles = Array.from(document.querySelectorAll('a[aria-label^="Photo"], a[href*="/photo/"]'));
    const keys = new Set();
    for (const a of tiles) {
      const hay = (a.getAttribute('href') || '') + '|' +
                  (a.getAttribute('aria-label') || '') + '|' +
                  (a.getAttribute('data-id') || '') + '|' +
                  (a.getAttribute('jslog') || '');
      const tok = hay.match(/AF1Qip[\w-]+/) || hay.match(/[A-Za-z0-9_-]{22,}/);
      keys.add(tok ? tok[0] : hay);
    }
    const multiUI = /Most relevant to your search/i.test(document.body.innerText || '');
    return { raw: tiles.length, unique: keys.size, multiUI };
  });
}

// One human-friendly list of everything needing a manual look: AMBIGUOUS (>1 GP match) and
// NOT-FOUND (0 GP matches). So every file the script couldn't safely auto-add is in one place.
function writeManualReview(progress, data) {
  const body = [];
  let ambT = 0, nfT = 0;
  for (const name of Object.keys(progress)) {
    const amb = progress[name].ambiguous || [];
    const nf  = progress[name].notFound  || [];
    if (!amb.length && !nf.length) continue;
    const album   = data[name] ? data[name].dryrun_album : '';
    const addedMap = progress[name].ambiguousAdded || {};
    const nMap     = progress[name].ambiguousN || {};
    body.push(`## ${name}  ->  "${album}"`);
    for (const f of amb) {
      const tag = addedMap[f] ? 'VERIFY auto-added' : 'ADD manually';
      body.push(`   [${tag}: ${nMap[f] || '?'} matches]  ${f}`);
    }
    for (const f of nf)  body.push(`   [not found in GP]                ${f}`);
    body.push('');
    ambT += amb.length; nfT += nf.length;
  }
  const head = [
    `NEEDS MANUAL ATTENTION — ${ambT} ambiguous + ${nfT} not-found file(s).`,
    'VERIFY auto-added = the best (most-relevant) GP match WAS added; open the dry-run album and confirm',
    '   it is really this person\'s photo. If it is the wrong one (usually a different date cluster), remove',
    '   it and search the quoted "filename" to add the correct match.',
    'ADD manually    = nothing was added (you ran with --skip-ambiguous); search + add it yourself.',
    'not found       = the quoted-filename search returned nothing (different name in GP, or not uploaded).',
    '',
  ];
  try { fs.writeFileSync(path.join(__dirname, 'gp-manual-review.txt'), head.concat(body).join('\n')); } catch {}
}
