#!/usr/bin/env bash
set -euo pipefail

# timestamp-tool — fix media capture timestamps (photos & videos) from embedded metadata
# (EXIF DateTimeOriginal / QuickTime CreateDate) or from the filename's own YYYYMMDD_hhmmss stamp.
#
# Usage: timestamp-tool <command> [options] <dir|file> [<dir|file> ...]
#
# Commands:
#   mtime   Set each file's filesystem "Last Modified" time to its capture date. File CONTENT untouched.
#   exif    Write the filename's YYYYMMDD_hhmmss into the EXIF capture tags (DateTimeOriginal + CreateDate)
#           where they are missing or disagree with the filename by more than --warn-gap. Fixes metadata
#           an editor (Snapseed/Lightroom) rewrote wrongly. Rewrites the file; mtime is preserved. Photos.
#   undo    Reverse a run recorded with --manifest (renames back, restores mtime and/or EXIF).
#
# Common options (mtime, exif):
#   -n, --dry-run      Show what would change; change nothing.
#   -R, --no-recurse   Do not descend into subdirectories.
#       --ext LIST     Restrict to comma-separated extensions (e.g. jpg,heic,mp4).
#       --warn-gap N   Tolerance in seconds for "filename disagrees with metadata" (default 3600; 0 = any).
#       --manifest F   Record every change to F as JSON, so the whole run is reversible with `undo`.
#
# `mtime` extra options:
#   -p, --prefix-date  Also rename each file, prefixing "YYYYMMDD_hhmmss " (capture date + a space).
#                      Names that already contain a YYYYMMDD_hhmmss stamp ANYWHERE are left as-is.
#   -f, --force        With --prefix-date, prefix names whose stamp is NOT at the very start.
#       --filename-fallback   Use the filename stamp when the metadata has no valid capture date.
#       --prefer-filename     Prefer the filename over metadata when they differ by more than --warn-gap
#                             (the phone's on-location local time; fixes travel-tz + corrupted EXIF).
#
# `undo` usage:  timestamp-tool undo [--dry-run] <manifest.json>
#
# mtime source of truth (highest first): DateTimeOriginal > CreateDate > MediaCreateDate > TrackCreateDate.
# Video metadata is read as UTC and converted to local time (QuickTimeUTC).
#
# Needs: exiftool (brew install exiftool). `undo` also needs jq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# Print the leading comment block (from line 4 to the first non-comment line) as help.
usage() { awk 'NR<4{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# ── shared helpers ───────────────────────────────────────────────────────────

DATE_RE='^[0-9]{12}\.[0-9]{2}$'
# A plausible YYYYMMDD_hhmmss stamp — date/time separator may be '_' or '-' (Android screenshots use
# '-'). Validated ranges so random digit runs don't match; trailing digits (a Pixel's milliseconds) ok.
_ts='(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[_-]([01][0-9]|2[0-3])[0-5][0-9][0-5][0-9]'
TS_START='^'"$_ts"                          # stamp at the very start:  20200719_183531 ...
TS_ANYWHERE='(^|[^0-9])'"$_ts"              # stamp anywhere: IMG_/VID_/PXL_ 20200719_183531 ...

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
  [[ $y -gt 0 ]] && parts+=("${y}y"); [[ $d -gt 0 ]] && parts+=("${d}d"); [[ $h -gt 0 ]] && parts+=("${h}h")
  [[ $m -gt 0 ]] && parts+=("${m}m"); [[ $s -gt 0 ]] && parts+=("${s}s")
  [[ ${#parts[@]} -eq 0 ]] && parts=("0s")
  HUMAN="${sign}${parts[0]}"
  [[ ${#parts[@]} -gt 1 ]] && HUMAN="${HUMAN} ${parts[1]}"
  return 0
}

# "%Y%m%d%H%M.%S" -> exiftool write form "YYYY:MM:DD HH:MM:SS" in global EXIF_DT ('' if unparseable/'-').
to_exif_fmt() {
  EXIF_DT=''
  [[ "$1" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\.([0-9]{2})$ ]] || return 0
  local m=("${BASH_REMATCH[@]}")
  EXIF_DT="${m[1]}:${m[2]}:${m[3]} ${m[4]}:${m[5]}:${m[6]}"
}

# The filename's own YYYYMMDD_hhmmss (on-location local capture time) -> global FN_TS ('' if none).
extract_fn_ts() {
  FN_TS=''
  if [[ "$1" =~ $TS_ANYWHERE && "$1" =~ ([0-9]{8})[_-]([0-9]{6}) ]]; then
    FN_TS="${BASH_REMATCH[1]}${BASH_REMATCH[2]:0:4}.${BASH_REMATCH[2]:4:2}"   # %Y%m%d%H%M.%S
  fi
}

# JSON-escape $1 -> global JE (handles backslash, quote, tab, newline, CR).
json_esc() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  JE=$s
}

# ── manifest (shared by mtime + exif; consumed by undo) ──────────────────────

MANIFEST_FILE=""     # set by --manifest; write_manifest() (EXIT trap) flushes MANIFEST_ROWS here
MANIFEST_ROWS=()

# Append one change: orig_path final_path orig_mtime mtime_changed exif_changed orig_dto orig_cre
add_manifest_row() {
  [[ -n "$MANIFEST_FILE" ]] || return 0
  local op fp odto ocre
  json_esc "$1"; op=$JE
  json_esc "$2"; fp=$JE
  json_esc "${6:-}"; odto=$JE
  json_esc "${7:-}"; ocre=$JE
  MANIFEST_ROWS+=("{\"orig_path\":\"$op\",\"final_path\":\"$fp\",\"orig_mtime\":\"${3:-}\",\"mtime_changed\":${4},\"exif_changed\":${5},\"orig_dto\":\"$odto\",\"orig_cre\":\"$ocre\"}")
}

# Flush the collected rows to MANIFEST_FILE as JSON. Called from the EXIT trap so an interrupted run
# still records what it managed to change.
write_manifest() {
  [[ -n "$MANIFEST_FILE" && ${#MANIFEST_ROWS[@]} -gt 0 ]] || return 0
  { printf '{\n  "tool": "timestamp-tool",\n  "generated": "%s",\n  "changes": [\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local i n=${#MANIFEST_ROWS[@]}
    for ((i = 0; i < n; i++)); do
      printf '    %s' "${MANIFEST_ROWS[i]}"
      [[ $i -lt $((n - 1)) ]] && printf ','
      printf '\n'
    done
    printf '  ]\n}\n'
  } > "$MANIFEST_FILE"
  return 0
}

# Build the shared exiftool read arguments (into global exif_args) for the current RECURSE/EXTS.
build_read_args() {
  local fmt
  printf -v fmt '${FileModifyDate}\t${DateTimeOriginal}\t${CreateDate}\t${MediaCreateDate}\t${TrackCreateDate}\t${Directory}/${FileName}'
  exif_args=( -api QuickTimeUTC=1 -d "%Y%m%d%H%M.%S" -f -p "$fmt" )
  $RECURSE && exif_args+=( -r )
  if [[ -n "$EXTS" ]]; then
    local e; IFS=',' read -ra _exts <<< "$EXTS"
    for e in "${_exts[@]}"; do exif_args+=( -ext "$e" ); done
  fi
}

# Pre-flight shared by mtime + exif: validate targets, warn-gap, exiftool.
preflight() {
  if [[ ${#TARGETS[@]} -eq 0 ]]; then log_error "No target given."; usage; exit 1; fi
  [[ "$WARN_GAP" =~ ^[0-9]+$ ]] || { log_error "--warn-gap needs a whole number of seconds (0 disables)."; exit 1; }
  command -v exiftool >/dev/null 2>&1 || { log_error "exiftool not found — install with: brew install exiftool"; exit 1; }
  local t; for t in "${TARGETS[@]}"; do [[ -e "$t" ]] || { log_error "Not found: $t"; exit 1; }; done
}

# ── command: undo ────────────────────────────────────────────────────────────

cmd_undo() {
  local DRY_RUN=false f=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=true; shift ;;
      -h|--help)    usage; exit 0 ;;
      -*)           log_error "Unknown option: $1"; exit 1 ;;
      *)            f="$1"; shift ;;
    esac
  done
  [[ -n "$f" ]] || { log_error "undo needs a manifest file:  timestamp-tool undo <manifest.json>"; exit 1; }
  [[ -f "$f" ]] || { log_error "manifest not found: $f"; exit 1; }
  command -v jq >/dev/null 2>&1 || { log_error "undo needs jq (brew install jq)"; exit 1; }
  command -v exiftool >/dev/null 2>&1 || { log_error "exiftool not found — install with: brew install exiftool"; exit 1; }
  log_step "timestamp-tool undo  ($($DRY_RUN && echo 'DRY-RUN — no changes' || echo 'APPLY'))"
  log_info "Manifest: $f"
  local orig final omt mch exc odto ocre restored=0 skipped=0 uerr=0
  while IFS= read -r orig && IFS= read -r final && IFS= read -r omt && IFS= read -r mch \
     && IFS= read -r exc && IFS= read -r odto && IFS= read -r ocre; do
    if [[ "$final" != "$orig" ]]; then
      if [[ ! -e "$final" ]]; then
        if [[ -e "$orig" ]]; then log_info "already reverted: $orig"; restored=$((restored + 1))
        else log_warn "missing, skipped: $final"; skipped=$((skipped + 1)); fi
        continue
      fi
      if $DRY_RUN; then log_info "would rename back: $final -> $orig"
      elif mv -- "$final" "$orig"; then log_success "renamed back: $final${COLOR_DIM} -> ${COLOR_RESET}$orig"
      else log_error "rename-back failed: $final"; uerr=$((uerr + 1)); continue; fi
    fi
    if [[ "$mch" == "true" ]]; then
      if $DRY_RUN; then log_info "would restore mtime: $orig -> $omt"
      elif touch -t "$omt" -- "$orig"; then log_success "mtime restored: $orig${COLOR_DIM} -> ${COLOR_RESET}$omt"
      else log_error "mtime-restore failed: $orig"; uerr=$((uerr + 1)); continue; fi
    fi
    if [[ "$exc" == "true" ]]; then
      to_exif_fmt "$odto"; local dtd=$EXIF_DT
      to_exif_fmt "$ocre"; local dtc=$EXIF_DT
      if $DRY_RUN; then log_info "would restore EXIF: $orig -> DateTimeOriginal='${dtd:-<removed>}'"
      elif exiftool -P -overwrite_original "-DateTimeOriginal=$dtd" "-CreateDate=$dtc" "$orig" >/dev/null 2>&1; then
        log_success "EXIF restored: $orig${COLOR_DIM} -> ${dtd:-<removed>}${COLOR_RESET}"
      else log_error "EXIF-restore failed: $orig"; uerr=$((uerr + 1)); continue; fi
    fi
    restored=$((restored + 1))
  done < <(jq -r '.changes[] | .orig_path, .final_path, (.orig_mtime // ""), (.mtime_changed // false | tostring), (.exif_changed // false | tostring), (.orig_dto // ""), (.orig_cre // "")' "$f")
  log_step "Undo summary"
  log_success "$($DRY_RUN && echo 'would restore' || echo 'restored'): $restored"
  [[ $skipped -gt 0 ]] && log_warn "skipped (missing): $skipped"
  [[ $uerr -gt 0 ]] && log_error "errors: $uerr"
  exit $(( uerr > 0 ? 1 : 0 ))
}

# ── command: mtime ───────────────────────────────────────────────────────────

cmd_mtime() {
  DRY_RUN=false; RECURSE=true; PREFIX_DATE=false; FORCE=false
  FN_FALLBACK=false; PREFER_NAME=false; WARN_GAP=3600; EXTS=""; TARGETS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)         DRY_RUN=true; shift ;;
      -R|--no-recurse)      RECURSE=false; shift ;;
      -p|--prefix-date)     PREFIX_DATE=true; shift ;;
      --filename-fallback)  FN_FALLBACK=true; shift ;;
      --prefer-filename)    PREFER_NAME=true; shift ;;
      -f|--force)           FORCE=true; shift ;;
      --warn-gap)           WARN_GAP="${2:-}"; shift 2 ;;
      --manifest)           MANIFEST_FILE="${2:-}"; shift 2 ;;
      --ext)                EXTS="${2:-}"; shift 2 ;;
      -h|--help)            usage; exit 0 ;;
      -*)                   log_error "Unknown option: $1"; usage; exit 1 ;;
      *)                    TARGETS+=("$1"); shift ;;
    esac
  done
  preflight
  build_read_args
  local _tmp; _tmp="$(mktemp "${TMPDIR:-/tmp}/timestamp-tool.XXXXXX")"
  trap 'rm -f "$_tmp"; write_manifest' EXIT
  exiftool "${exif_args[@]}" "${TARGETS[@]}" > "$_tmp" 2>/dev/null || true

  log_step "timestamp-tool mtime  ($($DRY_RUN && echo 'DRY-RUN — no changes' || echo 'APPLY'); recurse=$RECURSE; prefix-date=$PREFIX_DATE; force=$FORCE; prefer-filename=$PREFER_NAME; filename-fallback=$FN_FALLBACK; warn-gap=${WARN_GAP}s)"
  log_info "Targets: ${TARGETS[*]}"
  local changed=0 renamed=0 stamped=0 same=0 nodate=0 fromname=0 mismatch=0 errors=0 total=0
  local fmod dto cre mcre tcre src base fn_ts cand meta chosen from_name ce _fe _me _d _e1 gap note
  local acted mtime_did final_path guard_re prefix dir newpath fe gd

  while IFS=$'\t' read -r fmod dto cre mcre tcre src; do
    total=$((total + 1))
    base="${src##*/}"
    from_name=false
    extract_fn_ts "$base"; fn_ts=$FN_TS

    # Decide the capture date: metadata first, then let the filename override.
    meta=''
    for cand in "$dto" "$cre" "$mcre" "$tcre"; do
      if [[ "$cand" =~ $DATE_RE ]]; then meta="$cand"; break; fi
    done
    chosen="$meta"
    if [[ -n "$fn_ts" ]]; then
      if [[ -z "$meta" ]]; then
        if $PREFER_NAME || $FN_FALLBACK; then chosen="$fn_ts"; from_name=true; fromname=$((fromname + 1)); fi
      elif $PREFER_NAME; then
        to_epoch "$fn_ts"; _fe=$EPOCH; to_epoch "$meta"; _me=$EPOCH
        if [[ -n "$_fe" && -n "$_me" ]]; then
          _d=$(( _me - _fe ))
          if [[ ${_d#-} -gt $WARN_GAP ]]; then chosen="$fn_ts"; from_name=true; fromname=$((fromname + 1)); fi
        fi
      fi
    fi
    if [[ -z "$chosen" ]]; then
      log_warn "no capture date, skipped: $src"; nodate=$((nodate + 1)); continue
    fi
    to_epoch "$chosen"; ce=$EPOCH

    # Sanity: filename stamp that disagrees with the (used) metadata by more than WARN_GAP -> warn.
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

    acted=false; mtime_did=false; final_path="$src"

    # (1) mtime — set it if it differs from the capture date.
    if [[ "$chosen" != "$fmod" ]]; then
      acted=true
      to_epoch "$fmod"; _e1=$EPOCH
      gap=''
      if [[ -n "$_e1" && -n "$ce" ]]; then human_secs $(( ce - _e1 )); gap="  ${COLOR_DIM}(${HUMAN})${COLOR_RESET}"; fi
      note=''; $from_name && note="  ${COLOR_DIM}[from filename]${COLOR_RESET}"
      if $DRY_RUN; then
        log_info "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}${gap}${note}"; changed=$((changed + 1))
      elif touch -t "$chosen" -- "$src"; then
        log_success "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}${gap}${note}"; changed=$((changed + 1)); mtime_did=true
      else
        log_error "touch failed: $src"; errors=$((errors + 1))
      fi
    fi

    # (2) filename — with --prefix-date, prepend "YYYYMMDD_hhmmss " unless already stamped.
    if $PREFIX_DATE; then
      if $FORCE; then guard_re="$TS_START"; else guard_re="$TS_ANYWHERE"; fi
      if [[ "$base" =~ $guard_re ]]; then
        stamped=$((stamped + 1))
      else
        acted=true
        prefix="${chosen:0:8}_${chosen:8:4}${chosen:13:2}"
        dir="${src%/*}"; newpath="$dir/$prefix $base"
        if [[ -e "$newpath" ]]; then
          log_error "rename skipped (target exists): $prefix $base"; errors=$((errors + 1))
        elif $DRY_RUN; then
          log_info "name:  $base  ${COLOR_DIM}->${COLOR_RESET} $prefix $base"; renamed=$((renamed + 1))
        elif mv -- "$src" "$newpath"; then
          log_success "name:  $base  ${COLOR_DIM}->${COLOR_RESET} $prefix $base"; renamed=$((renamed + 1)); final_path="$newpath"
        else
          log_error "rename failed: $src"; errors=$((errors + 1))
        fi
      fi
    fi

    if [[ $mtime_did == true || "$final_path" != "$src" ]]; then
      add_manifest_row "$src" "$final_path" "$fmod" "$mtime_did" false "" ""
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
  [[ $mismatch -gt 0 ]] && log_warn "name↔metadata mismatches (> ${WARN_GAP}s): $mismatch  ← metadata suspect; consider 'timestamp-tool exif'"
  [[ $nodate -gt 0 ]] && log_warn "no capture date: $nodate"
  [[ $errors -gt 0 ]] && log_error "errors: $errors"
  $DRY_RUN && [[ $changed -gt 0 || $renamed -gt 0 ]] && log_info "Re-run without --dry-run to apply."
  [[ -n "$MANIFEST_FILE" && ${#MANIFEST_ROWS[@]} -gt 0 ]] && log_info "manifest: $MANIFEST_FILE (${#MANIFEST_ROWS[@]} changes) — undo:  ${0##*/} undo '$MANIFEST_FILE'"
  log_info "took ${SECONDS}s"
  exit $(( errors > 0 ? 1 : 0 ))
}

# ── command: exif ────────────────────────────────────────────────────────────

cmd_exif() {
  DRY_RUN=false; RECURSE=true; WARN_GAP=3600; EXTS=""; TARGETS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)     DRY_RUN=true; shift ;;
      -R|--no-recurse)  RECURSE=false; shift ;;
      --warn-gap)       WARN_GAP="${2:-}"; shift 2 ;;
      --manifest)       MANIFEST_FILE="${2:-}"; shift 2 ;;
      --ext)            EXTS="${2:-}"; shift 2 ;;
      -h|--help)        usage; exit 0 ;;
      -*)               log_error "Unknown option: $1"; usage; exit 1 ;;
      *)                TARGETS+=("$1"); shift ;;
    esac
  done
  preflight
  build_read_args
  local _tmp; _tmp="$(mktemp "${TMPDIR:-/tmp}/timestamp-tool.XXXXXX")"
  trap 'rm -f "$_tmp"; write_manifest' EXIT
  exiftool "${exif_args[@]}" "${TARGETS[@]}" > "$_tmp" 2>/dev/null || true

  log_step "timestamp-tool exif  ($($DRY_RUN && echo 'DRY-RUN — no changes' || echo 'APPLY'); recurse=$RECURSE; warn-gap=${WARN_GAP}s)"
  log_info "Targets: ${TARGETS[*]}    (writes DateTimeOriginal + CreateDate from the filename; mtime preserved)"
  local written=0 same=0 nofn=0 errors=0 total=0
  local fmod dto cre mcre tcre src base fn_ts cand meta need reason fe me gd gaptxt edt frm

  while IFS=$'\t' read -r fmod dto cre mcre tcre src; do
    total=$((total + 1))
    base="${src##*/}"
    extract_fn_ts "$base"; fn_ts=$FN_TS
    if [[ -z "$fn_ts" ]]; then nofn=$((nofn + 1)); continue; fi   # nothing to write from

    meta=''
    for cand in "$dto" "$cre" "$mcre" "$tcre"; do
      if [[ "$cand" =~ $DATE_RE ]]; then meta="$cand"; break; fi
    done

    need=false; reason=''; gaptxt=''
    if [[ -z "$meta" ]]; then
      need=true; reason='no capture date in metadata'
    else
      to_epoch "$fn_ts"; fe=$EPOCH; to_epoch "$meta"; me=$EPOCH
      if [[ -n "$fe" && -n "$me" ]]; then
        gd=$(( me - fe ))
        if [[ ${gd#-} -gt $WARN_GAP ]]; then human_secs "$gd"; gaptxt="  ${COLOR_DIM}(${HUMAN})${COLOR_RESET}"; need=true; reason='disagrees with filename'; fi
      fi
    fi
    if ! $need; then same=$((same + 1)); continue; fi

    to_exif_fmt "$fn_ts"; edt=$EXIF_DT
    frm="${meta:-(none)}"
    if $DRY_RUN; then
      log_info "exif: $src  ${COLOR_DIM}${frm} ->${COLOR_RESET} ${fn_ts}${gaptxt}  ${COLOR_DIM}(${reason})${COLOR_RESET}"
      written=$((written + 1))
    elif exiftool -P -overwrite_original "-DateTimeOriginal=$edt" "-CreateDate=$edt" "$src" >/dev/null 2>&1; then
      log_success "exif: $src  ${COLOR_DIM}${frm} ->${COLOR_RESET} ${fn_ts}${gaptxt}"
      written=$((written + 1))
      add_manifest_row "$src" "$src" "" false true "$dto" "$cre"
    else
      log_error "exif write failed: $src"; errors=$((errors + 1))
    fi
  done < "$_tmp"

  log_step "Summary"
  [[ $total -eq 0 ]] && log_warn "No readable media found."
  log_info "scanned: $total"
  log_success "$($DRY_RUN && echo 'EXIF would be written' || echo 'EXIF written'): $written"
  log_info "already correct: $same"
  [[ $nofn -gt 0 ]] && log_info "no filename timestamp (skipped): $nofn"
  [[ $errors -gt 0 ]] && log_error "errors: $errors"
  $DRY_RUN && [[ $written -gt 0 ]] && log_info "Re-run without --dry-run to apply."
  [[ -n "$MANIFEST_FILE" && ${#MANIFEST_ROWS[@]} -gt 0 ]] && log_info "manifest: $MANIFEST_FILE (${#MANIFEST_ROWS[@]} changes) — undo:  ${0##*/} undo '$MANIFEST_FILE'"
  log_info "took ${SECONDS}s"
  exit $(( errors > 0 ? 1 : 0 ))
}

# ── dispatch ─────────────────────────────────────────────────────────────────

cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true
case "$cmd" in
  mtime) cmd_mtime "$@" ;;
  exif)  cmd_exif  "$@" ;;
  undo)  cmd_undo  "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  "")    usage; exit 1 ;;
  *)     log_error "Unknown command: $cmd"; usage; exit 1 ;;
esac
