#!/usr/bin/env bash
set -euo pipefail

# wrap-commits — rewrap the message bodies of recent commits to a fixed column width.
#
# Usage: wrap-commits [options] [repo-dir]
#
# Options:
#   -w, --width N    Wrap column (default 72).
#   -c, --count N    Rewrite the last N commits instead of the unpushed ones. Reaching past
#                    the first unpushed commit rewrites published history and asks first.
#   -n, --dry-run    Show what would change; change nothing.
#   -v, --verbose    Print the rewrapped message of every commit that changes.
#   -y, --yes        Assume yes — required to rewrite pushed commits non-interactively.
#   -S, --gpg-sign   Re-sign the rewritten commits (a rewrite drops the original signature).
#   -h, --help       Show this help.
#
# By default the range is every commit that no remote-tracking branch has yet (first unpushed
# commit .. HEAD), so the common case rewrites only local work.
#
# The subject (first line) is never rewrapped — rewrapping it would fold it into the body — it
# is only reported when too long. Also left verbatim: indented/preformatted lines, ``` fenced
# blocks, quoted (>) and table (|) lines, and the trailing `Key: value` trailer block. Every
# other paragraph is unwrapped and refilled, hanging-indenting list items under their bullet.
# Words longer than the width (URLs) are never broken.
#
# Rewriting keeps each commit's tree, author and committer — only the message changes. The
# branch is moved with `git update-ref`, so the index and working tree (uncommitted changes
# included) are never touched, and the previous head stays in `git reflog`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# Print the leading comment block (from line 4 to the first non-comment line) as help.
usage() { awk 'NR<4{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

# ── Globals ─────────────────────────────────────────────────────────────────

WIDTH=72
COUNT=""
DRY_RUN=false
VERBOSE=false
AUTO_YES=false
GPG_SIGN=false
REPO_DIR="."

BRANCH=""
OLD_HEAD=""
UPSTREAM=""
UNPUSHED=0
PUBLISHED=0        # commits in range that a remote already has
RANGE_N=0

# Per-commit state (parallel arrays, filled during analysis)
declare -a C_SHAS=()
declare -a C_SUBJECTS=()
declare -a C_MESSAGES=()     # rewrapped message
declare -a C_ACTIONS=()      # wrap | same
declare -a C_LINES_IN=()
declare -a C_LINES_OUT=()
declare -a C_OVER_IN=()
declare -a C_OVER_OUT=()
declare -a C_MAX_IN=()
declare -a C_PUSHED=()       # true | false

# Run totals
T_LINES_IN=0
T_LINES_OUT=0
T_OVER_IN=0
T_OVER_OUT=0
T_MAX_IN=0
T_MAX_OUT=0
T_SUBJ_OVER=0
T_PARAS=0
T_PARAS_REFLOWED=0
T_LITERAL=0
T_OVERFLOW_WORDS=0
T_TRAILING_WS=0
T_SIGNED=0
REWRITTEN=0
REBUILT=0                    # unchanged message, recreated because an ancestor moved

# ── Argument parsing ────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--width)    WIDTH="${2:-}"; shift 2 ;;
            -c|--count)    COUNT="${2:-}"; shift 2 ;;
            -n|--dry-run)  DRY_RUN=true; shift ;;
            -v|--verbose)  VERBOSE=true; shift ;;
            -y|--yes)      AUTO_YES=true; shift ;;
            -S|--gpg-sign) GPG_SIGN=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            -*)            log_error "Unknown option: $1"; usage; exit 1 ;;
            *)             REPO_DIR="$1"; shift ;;
        esac
    done

    [[ "$WIDTH" =~ ^[0-9]+$ ]] && (( WIDTH >= 20 )) || {
        log_error "--width needs a whole number of at least 20 (got '${WIDTH}')"; exit 1; }

    if [[ -n "$COUNT" ]]; then
        [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || {
            log_error "--count needs a positive whole number (got '${COUNT}')"; exit 1; }
    fi

    [[ -d "$REPO_DIR" ]] || { log_error "Not a directory: $REPO_DIR"; exit 1; }
    REPO_DIR="$(cd "$REPO_DIR" && pwd)"
}

# ── Wrapping engine (pure bash — no fold/fmt, so it behaves the same everywhere) ──

