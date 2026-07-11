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
#                      to its current name — on TOP of setting the mtime.
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

DRY_RUN=false
RECURSE=true
PREFIX_DATE=false
EXTS=""
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)     DRY_RUN=true; shift ;;
    -R|--no-recurse)  RECURSE=false; shift ;;
    -p|--prefix-date) PREFIX_DATE=true; shift ;;
    --ext)            EXTS="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               log_error "Unknown option: $1"; usage; exit 1 ;;
    *)                TARGETS+=("$1"); shift ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then log_error "No target given."; usage; exit 1; fi
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

log_step "set-mtime-from-exif  ($($DRY_RUN && echo 'DRY-RUN — no changes' || echo 'APPLY'); recurse=$RECURSE; prefix-date=$PREFIX_DATE)"
log_info "Targets: ${TARGETS[*]}"

changed=0 renamed=0 same=0 nodate=0 errors=0 total=0
DATE_RE='^[0-9]{12}\.[0-9]{2}$'

# Buffer exiftool's output to a temp file first, so a rename can never race exiftool's
# own recursive walk (which might otherwise re-encounter a just-renamed file).
_tmp="$(mktemp "${TMPDIR:-/tmp}/set-mtime.XXXXXX")"
trap 'rm -f "$_tmp"' EXIT
exiftool "${exif_args[@]}" "${TARGETS[@]}" > "$_tmp" 2>/dev/null || true

while IFS=$'\t' read -r fmod dto cre mcre tcre src; do
  total=$((total + 1))
  chosen=""
  for cand in "$dto" "$cre" "$mcre" "$tcre"; do
    if [[ "$cand" =~ $DATE_RE ]]; then chosen="$cand"; break; fi
  done
  if [[ -z "$chosen" ]]; then
    log_warn "no capture date, skipped: $src"
    nodate=$((nodate + 1)); continue
  fi

  acted=false

  # (1) mtime — set it if it differs from the capture date.
  if [[ "$chosen" != "$fmod" ]]; then
    acted=true
    if $DRY_RUN; then
      log_info "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}"
      changed=$((changed + 1))
    elif touch -t "$chosen" -- "$src"; then
      log_success "mtime: $src  ${COLOR_DIM}${fmod} ->${COLOR_RESET} ${chosen}"
      changed=$((changed + 1))
    else
      log_error "touch failed: $src"
      errors=$((errors + 1))
    fi
  fi

  # (2) filename — with --prefix-date, prepend "YYYYMMDD_hhmmss " (capture date + a space).
  if $PREFIX_DATE; then
    prefix="${chosen:0:8}_${chosen:8:4}${chosen:13:2}"      # YYYYMMDD_hhmmss, derived from $chosen
    base="$(basename -- "$src")"
    dir="$(dirname -- "$src")"
    if [[ "$base" == "$prefix "* ]]; then
      :                                                      # already carries this exact prefix — skip
    else
      acted=true
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
$PREFIX_DATE && log_success "$($DRY_RUN && echo 'would rename' || echo 'renamed'): $renamed"
log_info "unchanged: $same"
[[ $nodate -gt 0 ]] && log_warn "no capture date: $nodate"
[[ $errors -gt 0 ]] && log_error "errors: $errors"
$DRY_RUN && [[ $changed -gt 0 || $renamed -gt 0 ]] && log_info "Re-run without --dry-run to apply."
log_info "took ${SECONDS}s"
exit $(( errors > 0 ? 1 : 0 ))
