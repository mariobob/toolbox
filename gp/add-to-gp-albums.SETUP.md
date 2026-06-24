# add-to-gp-albums.js — setup & run

Google refuses sign-in inside automation-launched browsers ("**Couldn't sign you in — this browser
or app may not be secure**"). So we **don't log in from automation**. We log in once with **normal
Chrome**, then attach the script to that already-logged-in session over Chrome's remote-debugging
port. Google's block is on the *login page*; an already-authenticated real-Chrome session is fine.

We use a **dedicated profile** `~/chrome-gp-automation` so this never touches your main Chrome (and
because Chrome refuses remote-debugging on the *default* profile).

---

## 1. Install (one-time)

```bash
cd gp && npm install        # installs playwright; no browser download (we attach to your own Chrome)
```

## 2. One-time Google login (normal Chrome, NO debug port)

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$HOME/chrome-gp-automation"
```

A fresh Chrome window opens → go to **https://photos.google.com** → **log in normally** (real Chrome,
so Google allows it) → confirm Photos loads → **quit that window** (Cmd+Q while focused). Login is now
saved in that profile.

## 3. Each run — launch that profile WITH the debug port

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222 --user-data-dir="$HOME/chrome-gp-automation"
```

It opens **already logged in**. **Leave it open and don't touch it** during the run. Your everyday
Chrome (different profile) is unaffected — keep using it.

## 4. Run the script (another Terminal tab)

```bash
cd gp

node add-to-gp-albums.js --only "Some Contributor"   # one contributor (testing)
node add-to-gp-albums.js --limit 3                   # stop after N additions (testing)
node add-to-gp-albums.js                             # all, smallest -> largest, resumable

# or point at your own files (otherwise the defaults next to the script are used):
node add-to-gp-albums.js --manifest /path/to/manifest.json --progress /path/to/progress.json
```

It attaches to the Chrome at `localhost:9222`, searches each `"filename"`, and adds it to
`[Photos] X dry-run`. Resumable (`gp-add-progress.json`), throttled, writes only to dry-run albums,
error screenshots go to `shots/`.

**Manifest format** (`--manifest`, default `gp-album-additions-manifest.json` next to the script):

```json
{
  "Some Contributor": {
    "real_album": "[Photos] Some Contributor",
    "dryrun_album": "[Photos] Some Contributor dry-run",
    "count": 2,
    "filenames": ["IMG_0001.JPG", "VID_0002.mp4"]
  }
}
```

Create the `[Photos] X dry-run` albums in Google Photos first (the script adds to them, and creates one
if missing). `count` is only used for smallest-first ordering. Photos and videos share the one
`filenames` list — the script routes each by extension.

Then in Google Photos: open each `[Photos] X dry-run` → eyeball → select-all → add to the real
`[Photos] X` → delete the dry-run.

**Multiple matches & review:** some names (e.g. `DSC_0059.JPG`) match **several different** photos in
Google Photos. The script adds GP's **most-relevant** match (best guess) — that's why you eyeball each
`[Photos] X dry-run` before merging: a wrong pick lands in a different **date cluster** in the album,
easy to spot and remove. Names that return **no** match are logged `–  not in GP search` and collected
in **`gp-manual-review.txt`** (those either have a different name in GP or were never uploaded).

---

**If it stops/misbehaves:** paste me the console line + the `shots/*.png` and I'll fix the selector.
**Flags:** `--only "<name>"`, `--limit <N>`, `--manifest <file>`, `--progress <file>`, `--review <file>`, env `CDP_URL` (default `http://localhost:9222`).

**Why CDP and not just a Playwright-launched Chrome?** Google flags automation-launched browsers
(`navigator.webdriver`, Chrome-for-Testing build) and blocks sign-in. Attaching to your real,
already-authenticated Chrome avoids the login flow entirely.
