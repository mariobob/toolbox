#!/usr/bin/env bash
set -euo pipefail

# Set each file's "Last Modified" time (filesystem mtime) to its capture date read
# from embedded metadata — EXIF DateTimeOriginal for photos, QuickTime CreateDate
# for videos. Fixes timestamps that drifted from copying between storages, email,
# downloads, etc. Only the filesystem mtime changes; file CONTENT is never touched.
#
# Usage: set-mtime-from-exif [OPTIONS] <dir|file> [<dir|file> ...]
#
# Options:
#   -n, --dry-run      Show what would change; touch/rename nothing.
#   -R, --no-recurse   Do not descend into subdirectories.
#   -p, --prefix-date  Also rename each file, prefixing "YYYYMMDD_hhmmss " (capture date + a space)
#                      to its current name — on TOP of setting the mtime. Names that already contain
#                      a YYYYMMDD_hhmmss stamp ANYWHERE (e.g. IMG_20200719_183531.jpg) are left as-is.
#   -f, --force        With --prefix-date, still prefix names whose YYYYMMDD_hhmmss stamp is NOT at
#                      the start (names that already START with one are still kept, for idempotency).
#       --filename-fallback
#                      When the metadata has NO valid capture date, fall back to the filename's own
#                      YYYYMMDD_hhmmss (e.g. Android VID_/IMG_ videos whose MP4 dates are zeroed).
#       --prefer-filename
#                      Use the filename's YYYYMMDD_hhmmss IN PREFERENCE TO the metadata whenever present.
#                      It's the phone's on-location local time — correct for travel footage (metadata is
#                      converted to THIS machine's timezone), and immune to editor-corrupted EXIF.
#       --warn-gap N   Warn when a filename's own YYYYMMDD_hhmmss stamp disagrees with the metadata
#                      date by more than N seconds (default 3600; 0 disables). Catches e.g. Snapseed /
#                      Lightroom edits that rewrote EXIF to a wrong capture date.
#       --ext LIST     Restrict to comma-separated extensions (e.g. jpg,heic,mp4).
#   -h, --help         Show this help.
#
# Source of truth (highest priority first): DateTimeOriginal > CreateDate >
# MediaCreateDate > TrackCreateDate. Files with none of these are skipped (warned).
# Video timestamps are read as UTC and converted to local time (QuickTimeUTC).
#
# Needs: exiftool (brew install exiftool).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# Print the leading comment block (from line 4 to the first non-comment line) as help.
usage() { awk 'NR<4{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# Naive epoch seconds for a "%Y%m%d%H%M.%S" timestamp -> global EPOCH ('' if unparseable). Pure bash
# (no `date` fork). Treats the time as UTC — we only ever use DIFFERENCES, which are the wall-clock gap.
to_epoch() {
  EPOCH=''
  [[ "$1" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{2})$ ]] || return 0
  local Y=$((10#${BASH_REMATCH[1]})) Mo=$((10#${BASH_REMATCH[2]})) D=$((10#${BASH_REMATCH[3]}))
  local hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  local y=$Y era yoe mp doy doe days
  [[ $Mo -le 2 ]] && y=$((y - 1))
  if [[ $y -ge 0 ]]; then era=$((y / 400)); else era=$(( (y - 399) / 400 )); fi
  yoe=$(( y - era*400 ))
  mp=$(( (Mo + 9) % 12 ))
  doy=$(( (153*mp + 2)/5 + D - 1 ))
  doe=$(( yoe*365 + yoe/4 - yoe/100 + doy ))
  days=$(( era*146097 + doe - 719468 ))                  # days since 1970-01-01 (Hinnant's algorithm)
  EPOCH=$(( days*86400 + hh*3600 + mm*60 + ss ))
}

# Signed top-2-unit human string for a second delta -> global HUMAN, e.g. -78330 -> "-21h 45m".
human_secs() {
  local delta=$1 sign abs y d h m s
  if [[ $delta -lt 0 ]]; then sign='-'; abs=$(( -delta )); else sign='+'; abs=$delta; fi
  y=$(( abs / 31536000 )); abs=$(( abs % 31536000 ))
  d=$(( abs / 86400 ));    abs=$(( abs % 86400 ))
  h=$(( abs / 3600 ));     abs=$(( abs % 3600 ))
  m=$(( abs / 60 ));       s=$(( abs % 60 ))
  local parts=()
  [[ $y -gt 0 ]] && parts+=("${y}y")
  [[ $d -gt 0 ]] && parts+=("${d}d")
  [[ $h -gt 0 ]] && parts+=("${h}h")
  [[ $m -gt 0 ]] && parts+=("${m}m")
  [[ $s -gt 0 ]] && parts+=("${s}s")
  [[ ${#parts[@]} -eq 0 ]] && parts=("0s")
  HUMAN="${sign}${parts[0]}"
  [[ ${#parts[@]} -gt 1 ]] && HUMAN="${HUMAN} ${parts[1]}"
  return 0
}

DRY_RUN=false
RECURSE=true
PREFIX_DATE=false
FORCE=false
FN_FALLBACK=false        # use the filename's own YYYYMMDD_hhmmss when metadata has no valid date
PREFER_NAME=false        # use the filename's own YYYYMMDD_hhmmss IN PREFERENCE TO the metadata date
WARN_GAP=3600            # warn if a filename's own YYYYMMDD_hhmmss disagrees with the metadata by > this
EXTS=""
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)          DRY_RUN=true; shift ;;
    -R|--no-recurse)       RECURSE=false; shift ;;
    -p|--prefix-date)      PREFIX_DATE=true; shift ;;
    --filename-fallback)   FN_FALLBACK=true; shift ;;
    --prefer-filename)     PREFER_NAME=true; shift ;;
    -f|--force)            FORCE=true; shift ;;
    --warn-gap)            WARN_GAP="${2:-}"; shift 2 ;;
    --ext)                 EXTS="${2:-}"; shift 2 ;;
    -h|--help)             usage; exit 0 ;;
    -*)                    log_error "Unknown option: $1"; usage; exit 1 ;;
    *)                     TARGETS+=("$1"); shift ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then log_error "No target given."; usage; exit 1; fi
