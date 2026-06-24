# add-to-gp-albums.js — setup & run

Google refuses sign-in inside automation-launched browsers ("**Couldn't sign you in — this browser
or app may not be secure**"). So we **don't log in from automation**. We log in once with **normal
Chrome**, then attach the script to that already-logged-in session over Chrome's remote-debugging
port. Google's block is on the *login page*; an already-authenticated real-Chrome session is fine.

We use a **dedicated profile** `~/chrome-gp-automation` so this never touches your main Chrome (and
because Chrome refuses remote-debugging on the *default* profile).

---

## 1. One-time login (normal Chrome, NO debug port)

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir="$HOME/chrome-gp-automation"
```

A fresh Chrome window opens → go to **https://photos.google.com** → **log in normally** (real Chrome,
so Google allows it) → confirm Photos loads → **quit that window** (Cmd+Q while focused). Login is now
saved in that profile.

## 2. Each run — launch that profile WITH the debug port

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222 --user-data-dir="$HOME/chrome-gp-automation"
```

It opens **already logged in**. **Leave it open and don't touch it** during the run. Your everyday
Chrome (different profile) is unaffected — keep using it.

## 3. Run the script (another Terminal tab)

```bash
cd ~/workplace/personal/toolbox/gp

node add-to-gp-albums.js --only "Contributor Three"   # TEST: 1 photo, creates the dry-run album
node add-to-gp-albums.js --only "Contributor One"     # TEST: 2 photos, create + add-to-existing
node add-to-gp-albums.js                          # all, smallest -> largest, resumable
```

It attaches to the Chrome at `localhost:9222`, searches each `"filename"`, and adds it to
`[Photos] X dry-run`. Resumable (`gp-add-progress.json`), throttled, writes only to dry-run albums,
error screenshots go to `shots/`.

Then in Google Photos: open each `[Photos] X dry-run` → eyeball → select-all → add to the real
`[Photos] X` → delete the dry-run.

**Multiple matches & review:** some names (e.g. `DSC_0059.JPG`) match **several different** photos in
Google Photos. The script adds GP's **most-relevant** match (best guess) — that's why you eyeball each
`[Photos] X dry-run` before merging: a wrong pick lands in a different **date cluster** in the album,
easy to spot and remove. Names that return **no** match are logged `–  not in GP search` and collected
in **`gp-manual-review.txt`** (those either have a different name in GP or were never uploaded).

---

**If it stops/misbehaves:** paste me the console line + the `shots/*.png` and I'll fix the selector.
**Flags:** `--only "<name>"`, `--limit <N>`, `--headful-slow`, env `CDP_URL` (default `http://localhost:9222`).

**Why CDP and not just a Playwright-launched Chrome?** Google flags automation-launched browsers
(`navigator.webdriver`, Chrome-for-Testing build) and blocks sign-in. Attaching to your real,
already-authenticated Chrome avoids the login flow entirely.
