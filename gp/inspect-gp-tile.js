#!/usr/bin/env node
/**
 * Read-only diagnostic. Dumps the DOM around the first search-result tile (esp. its selection
 * checkbox) so we can make video selection exact. It does NOT click or change anything.
 *
 * Run (Chrome already started with --remote-debugging-port=9222, see add-to-gp-albums.SETUP.md):
 *   node inspect-gp-tile.js "20190628_135032.mp4"      # the video that skipped
 * Then paste the whole output back to me.
 */
const { chromium } = require('playwright');
const MOD = process.platform === 'darwin' ? 'Meta' : 'Control';
const q = process.argv[2] || 'DSC_0012.JPG';

(async () => {
  const browser = await chromium.connectOverCDP(process.env.CDP_URL || 'http://localhost:9222');
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('photos.google.com')) || ctx.pages()[0] || await ctx.newPage();

  await page.goto('https://photos.google.com/', { waitUntil: 'domcontentloaded' });
  await page.getByRole('combobox', { name: /search your photos/i }).click();
  await page.keyboard.press(`${MOD}+A`);
  await page.keyboard.type(`"${q}"`, { delay: 8 });
  await page.keyboard.press('Enter');
  await page.waitForURL(/\/search\//, { timeout: 8000 }).catch(() => {});
  await page.getByRole('link', { name: /^Photo/ }).first().waitFor({ timeout: 12000 }).catch(() => {});
  await page.waitForTimeout(1500);

  console.log('search:', JSON.stringify(q));
  console.log('URL   :', page.url());

  // hover the first tile so the checkbox renders, then describe the cell + checkbox candidates
  const a0 = page.getByRole('link', { name: /^Photo/ }).first();
  const b = await a0.boundingBox().catch(() => null);
  if (b) { await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2); await page.waitForTimeout(600); }

  const info = await page.evaluate(() => {
    const a = document.querySelector('a[aria-label^="Photo"], a[href*="/photo/"]');
    if (!a) return { error: 'no result tile found' };
    let cell = a; for (let i = 0; i < 5 && cell.parentElement; i++) cell = cell.parentElement;
    const desc = el => {
      const r = el.getBoundingClientRect();
      return {
        tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || null,
        ariaLabel: el.getAttribute('aria-label') || null, ariaChecked: el.getAttribute('aria-checked') || null,
        title: el.getAttribute('title') || null, cls: (el.getAttribute('class') || '').slice(0, 50),
        rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
      };
    };
    const sel = '[role="checkbox"],[aria-checked],[aria-label*="elect" i],button,svg[aria-label]';
    const cands = Array.from(cell.querySelectorAll(sel)).slice(0, 12).map(desc);
    return { tile: desc(a), isVideo: /\bvideo\b|\b\d+:\d\d\b/i.test(a.getAttribute('aria-label') || ''), checkboxCandidates: cands };
  });
  console.log(JSON.stringify(info, null, 2));
  console.log('\n--- paste everything above back to Claude ---');
})();