[[ "$WARN_GAP" =~ ^[0-9]+$ ]] || { log_error "--warn-gap needs a whole number of seconds (0 disables)."; exit 1; }
command -v exiftool >/dev/null 2>&1 || { log_error "exiftool not found — install with: brew install exiftool"; exit 1; }

for t in "${TARGETS[@]}"; do
  [[ -e "$t" ]] || { log_error "Not found: $t"; exit 1; }
done

# exiftool prints one TAB-delimited line per file:
#   <FileModifyDate>\t<DateTimeOriginal>\t<CreateDate>\t<MediaCreateDate>\t<TrackCreateDate>\t<path>
# Missing tags print as '-' (-f). Dates are formatted (-d) straight into `touch -t` form
# (CCYYMMDDhhmm.SS), local time; video times are read as UTC -> local (QuickTimeUTC).
# (-p with ${Directory}/${FileName} for the path — SourceFile prints '-' under -T/-p.)
printf -v fmt '${FileModifyDate}\t${DateTimeOriginal}\t${CreateDate}\t${MediaCreateDate}\t${TrackCreateDate}\t${Directory}/${FileName}'
exif_args=( -api QuickTimeUTC=1 -d "%Y%m%d%H%M.%S" -f -p "$fmt" )
$RECURSE && exif_args+=( -r )
if [[ -n "$EXTS" ]]; then
  IFS=',' read -ra _exts <<< "$EXTS"
  for e in "${_exts[@]}"; do exif_args+=( -ext "$e" ); done
fi