BULLET_RE='^([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)'
FENCE_RE='^[[:space:]]*(```|~~~)'

# Strip trailing whitespace from $1 -> global RT.
rtrim() { RT="${1%"${1##*[![:space:]]}"}"; }

# True for `Key: value` trailer lines and the cherry-pick note git appends to them.
is_trailer_line() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*[^[:space:]] ]] && return 0
    [[ "$1" =~ ^\(cherry\ picked\ from\ commit\ [0-9a-f]+\)$ ]] && return 0
    return 1
}

# Greedy-fill the single-line $1 into W_OUT: first line prefixed with $2, continuations with $3.
# Never splits a word — an over-long word (URL) gets a line of its own and is counted.
fill_paragraph() {
    local text="$1" first_prefix="$2" cont_prefix="$3"
    local -a words=()
    read -ra words <<< "$text"

    if [[ ${#words[@]} -eq 0 ]]; then
        W_OUT+=("$first_prefix")
        return 0
    fi

    local prefix="$first_prefix" cur="" w
    for w in "${words[@]}"; do
        (( ${#cont_prefix} + ${#w} > WIDTH )) && W_OVERFLOW_WORDS=$(( W_OVERFLOW_WORDS + 1 ))
        if [[ -z "$cur" ]]; then
            cur="$w"
        elif (( ${#prefix} + ${#cur} + 1 + ${#w} <= WIDTH )); then
            cur="$cur $w"
        else
            W_OUT+=("${prefix}${cur}")
            prefix="$cont_prefix"
            cur="$w"
        fi
    done
    W_OUT+=("${prefix}${cur}")
}

# Rewrap the commit message $1 to WIDTH.
# Sets: W_TEXT (result) plus per-message counters W_LINES_IN/OUT, W_OVER_IN/OUT, W_MAX_IN/OUT,
# W_SUBJ_OVER, W_PARAS, W_PARAS_REFLOWED, W_LITERAL, W_OVERFLOW_WORDS, W_TRAILING_WS.
wrap_message() {
    local -a MSG_LINES=()
    local raw
    while IFS= read -r raw; do
        rtrim "$raw"
        [[ "$RT" != "$raw" ]] && W_TRAILING_WS=$(( W_TRAILING_WS + 1 ))
        MSG_LINES+=("$RT")
    done <<< "$1"

    local n=${#MSG_LINES[@]}
    # Ignore trailing blank lines on the way in so they don't count as a difference.
    while (( n > 1 )) && [[ -z "${MSG_LINES[n - 1]}" ]]; do n=$(( n - 1 )); done

    W_LINES_IN=$n
    local i
    for (( i = 0; i < n; i++ )); do
        local len=${#MSG_LINES[i]}
        (( len > WIDTH ))   && W_OVER_IN=$(( W_OVER_IN + 1 ))
        (( len > W_MAX_IN )) && W_MAX_IN=$len
    done
    (( ${#MSG_LINES[0]} > WIDTH )) && W_SUBJ_OVER=1

    # Locate the trailing `Key: value` block (preceded by a blank line) — never reflow it.
    local trailer_start=-1 j=$(( n - 1 )) last
    while (( j > 0 )) && [[ -z "${MSG_LINES[j]}" ]]; do j=$(( j - 1 )); done
    last=$j
    while (( j > 0 )) && is_trailer_line "${MSG_LINES[j]}"; do j=$(( j - 1 )); done
    if (( j < last )) && [[ -z "${MSG_LINES[j]}" ]]; then trailer_start=$(( j + 1 )); fi

    W_OUT=("${MSG_LINES[0]}")
    local in_fence=false line nxt trimmed marker cont buf src_first src_last out_first
    i=1
    while (( i < n )); do
        line="${MSG_LINES[i]}"

        if $in_fence; then
            W_OUT+=("$line"); W_LITERAL=$(( W_LITERAL + 1 ))
            [[ "$line" =~ $FENCE_RE ]] && in_fence=false
            i=$(( i + 1 )); continue
        fi
        if [[ "$line" =~ $FENCE_RE ]]; then
            in_fence=true; W_OUT+=("$line"); W_LITERAL=$(( W_LITERAL + 1 ))
            i=$(( i + 1 )); continue
        fi
        if (( trailer_start >= 0 && i >= trailer_start )); then
            W_OUT+=("$line"); W_LITERAL=$(( W_LITERAL + 1 ))
            i=$(( i + 1 )); continue
        fi
        if [[ -z "$line" ]]; then
            W_OUT+=(""); i=$(( i + 1 )); continue
        fi
        # Indented (code/preformatted), quoted or table lines carry their own layout.
        if [[ "$line" == [[:space:]]* || "$line" == ">"* || "$line" == "|"* ]]; then
            W_OUT+=("$line"); W_LITERAL=$(( W_LITERAL + 1 ))
            i=$(( i + 1 )); continue
        fi

        # A paragraph: this line plus every plain line that follows it.
        marker=""; cont=""
        if [[ "$line" =~ $BULLET_RE ]]; then
            marker="${BASH_REMATCH[1]}"
            printf -v cont '%*s' "${#marker}" ''
        fi
        buf="${line:${#marker}}"
        src_first=$i
        i=$(( i + 1 ))
        while (( i < n )); do
            nxt="${MSG_LINES[i]}"
            [[ -z "$nxt" ]] && break
            [[ "$nxt" =~ $FENCE_RE ]] && break
            (( trailer_start >= 0 && i >= trailer_start )) && break
            if [[ -n "$marker" ]]; then
                # Only an indented, non-bullet line continues a list item.
                [[ "$nxt" == [[:space:]]* ]] || break
                trimmed="${nxt#"${nxt%%[![:space:]]*}"}"
                [[ "$trimmed" =~ $BULLET_RE ]] && break
                buf="$buf $trimmed"
            else
                [[ "$nxt" == [[:space:]]* || "$nxt" == ">"* || "$nxt" == "|"* ]] && break
                [[ "$nxt" =~ $BULLET_RE ]] && break
                buf="$buf $nxt"
            fi
            i=$(( i + 1 ))
        done
        src_last=$(( i - 1 ))

        out_first=${#W_OUT[@]}
        W_PARAS=$(( W_PARAS + 1 ))
        fill_paragraph "$buf" "$marker" "$cont"

        # Reflowed? Compare the lines we consumed with the lines we produced.
        local changed=false k
        if (( src_last - src_first != ${#W_OUT[@]} - 1 - out_first )); then
            changed=true
        else
            for (( k = 0; k <= src_last - src_first; k++ )); do
                [[ "${MSG_LINES[src_first + k]}" == "${W_OUT[out_first + k]}" ]] && continue
                changed=true; break
            done
        fi
        $changed && W_PARAS_REFLOWED=$(( W_PARAS_REFLOWED + 1 ))
    done

    # Drop trailing blank lines, then join.
    local m=$(( ${#W_OUT[@]} - 1 ))
    while (( m > 0 )) && [[ -z "${W_OUT[m]}" ]]; do m=$(( m - 1 )); done
    W_LINES_OUT=$(( m + 1 ))
    W_TEXT="${W_OUT[0]}"
    for (( k = 1; k <= m; k++ )); do W_TEXT="${W_TEXT}"$'\n'"${W_OUT[k]}"; done
    for (( k = 0; k <= m; k++ )); do
        local olen=${#W_OUT[k]}
        (( olen > WIDTH ))    && W_OVER_OUT=$(( W_OVER_OUT + 1 ))
        (( olen > W_MAX_OUT )) && W_MAX_OUT=$olen
    done
    return 0
}

# ── Phase 1: Inspect the repository ─────────────────────────────────────────

inspect_repo() {
    git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
        log_error "Not a git repository: $REPO_DIR"; exit 1; }

    local git_dir state
    git_dir="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)"
    for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        [[ -e "$git_dir/$state" ]] && { log_error "Operation in progress ($state) — finish or abort it first"; exit 1; }
    done

    git -C "$REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || {
        log_error "No commits yet in $REPO_DIR"; exit 1; }

    BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
    [[ "$BRANCH" != "HEAD" ]] || { log_error "Detached HEAD — check out a branch first"; exit 1; }

    OLD_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
    UPSTREAM="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")"

    local total have_remotes
    total="$(git -C "$REPO_DIR" rev-list --count --first-parent HEAD)"
    have_remotes="$(git -C "$REPO_DIR" for-each-ref --count=1 --format='x' refs/remotes)"
    UNPUSHED="$(git -C "$REPO_DIR" rev-list --count --first-parent HEAD --not --remotes)"

    log_info "Repository: ${COLOR_BOLD}$(basename "$REPO_DIR")${COLOR_RESET} on '${BRANCH}' (${total} commit(s) on the first-parent chain)"

    if [[ -z "$have_remotes" ]]; then
        log_warn "No remote-tracking branches — every commit counts as unpushed"
    elif [[ -n "$UPSTREAM" ]]; then
        log_info "Upstream: ${UPSTREAM} — ${UNPUSHED} unpushed commit(s)"
    else
        log_info "No upstream set — ${UNPUSHED} commit(s) not on any remote"
    fi

    if [[ -n "$COUNT" ]]; then
        RANGE_N="$COUNT"
        if (( RANGE_N > total )); then
            log_warn "Only ${total} commit(s) in history — using ${total} instead of ${COUNT}"
            RANGE_N="$total"
        fi
    else
        RANGE_N="$UNPUSHED"
    fi

    if (( RANGE_N == 0 )); then
        log_success "Nothing to do — no unpushed commits (use --count N to reach further back)"
        exit 0
    fi

    PUBLISHED=$(( RANGE_N - UNPUSHED ))
    (( PUBLISHED < 0 )) && PUBLISHED=0

    log_info "Target: last ${COLOR_BOLD}${RANGE_N}${COLOR_RESET} commit(s), wrapping at ${COLOR_BOLD}${WIDTH}${COLOR_RESET} columns$($DRY_RUN && echo "  ${COLOR_DIM}(dry run)${COLOR_RESET}" || echo "")"
    return 0
}

# ── Phase 2: Analyse (read-only — computes every new message up front) ──────

analyse_commits() {
    local sha idx=0
    while IFS= read -r sha; do
        C_SHAS+=("$sha")
        idx=$(( idx + 1 ))
    done < <(git -C "$REPO_DIR" rev-list --first-parent -n "$RANGE_N" HEAD)

    for (( idx = 0; idx < ${#C_SHAS[@]}; idx++ )); do
        sha="${C_SHAS[idx]}"

        local msg sig
        msg="$(git -C "$REPO_DIR" log -1 --format=%B "$sha")"
        sig="$(git -C "$REPO_DIR" log -1 --format='%G?' "$sha")"
        [[ "$sig" != "N" ]] && T_SIGNED=$(( T_SIGNED + 1 ))

        W_OUT=(); W_TEXT=""
        W_LINES_IN=0; W_LINES_OUT=0; W_OVER_IN=0; W_OVER_OUT=0; W_MAX_IN=0; W_MAX_OUT=0
        W_SUBJ_OVER=0; W_PARAS=0; W_PARAS_REFLOWED=0; W_LITERAL=0; W_OVERFLOW_WORDS=0; W_TRAILING_WS=0
        wrap_message "$msg"

        C_SUBJECTS+=("${W_OUT[0]}")
        C_MESSAGES+=("$W_TEXT")
        C_LINES_IN+=("$W_LINES_IN")
        C_LINES_OUT+=("$W_LINES_OUT")
        C_OVER_IN+=("$W_OVER_IN")
        C_OVER_OUT+=("$W_OVER_OUT")
        C_MAX_IN+=("$W_MAX_IN")

        if [[ "$W_TEXT" == "$msg" ]]; then
            C_ACTIONS+=("same")
        else
            C_ACTIONS+=("wrap")
        fi

        # Commits beyond the unpushed ones are already on a remote.
        if (( idx >= UNPUSHED )); then C_PUSHED+=("true"); else C_PUSHED+=("false"); fi

        T_LINES_IN=$(( T_LINES_IN + W_LINES_IN ))
        T_LINES_OUT=$(( T_LINES_OUT + W_LINES_OUT ))
        T_OVER_IN=$(( T_OVER_IN + W_OVER_IN ))
        T_OVER_OUT=$(( T_OVER_OUT + W_OVER_OUT ))
        T_SUBJ_OVER=$(( T_SUBJ_OVER + W_SUBJ_OVER ))
        T_PARAS=$(( T_PARAS + W_PARAS ))
        T_PARAS_REFLOWED=$(( T_PARAS_REFLOWED + W_PARAS_REFLOWED ))
        T_LITERAL=$(( T_LITERAL + W_LITERAL ))
        T_OVERFLOW_WORDS=$(( T_OVERFLOW_WORDS + W_OVERFLOW_WORDS ))
        T_TRAILING_WS=$(( T_TRAILING_WS + W_TRAILING_WS ))
        (( W_MAX_IN  > T_MAX_IN  )) && T_MAX_IN=$W_MAX_IN
        (( W_MAX_OUT > T_MAX_OUT )) && T_MAX_OUT=$W_MAX_OUT
    done
    return 0
}

# ── Phase 3: Present & confirm ──────────────────────────────────────────────

# Truncate $1 to at most $2 characters, with an ellipsis when cut.
truncate_str() {
    if (( ${#1} > $2 )); then printf '%s…' "${1:0:$(( $2 - 1 ))}"; else printf '%s' "$1"; fi
}

present_plan() {
    local subj_w=10 i
    for i in "${!C_SUBJECTS[@]}"; do
        local sl=${#C_SUBJECTS[i]}
        (( sl > subj_w )) && subj_w=$sl
    done
    (( subj_w > 52 )) && subj_w=52

    echo ""
    printf "  ${COLOR_BOLD}%-8s %-${subj_w}s %6s %5s  %-7s %s${COLOR_RESET}\n" \
        "SHA" "SUBJECT" "LINES" ">${WIDTH}" "STATE" "ACTION"
    printf "  %-8s %-${subj_w}s %6s %5s  %-7s %s\n" \
        "--------" "$(printf '%*s' "$subj_w" '' | tr ' ' '-')" "-----" "-----" "-------" "------"

    for i in "${!C_SHAS[@]}"; do
        local state="local" state_color="$COLOR_DIM"
        if [[ "${C_PUSHED[i]}" == "true" ]]; then state="pushed"; state_color="$COLOR_YELLOW"; fi

        local action action_color
        if [[ "${C_ACTIONS[i]}" == "wrap" ]]; then
            action="wrap"; action_color="$COLOR_GREEN"
        else
            action="ok"; action_color="$COLOR_DIM"
        fi

        printf "  %-8s %-${subj_w}s %6s %5s  ${state_color}%-7s${COLOR_RESET} ${action_color}%s${COLOR_RESET}\n" \
            "${C_SHAS[i]:0:7}" "$(truncate_str "${C_SUBJECTS[i]}" "$subj_w")" \
            "${C_LINES_IN[i]}" "${C_OVER_IN[i]}" "$state" "$action"
    done
    echo ""
    return 0
}

count_changed() {
    local i n=0
    for i in "${!C_ACTIONS[@]}"; do
        [[ "${C_ACTIONS[i]}" == "wrap" ]] && n=$(( n + 1 ))
    done
    echo "$n"
}

confirm_if_needed() {
    local changed="$1"

    if (( PUBLISHED == 0 )); then
        return 0
    fi

    # Only commits that actually change matter for the "rewrites remote history" warning.
    local i published_changed=0
    for i in "${!C_ACTIONS[@]}"; do
        [[ "${C_ACTIONS[i]}" == "wrap" && "${C_PUSHED[i]}" == "true" ]] && published_changed=$(( published_changed + 1 ))
    done
    if (( published_changed == 0 )); then
        log_info "The ${PUBLISHED} pushed commit(s) in range need no change — nothing published gets rewritten"
        return 0
    fi

    echo ""
    log_warn "${COLOR_BOLD}This rewrites published history.${COLOR_RESET}"
    log_warn "${published_changed} of the ${PUBLISHED} commit(s) already on ${UPSTREAM:-a remote} will get new SHAs."
    log_warn "Everyone who has these commits must reset or re-clone, and the push needs --force-with-lease."
    echo ""

    $DRY_RUN && return 0
    $AUTO_YES && { log_warn "Continuing anyway (--yes)"; return 0; }

    [[ -t 0 ]] || { log_error "Refusing to rewrite pushed commits without a terminal — pass --yes"; exit 1; }

    read -rp "Rewrite all ${changed} commit(s), including ${published_changed} pushed one(s)? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { log_info "Aborted — nothing changed"; exit 0; }
}

# ── Phase 4: Rewrite (replays the range with git commit-tree) ───────────────

# Print the rewrapped message, indented and dimmed, with a width ruler.
print_message() {
    local line
    printf "      ${COLOR_DIM}%s${COLOR_RESET}\n" "$(printf '%*s' "$WIDTH" '' | tr ' ' '·')"
    while IFS= read -r line; do
        if (( ${#line} > WIDTH )); then
            printf "      ${COLOR_YELLOW}%s${COLOR_RESET}\n" "$line"
        else
            printf "      ${COLOR_DIM}%s${COLOR_RESET}\n" "$line"
        fi
    done <<< "$1"
}

rewrite_commits() {
    local parent_override="" idx
    # Oldest first, so every commit already knows its (possibly new) parent.
    for (( idx = ${#C_SHAS[@]} - 1; idx >= 0; idx-- )); do
        local sha="${C_SHAS[idx]}"
        local short="${sha:0:7}"

        if [[ "${C_ACTIONS[idx]}" == "same" && -z "$parent_override" ]]; then
            echo -e "${COLOR_DIM}[--]   ${short}  ${C_SUBJECTS[idx]}${COLOR_RESET}"
            echo -e "${COLOR_DIM}         already within ${WIDTH} columns — left alone${COLOR_RESET}"
            continue
        fi

        log_info "${COLOR_BOLD}${short}${COLOR_RESET}  ${C_SUBJECTS[idx]}"

        local delta=$(( C_LINES_OUT[idx] - C_LINES_IN[idx] ))
        local delta_txt="same line count"
        (( delta > 0 )) && delta_txt="+${delta} line(s)"
        (( delta < 0 )) && delta_txt="${delta} line(s)"

        if [[ "${C_ACTIONS[idx]}" == "same" ]]; then
            log_info "  message unchanged — recreated because its parent moved"
        else
            log_info "  ${C_LINES_IN[idx]} → ${C_LINES_OUT[idx]} lines (${delta_txt}), ${C_OVER_IN[idx]} over ${WIDTH} (longest ${C_MAX_IN[idx]}) → ${C_OVER_OUT[idx]}"
            $VERBOSE && print_message "${C_MESSAGES[idx]}"
        fi

        if $DRY_RUN; then
            [[ "${C_ACTIONS[idx]}" == "wrap" ]] && REWRITTEN=$(( REWRITTEN + 1 )) || REBUILT=$(( REBUILT + 1 ))
            parent_override="dry-run"
            continue
        fi

        # Rebuild the commit: same tree, same author/committer, new message.
        local tree parents_line
        tree="$(git -C "$REPO_DIR" rev-parse "${sha}^{tree}")"
        parents_line="$(git -C "$REPO_DIR" rev-list --parents -n 1 "$sha")"

        local -a fields=() args=()
        read -ra fields <<< "$parents_line"
        local p first=true
        for p in "${fields[@]:1}"; do
            if $first; then
                first=false
                args+=( -p "${parent_override:-$p}" )
            else
                args+=( -p "$p" )   # merge side-parents are outside the range
            fi
        done
        $GPG_SIGN && args+=( -S )

        local meta an ae ad cn ce cd
        meta="$(git -C "$REPO_DIR" log -1 --format='%an%x09%ae%x09%aI%x09%cn%x09%ce%x09%cI' "$sha")"
        IFS=$'\t' read -r an ae ad cn ce cd <<< "$meta"

        local newsha
        if ! newsha="$(
            export GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad"
            export GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cd"
            printf '%s\n' "${C_MESSAGES[idx]}" | git -C "$REPO_DIR" commit-tree "${args[@]}" -F - "$tree"
        )"; then
            log_error "  Failed to create the rewritten commit — nothing has been moved"
            log_error "  Branch '${BRANCH}' still points at ${OLD_HEAD:0:7}"
            exit 1
        fi

        log_success "  ${short} → ${newsha:0:7}"
        parent_override="$newsha"
        [[ "${C_ACTIONS[idx]}" == "wrap" ]] && REWRITTEN=$(( REWRITTEN + 1 )) || REBUILT=$(( REBUILT + 1 ))
    done

    [[ -z "$parent_override" ]] && return 0
    $DRY_RUN && return 0

    local now_head
    now_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [[ "$now_head" != "$OLD_HEAD" ]]; then
        log_error "HEAD moved while running (${OLD_HEAD:0:7} → ${now_head:0:7}) — branch left untouched"
        log_error "The rewritten commits exist as ${parent_override:0:7} if you want them"
        exit 1
    fi

    if ! git -C "$REPO_DIR" update-ref -m "wrap-commits: rewrap ${REWRITTEN} message(s) to ${WIDTH} columns" \
        "refs/heads/${BRANCH}" "$parent_override" "$OLD_HEAD"; then
        log_error "Could not move '${BRANCH}' — the rewritten commits exist as ${parent_override:0:7}"
        exit 1
    fi
    return 0
}

# ── Phase 5: Summary ────────────────────────────────────────────────────────

print_summary() {
    local changed="$1"
    log_step "Summary"

    local verb="amended"
    $DRY_RUN && verb="would be amended"

    log_success "commits ${verb}: ${REWRITTEN}/${RANGE_N}"
    (( REBUILT > 0 )) && log_info "commits recreated unchanged (parent moved): ${REBUILT}"
    log_info "commits already within ${WIDTH} columns: $(( RANGE_N - changed ))"
    echo ""

    local net=$(( T_LINES_OUT - T_LINES_IN )) net_txt
    if   (( net > 0 )); then net_txt="+${net}"
    elif (( net < 0 )); then net_txt="${net}"
    else net_txt="±0"; fi
    log_info "lines: ${T_LINES_IN} → ${T_LINES_OUT} (${net_txt})"
    log_info "lines wider than ${WIDTH}: ${T_OVER_IN} → ${T_OVER_OUT}"
    log_info "longest line: ${T_MAX_IN} → ${T_MAX_OUT} characters"
    log_info "paragraphs reflowed: ${T_PARAS_REFLOWED}/${T_PARAS}"
    (( T_LITERAL > 0 ))         && log_info "lines kept verbatim (indented, fenced, quoted, trailers): ${T_LITERAL}"
    (( T_TRAILING_WS > 0 ))     && log_info "lines with trailing whitespace trimmed: ${T_TRAILING_WS}"
    (( T_SUBJ_OVER > 0 ))       && log_warn "subjects longer than ${WIDTH} (never rewrapped): ${T_SUBJ_OVER}"
    (( T_OVERFLOW_WORDS > 0 ))  && log_warn "words too long to fit (URLs, kept whole): ${T_OVERFLOW_WORDS}"
    (( T_OVER_OUT > 0 ))        && log_warn "lines still over ${WIDTH} afterwards: ${T_OVER_OUT}  ${COLOR_DIM}(subjects, verbatim lines, unbreakable words)${COLOR_RESET}"
    (( T_SIGNED > 0 )) && ! $GPG_SIGN && log_warn "signed commits in range: ${T_SIGNED} — a rewrite drops the signature (re-run with --gpg-sign)"

    echo ""
    if $DRY_RUN; then
        (( changed > 0 )) && log_info "Re-run without --dry-run to apply."
        return 0
    fi
    if (( REWRITTEN + REBUILT == 0 )); then
        log_info "Nothing was changed."
        return 0
    fi

    local new_head
    new_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
    log_success "'${BRANCH}' moved ${OLD_HEAD:0:7} → ${new_head:0:7}"
    log_info "undo: ${COLOR_BOLD}git reset --hard ${OLD_HEAD}${COLOR_RESET}"
    if (( PUBLISHED > 0 )); then
        log_warn "push with: ${COLOR_BOLD}git push --force-with-lease${COLOR_RESET}"
    fi
    log_info "took ${SECONDS}s"
    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    log_step "Inspecting repository"
    inspect_repo

    log_step "Analysing ${RANGE_N} commit(s)"
    analyse_commits
    present_plan

    local changed
    changed="$(count_changed)"

    if (( changed == 0 )); then
        log_success "Every message already fits ${WIDTH} columns — nothing to do"
        exit 0
    fi

    confirm_if_needed "$changed"

    log_step "$($DRY_RUN && echo "Rewrapping (dry run)" || echo "Rewrapping")"
    rewrite_commits

    print_summary "$changed"
    exit 0
}

main "$@"
