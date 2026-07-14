# Toolbox
A collection of utility scripts for automation and productivity.

## Usage
Add aliases to your shell config (`.zshrc`, `.bashrc`, etc.):
```bash
alias base="~/path/to/easy-base.sh"
alias rebase="~/path/to/easy-rebase.sh"
alias lintcheck="~/path/to/lintcheck.sh"
alias magic="~/path/to/reconnect-bluetooth-devices.sh"
alias partial-push="~/path/to/partial-push.sh"
alias pull-all="~/path/to/pull-all.sh"
alias timestamp-tool="~/path/to/timestamp-tool.sh"
```

## Scripts
### check-ip.sh
Checks and logs public IP address changes. Only outputs on first run and when IP changes are detected.

**Useful for:** Scheduling with cron or task schedulers to track IP changes over time without flooding logs.

### easy-base.sh
Checks out the base branch and pulls latest changes. Auto-detects the base branch via `origin/HEAD` or common names (develop, staging, main, master), or accepts an explicit branch argument.

**Useful for:** Quickly jumping back to the base branch with up-to-date code before starting new work.

### easy-rebase.sh
Simplifies Git rebasing with two modes: interactive rebase of last N commits (preserving author dates) or pulling a target branch and rebasing onto it.

**Useful for:** Cleaning up commit history before merging or staying up-to-date with a base branch while maintaining a clean rebase workflow.

### lintcheck.sh
Runs Python linters (black, ruff, flake8) on changed files from recent Git commits or uncommitted changes.

**Useful for:** Validating code quality before pushing to ensure all changes pass linting standards.

### pull-all.sh
Finds all git repositories under a directory (default: current directory) and pulls the latest base branch in each.

**Useful for:** Keeping all local repositories up-to-date in one command, e.g. after returning from time off.

### partial-push.sh
Pushes commits to remote while keeping the last N commits local. Safely resets, pushes with force-with-lease, then restores local commits.

**Useful for:** Pushing reviewed changes in a PR while keeping work-in-progress commits local for further refinement.

### reconnect-bluetooth-devices.sh
Automatically reconnects Bluetooth devices. 

**Useful for:** Switching peripherals between computers (e.g. magic keyboard, trackpad, mouse, headphones).

### timestamp-tool.sh
Fixes media capture timestamps (photos & videos) from EXIF/QuickTime metadata or the filename's own `YYYYMMDD_hhmmss` stamp, via exiftool. Git-style subcommands:

- **`mtime`** — set each file's filesystem "Last Modified" time to its capture date (`DateTimeOriginal` > `CreateDate` > `MediaCreateDate` > `TrackCreateDate`; content untouched). `--prefix-date` also renames each file with a `YYYYMMDD_hhmmss ` prefix (skips names that already contain such a stamp *anywhere* — `_` or `-` separator, e.g. `IMG_…`, `VID_…`, `PXL_…`, `Screenshot_…`; `--force` prefixes mid-name ones too). Each line shows the old→new gap (`(+2s)`, `(-166d 15h)`). `--warn-gap` flags filenames that disagree with the metadata (editor-corrupted EXIF); `--filename-fallback` uses the filename when metadata has none (e.g. Android videos with zeroed MP4 dates); `--prefer-filename` prefers the filename beyond the tolerance (on-location local time — fixes travel-tz, keeps a photo's exact EXIF second).
- **`exif`** — write the filename's `YYYYMMDD_hhmmss` into `DateTimeOriginal`/`CreateDate` where they're missing or disagree by more than `--warn-gap` (makes the metadata canonical so every tool reads the right date). Rewrites the file; mtime preserved. Best for photos.
- **`undo`** — reverse a run recorded with `--manifest` (renames back, restores mtime and/or EXIF). Needs jq.

Common: `--dry-run`, `--no-recurse`, `--ext`, `--warn-gap N`, `--manifest <file>` (JSON change-log for full reversibility).

**Useful for:** Restoring correct capture times after photos/videos lost or corrupted them (copying between storages, emailing, editing) — so they sort chronologically and read the right date everywhere.

### gp/add-to-gp-albums.js
Adds your "missing from Google Photos person-album" photos **and videos** into per-contributor `[Photos] X dry-run` albums via exact-filename search, by attaching (over CDP) to your real, already-logged-in Chrome — sidestepping Google's automation sign-in block. Resumable, throttled, writes only to dry-run albums. All GP files live under `gp/`; setup + run steps in `gp/add-to-gp-albums.SETUP.md`.

**Useful for:** Pushing your (more complete) local contributor organization into Google Photos person-albums now that the personal Photos API is dead.