log_step "set-mtime-from-exif  ($($DRY_RUN && echo 'DRY-RUN — no changes' || echo 'APPLY'); recurse=$RECURSE; prefix-date=$PREFIX_DATE; force=$FORCE; prefer-filename=$PREFER_NAME; filename-fallback=$FN_FALLBACK; warn-gap=${WARN_GAP}s)"
log_info "Targets: ${TARGETS[*]}"

changed=0 renamed=0 stamped=0 same=0 nodate=0 fromname=0 mismatch=0 errors=0 total=0
DATE_RE='^[0-9]{12}\.[0-9]{2}$'
# A plausible YYYYMMDD_hhmmss stamp — date/time separator may be '_' or '-' (Android screenshots use
# '-'). Validated ranges so random digit runs don't match; trailing digits (a Pixel's milliseconds)
# are fine. Used to skip files already carrying a capture timestamp so --prefix-date never double-stamps.
_ts='(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[_-]([01][0-9]|2[0-3])[0-5][0-9][0-5][0-9]'
TS_START='^'"$_ts"                          # stamp at the very start:  20200719_183531 ...
TS_ANYWHERE='(^|[^0-9])'"$_ts"              # stamp anywhere: IMG_/VID_/PXL_ 20200719_183531 ...

# Buffer exiftool's output to a temp file first, so a rename can never race exiftool's
# own recursive walk (which might otherwise re-encounter a just-renamed file).
_tmp="$(mktemp "${TMPDIR:-/tmp}/set-mtime.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT
exiftool "${exif_args[@]}" "${TARGETS[@]}" > "$_tmp" 2>/dev/null || true

while IFS=$'\t' read -r fmod dto cre mcre tcre src; do
  total=$((total + 1))
  base="${src##*/}"
  chosen=""; from_name=false
  # The filename's own YYYYMMDD_hhmmss (if any), extracted once — used by --prefer-filename,
  # --filename-fallback, and the mismatch check. It is the phone's ON-LOCATION local time at capture.
  fn_ts=''
  if [[ "$base" =~ $TS_ANYWHERE && "$base" =~ ([0-9]{8})[_-]([0-9]{6}) ]]; then
    fn_ts="${BASH_REMATCH[1]}${BASH_REMATCH[2]:0:4}.${BASH_REMATCH[2]:4:2}"   # %Y%m%d%H%M.%S
  fi

  # (1) --prefer-filename: trust the filename's capture stamp over metadata — correct on-location local
  #     time for travel footage, and sidesteps editor-corrupted EXIF.
  if $PREFER_NAME && [[ -n "$fn_ts" ]]; then
    chosen="$fn_ts"; from_name=true; fromname=$((fromname + 1))
  fi
  # (2) else the metadata date (DateTimeOriginal > CreateDate > MediaCreateDate > TrackCreateDate).
  if [[ -z "$chosen" ]]; then
    for cand in "$dto" "$cre" "$mcre" "$tcre"; do
      if [[ "$cand" =~ $DATE_RE ]]; then chosen="$cand"; break; fi
    done
  fi
  # (3) else fall back to the filename stamp, if --filename-fallback and metadata had none (e.g. Android
  #     VID_/IMG_ videos whose MP4 create-dates are zeroed).
  if [[ -z "$chosen" && $FN_FALLBACK == true && -n "$fn_ts" ]]; then
    chosen="$fn_ts"; from_name=true; fromname=$((fromname + 1))
  fi
  if [[ -z "$chosen" ]]; then
    log_warn "no capture date, skipped: $src"
    nodate=$((nodate + 1)); continue
  fi
  to_epoch "$chosen"; ce=$EPOCH        # capture-date epoch, reused for both checks below

  # Sanity: if the filename carries its own YYYYMMDD_hhmmss (camera capture stamp) that disagrees with
  # the metadata date by more than WARN_GAP, the metadata is suspect (e.g. Snapseed/Lightroom rewrote it).
  # (Skipped when chosen already came from the filename — there's nothing to compare it against.)
  if [[ $from_name == false && $WARN_GAP -gt 0 && -n "$fn_ts" ]]; then
    to_epoch "$fn_ts"; fe=$EPOCH
    if [[ -n "$fe" && -n "$ce" ]]; then
      gd=$(( ce - fe ))
      if [[ ${gd#-} -gt $WARN_GAP ]]; then
        human_secs "$gd"
        log_warn "name↔metadata mismatch: $src  ${COLOR_DIM}name ${fn_ts} vs meta ${chosen} (${HUMAN})${COLOR_RESET}"
        mismatch=$((mismatch + 1))
      fi
    fi
  fi

  acted=false

  # (1) mtime — set it if it differs from the capture date.
  if [[ "$chosen" != "$fmod" ]]; then
    acted=true
    to_epoch "$fmod"; _e1=$EPOCH
    gap=''
    if [[ -n "$_e1" && -n "$ce" ]]; then human_secs $(( ce - _e1 )); gap="  ${COLOR_DIM}(${HUMAN})${COLOR_RESET}"; fi
    note=''; $from_name && note="  ${COLOR_DIM}[from filename]${COLOR_RESET}"
    if $DRY_RUN; then
      log_info "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}${gap}${note}"
      changed=$((changed + 1))
    elif touch -t "$chosen" -- "$src"; then
      log_success "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}${gap}${note}"
      changed=$((changed + 1))
    else
      log_error "touch failed: $src"
      errors=$((errors + 1))
    fi
  fi

  # (2) filename — with --prefix-date, prepend "YYYYMMDD_hhmmss " (capture date + a space), UNLESS the
  #     name already carries a YYYYMMDD_hhmmss stamp: anywhere by default, or only at the start (--force).
  if $PREFIX_DATE; then
    if $FORCE; then guard_re="$TS_START"; else guard_re="$TS_ANYWHERE"; fi
    if [[ "$base" =~ $guard_re ]]; then
      stamped=$((stamped + 1))                               # already timestamped — keep name as-is
    else
      acted=true
      prefix="${chosen:0:8}_${chosen:8:4}${chosen:13:2}"     # YYYYMMDD_hhmmss, derived from $chosen
      dir="${src%/*}"
      newpath="$dir/$prefix $base"
      if [[ -e "$newpath" ]]; then
        log_error "rename skipped (target exists): $prefix $base"
        errors=$((errors + 1))
      elif $DRY_RUN; then
        log_info "name:  $base  ${COLOR_DIM}->${COLOR_RESET} $prefix $base"
        renamed=$((renamed + 1))
      elif mv -- "$src" "$newpath"; then
        log_success "name:  $base  ${COLOR_DIM}->${COLOR_RESET} $prefix $base"
        renamed=$((renamed + 1))
      else
        log_error "rename failed: $src"
        errors=$((errors + 1))
      fi
    fi
  fi

  $acted || same=$((same + 1))
done < "$_tmp"

log_step "Summary"
[[ $total -eq 0 ]] && log_warn "No readable media found."
log_info "scanned: $total"
log_success "$($DRY_RUN && echo 'mtime would change' || echo 'mtime changed'): $changed"
[[ $fromname -gt 0 ]] && log_info "date taken from filename: $fromname"
$PREFIX_DATE && log_success "$($DRY_RUN && echo 'would rename' || echo 'renamed'): $renamed"
$PREFIX_DATE && [[ $stamped -gt 0 ]] && log_info "name already timestamped (kept): $stamped"
log_info "unchanged: $same"
[[ $mismatch -gt 0 ]] && log_warn "name↔metadata mismatches (> ${WARN_GAP}s): $mismatch  ← metadata date is suspect (edited?); verify before trusting"
[[ $nodate -gt 0 ]] && log_warn "no capture date: $nodate"
[[ $errors -gt 0 ]] && log_error "errors: $errors"
$DRY_RUN && [[ $changed -gt 0 || $renamed -gt 0 ]] && log_info "Re-run without --dry-run to apply."
log_info "took ${SECONDS}s"
exit $(( errors > 0 ? 1 : 0 ))
