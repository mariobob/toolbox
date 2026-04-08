#!/usr/bin/env bash
set -euo pipefail

# Pull latest base branch in every git repository under a directory.
#
# Usage: pull-all [OPTIONS] [directory]
#
# Options:
#   -y, --yes    Auto-switch all repos to base branch without prompting
#   -h, --help   Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ── Globals ─────────────────────────────────────────────────────────────────

AUTO_YES=false
SCAN_DIR=""

# Per-repo state (parallel arrays, set during scan)
declare -a REPO_DIRS=()
declare -a REPO_NAMES=()
declare -a REPO_BRANCHES=()    # current branch
declare -a REPO_BASES=()       # detected base branch
declare -a REPO_STATES=()      # ready | needs_switch | dirty | error
declare -a REPO_ERRORS=()      # reason string (empty if none)
declare -a REPO_ACTIONS=()     # pull | skip (set after prompting)

# Result tracking (set during execution)
declare -a PULLED_REPOS=()
declare -a PULLED_COMMITS=()
declare -a PULLED_STALENESS=()
declare -a SKIPPED_REPOS=()
declare -a SKIPPED_REASONS=()
declare -a FAILED_REPOS=()
declare -a FAILED_REASONS=()

# ── Argument parsing ────────────────────────────────────────────────────────

usage() {
    sed -n '3,9p' "$0" | sed 's/^# \?//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)  AUTO_YES=true; shift ;;
            -h|--help) usage ;;
            -*)        log_error "Unknown option: $1"; usage ;;
            *)         SCAN_DIR="$1"; shift ;;
        esac
    done

    SCAN_DIR="${SCAN_DIR:-.}"

    if [[ ! -d "$SCAN_DIR" ]]; then
        log_error "Not a directory: $SCAN_DIR"
        exit 1
    fi

    SCAN_DIR="$(cd "$SCAN_DIR" && pwd)"
}

# ── Helpers ─────────────────────────────────────────────────────────────────

get_base_branch() {
    local repo_dir="$1"
    local head_ref
    head_ref=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo "")
    if [[ -n "$head_ref" ]]; then
        echo "${head_ref##*/}"
        return
    fi
    for branch in develop staging main master; do
        if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
            echo "$branch"
            return
        fi
    done
}

format_duration() {
    local seconds="$1"
    if (( seconds < 0 )); then seconds=0; fi
    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$(( seconds / 60 ))m"
    elif (( seconds < 86400 )); then
        echo "$(( seconds / 3600 ))h $(( seconds % 3600 / 60 ))m"
    else
        echo "$(( seconds / 86400 ))d $(( seconds % 86400 / 3600 ))h"
    fi
}

repo_display_name() {
    local repo_dir="$1"
    if [[ "$repo_dir" == "$SCAN_DIR" ]]; then
        basename "$repo_dir"
    else
        echo "${repo_dir#"$SCAN_DIR"/}"
    fi
}

# Parse a selection string like "1,3,5" or "1-3,5" into 0-based indices on stdout.
# Errors go to stderr. Returns non-zero on invalid input.
parse_selection() {
    local input="$1"
    local max="$2"
    local -a indices=()

    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part="$(echo "$part" | tr -d ' ')"
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
            if (( from < 1 || to > max || from > to )); then
                echo "Invalid range: $part (valid: 1-$max)" >&2
                return 1
            fi
            for (( n=from; n<=to; n++ )); do
                indices+=($((n - 1)))
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if (( part < 1 || part > max )); then
                echo "Invalid number: $part (valid: 1-$max)" >&2
                return 1
            fi
            indices+=($((part - 1)))
        else
            echo "Invalid selection: $part" >&2
            return 1
        fi
    done

    printf '%s\n' "${indices[@]}" | sort -nu
}

# ── Phase 1: Discover ──────────────────────────────────────────────────────

discover_repos() {
    while IFS= read -r git_dir; do
        REPO_DIRS+=("${git_dir%/.git}")
    done < <(find "$SCAN_DIR" -maxdepth 3 -name .git -type d 2>/dev/null | sort)

    if [[ ${#REPO_DIRS[@]} -eq 0 ]]; then
        log_warn "No git repositories found under $SCAN_DIR"
        exit 0
    fi

    log_info "Found ${#REPO_DIRS[@]} repositories"
}

# ── Phase 2: Scan (no I/O — local git state only) ──────────────────────────

scan_repos() {
    for repo_dir in "${REPO_DIRS[@]}"; do
        local repo_name
        repo_name=$(repo_display_name "$repo_dir")
        REPO_NAMES+=("$repo_name")

        # Detect base branch
        local base_branch
        base_branch=$(get_base_branch "$repo_dir")
        REPO_BASES+=("${base_branch:-}")

        if [[ -z "$base_branch" ]]; then
            REPO_BRANCHES+=("—")
            REPO_STATES+=("error")
            REPO_ERRORS+=("no base branch detected")
            REPO_ACTIONS+=("skip")
            continue
        fi

        # Get current branch
        local current_branch
        current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
            REPO_BRANCHES+=("HEAD (detached)")
            REPO_STATES+=("error")
            REPO_ERRORS+=("detached HEAD")
            REPO_ACTIONS+=("skip")
            continue
        fi

        REPO_BRANCHES+=("$current_branch")

        if [[ "$current_branch" == "$base_branch" ]]; then
            REPO_STATES+=("ready")
            REPO_ERRORS+=("")
            REPO_ACTIONS+=("pull")
        elif ! git -C "$repo_dir" diff --quiet 2>/dev/null || ! git -C "$repo_dir" diff --cached --quiet 2>/dev/null; then
            REPO_STATES+=("dirty")
            REPO_ERRORS+=("uncommitted changes on '${current_branch}'")
            REPO_ACTIONS+=("skip")
        else
            REPO_STATES+=("needs_switch")
            REPO_ERRORS+=("")
            REPO_ACTIONS+=("pending")
        fi
    done
}

# ── Phase 3: Present & Prompt ──────────────────────────────────────────────

present_scan() {
    # Calculate column widths from actual data (capped at 80 to keep it readable)
    local max_name=10 max_branch=6 max_base=4
    for i in "${!REPO_NAMES[@]}"; do
        local nl=${#REPO_NAMES[$i]} bl=${#REPO_BRANCHES[$i]} bal=${#REPO_BASES[$i]}
        (( nl  > max_name   )) && max_name=$nl
        (( bl  > max_branch )) && max_branch=$bl
        (( bal > max_base   )) && max_base=$bal
    done
    (( max_name   > 80 )) && max_name=80
    (( max_branch > 80 )) && max_branch=80
    (( max_base   > 80 )) && max_base=80
    # Add 2 chars of gutter between columns
    local wn=$(( max_name + 2 )) wb=$(( max_branch + 2 )) wba=$(( max_base + 2 ))

    echo ""
    printf "  ${COLOR_BOLD}%-${wn}s %-${wb}s %-${wba}s %s${COLOR_RESET}\n" "REPOSITORY" "BRANCH" "BASE" "STATUS"
    printf "  %-${wn}s %-${wb}s %-${wba}s %s\n" "----------" "------" "----" "------"

    for i in "${!REPO_NAMES[@]}"; do
        local status_text status_color
        case "${REPO_STATES[$i]}" in
            ready)        status_text="ready";              status_color="$COLOR_GREEN"  ;;
            needs_switch) status_text="switch?";            status_color="$COLOR_YELLOW" ;;
            dirty)        status_text="dirty — skip";       status_color="$COLOR_YELLOW" ;;
            error)        status_text="${REPO_ERRORS[$i]}";  status_color="$COLOR_RED"    ;;
        esac

        printf "  %-${wn}s %-${wb}s %-${wba}s ${status_color}%s${COLOR_RESET}\n" \
            "${REPO_NAMES[$i]}" "${REPO_BRANCHES[$i]}" "${REPO_BASES[$i]:-—}" "$status_text"
    done

    # Count by state
    local ready=0 switch=0 dirty=0 errors=0
    for state in "${REPO_STATES[@]}"; do
        case "$state" in
            ready)        ready=$((ready + 1)) ;;
            needs_switch) switch=$((switch + 1)) ;;
            dirty)        dirty=$((dirty + 1)) ;;
            error)        errors=$((errors + 1)) ;;
        esac
    done

    echo ""
    local parts=()
    (( ready  > 0 )) && parts+=("${COLOR_GREEN}${ready} ready${COLOR_RESET}")
    (( switch > 0 )) && parts+=("${COLOR_YELLOW}${switch} need switch${COLOR_RESET}")
    (( dirty  > 0 )) && parts+=("${COLOR_YELLOW}${dirty} dirty${COLOR_RESET}")
    (( errors > 0 )) && parts+=("${COLOR_RED}${errors} error${COLOR_RESET}")
    local IFS=", "
    echo -e "  ${parts[*]}"
}

prompt_switches() {
    # Collect indices of repos that need a decision
    local -a switch_indices=()
    for i in "${!REPO_STATES[@]}"; do
        [[ "${REPO_STATES[$i]}" == "needs_switch" ]] && switch_indices+=("$i")
    done

    if [[ ${#switch_indices[@]} -eq 0 ]]; then
        return
    fi

    # Auto-switch with -y
    if [[ "$AUTO_YES" == true ]]; then
        for idx in "${switch_indices[@]}"; do
            REPO_ACTIONS[$idx]="pull"
        done
        log_info "Auto-switching ${#switch_indices[@]} repos to base branch (-y)"
        return
    fi

    # Show numbered list
    echo ""
    log_warn "Repos not on base branch:"
    for n in "${!switch_indices[@]}"; do
        local idx="${switch_indices[$n]}"
        printf "  ${COLOR_BOLD}%2d${COLOR_RESET}) %-28s %s → %s\n" \
            "$((n + 1))" "${REPO_NAMES[$idx]}" "${REPO_BRANCHES[$idx]}" "${REPO_BASES[$idx]}"
    done
    echo ""

    read -rp "Switch all ${#switch_indices[@]} repos to base branch? [Y/n] " answer
    if [[ "${answer:-Y}" =~ ^[Yy]$ ]]; then
        for idx in "${switch_indices[@]}"; do
            REPO_ACTIONS[$idx]="pull"
        done
        return
    fi

    # Selective switching — default all to skip, then mark selected for pull
    for idx in "${switch_indices[@]}"; do
        REPO_ACTIONS[$idx]="skip"
    done

    read -rp "Select which to switch (e.g. 1,3 or 1-3), or Enter to skip all: " selection
    if [[ -z "$selection" ]]; then
        log_info "Skipping all branch switches"
        return
    fi

    local selection_output
    if ! selection_output=$(parse_selection "$selection" "${#switch_indices[@]}"); then
        log_warn "Invalid selection — skipping all"
        return
    fi

    local -a selected
    mapfile -t selected <<< "$selection_output"

    for sel_idx in "${selected[@]}"; do
        REPO_ACTIONS[${switch_indices[$sel_idx]}]="pull"
    done
}

# ── Phase 4: Execute (all I/O happens here — no more prompts) ──────────────

execute_pulls() {
    # Safety: resolve any remaining pending actions
    for i in "${!REPO_ACTIONS[@]}"; do
        [[ "${REPO_ACTIONS[$i]}" == "pending" ]] && REPO_ACTIONS[$i]="skip"
    done

    # Count repos to pull
    local pull_count=0
    for action in "${REPO_ACTIONS[@]}"; do
        [[ "$action" == "pull" ]] && pull_count=$((pull_count + 1))
    done

    if [[ $pull_count -eq 0 ]]; then
        log_warn "No repositories to pull"
    else
        log_info "Pulling ${pull_count} repositories ..."
        for i in "${!REPO_DIRS[@]}"; do
            [[ "${REPO_ACTIONS[$i]}" != "pull" ]] && continue
            execute_single_repo "$i"
        done
    fi

    # Record skipped repos
    for i in "${!REPO_DIRS[@]}"; do
        if [[ "${REPO_ACTIONS[$i]}" == "skip" ]]; then
            SKIPPED_REPOS+=("${REPO_NAMES[$i]}")
            case "${REPO_STATES[$i]}" in
                needs_switch) SKIPPED_REASONS+=("on '${REPO_BRANCHES[$i]}'") ;;
                dirty)        SKIPPED_REASONS+=("${REPO_BRANCHES[$i]} (dirty)") ;;
                error)        SKIPPED_REASONS+=("${REPO_ERRORS[$i]}") ;;
                *)            SKIPPED_REASONS+=("skipped") ;;
            esac
        fi
    done
}

execute_single_repo() {
    local i="$1"
    local repo_dir="${REPO_DIRS[$i]}"
    local repo_name="${REPO_NAMES[$i]}"
    local base_branch="${REPO_BASES[$i]}"

    echo ""
    log_info "${COLOR_BOLD}${repo_name}${COLOR_RESET}"

    # Switch branch if needed
    if [[ "${REPO_STATES[$i]}" == "needs_switch" ]]; then
        log_info "  Switching '${REPO_BRANCHES[$i]}' → '${base_branch}'"
        if ! git -C "$repo_dir" checkout "$base_branch" --quiet 2>/dev/null; then
            log_error "  Failed to checkout '${base_branch}'"
            FAILED_REPOS+=("$repo_name")
            FAILED_REASONS+=("checkout '${base_branch}' failed")
            return
        fi
        log_success "  Switched to '${base_branch}'"
    fi

    # Record pre-pull state
    local old_head
    old_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    local old_timestamp
    old_timestamp=$(git -C "$repo_dir" log -1 --format=%ct 2>/dev/null || echo "0")

    # Fetch
    if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
        log_error "  Fetch failed (network issue or missing remote)"
        FAILED_REPOS+=("$repo_name")
        FAILED_REASONS+=("fetch failed")
        return
    fi

    # Pull (fast-forward only — never creates merge commits)
    if ! git -C "$repo_dir" pull --ff-only --quiet 2>/dev/null; then
        log_error "  Pull failed — local branch has diverged"
        FAILED_REPOS+=("$repo_name")
        FAILED_REASONS+=("not fast-forwardable")
        return
    fi

    # Calculate results
    local new_head
    new_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")

    local commit_count=0
    if [[ -n "$old_head" && -n "$new_head" && "$old_head" != "$new_head" ]]; then
        commit_count=$(git -C "$repo_dir" rev-list "${old_head}..${new_head}" --count 2>/dev/null || echo "0")
    fi

    local staleness="up to date"
    if [[ "$commit_count" -gt 0 ]]; then
        local now
        now=$(date +%s)
        local behind_seconds=$(( now - old_timestamp ))
        staleness=$(format_duration "$behind_seconds")
        log_success "  Pulled ${COLOR_BOLD}${commit_count}${COLOR_RESET}${COLOR_GREEN} commit(s) — was ${staleness} behind${COLOR_RESET}"
    else
        log_success "  Already up to date"
    fi

    PULLED_REPOS+=("$repo_name")
    PULLED_COMMITS+=("$commit_count")
    PULLED_STALENESS+=("$staleness")
}

# ── Phase 5: Summary ───────────────────────────────────────────────────────

print_summary() {
    log_step "Summary"

    if [[ ${#PULLED_REPOS[@]} -gt 0 ]]; then
        echo -e "${COLOR_GREEN}Pulled (${#PULLED_REPOS[@]}):${COLOR_RESET}"
        printf "  ${COLOR_BOLD}%-30s %-10s %s${COLOR_RESET}\n" "REPOSITORY" "COMMITS" "WAS BEHIND"
        for i in "${!PULLED_REPOS[@]}"; do
            if [[ "${PULLED_COMMITS[$i]}" -eq 0 ]]; then
                printf "  ${COLOR_DIM}%-30s %-10s %s${COLOR_RESET}\n" "${PULLED_REPOS[$i]}" "—" "up to date"
            else
                printf "  %-30s ${COLOR_GREEN}%-10s${COLOR_RESET} %s\n" "${PULLED_REPOS[$i]}" "+${PULLED_COMMITS[$i]}" "${PULLED_STALENESS[$i]}"
            fi
        done
        echo ""
    fi

    if [[ ${#SKIPPED_REPOS[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}Skipped (${#SKIPPED_REPOS[@]}):${COLOR_RESET}"
        printf "  ${COLOR_BOLD}%-30s %s${COLOR_RESET}\n" "REPOSITORY" "REASON"
        for i in "${!SKIPPED_REPOS[@]}"; do
            printf "  %-30s ${COLOR_YELLOW}%s${COLOR_RESET}\n" "${SKIPPED_REPOS[$i]}" "${SKIPPED_REASONS[$i]}"
        done
        echo ""
    fi

    if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
        echo -e "${COLOR_RED}Failed (${#FAILED_REPOS[@]}):${COLOR_RESET}"
        printf "  ${COLOR_BOLD}%-30s %s${COLOR_RESET}\n" "REPOSITORY" "REASON"
        for i in "${!FAILED_REPOS[@]}"; do
            printf "  %-30s ${COLOR_RED}%s${COLOR_RESET}\n" "${FAILED_REPOS[$i]}" "${FAILED_REASONS[$i]}"
        done
        echo ""
    fi

    local total=$(( ${#PULLED_REPOS[@]} + ${#SKIPPED_REPOS[@]} + ${#FAILED_REPOS[@]} ))
    local total_commits=0
    for c in ${PULLED_COMMITS[@]+"${PULLED_COMMITS[@]}"}; do
        total_commits=$(( total_commits + c ))
    done

    echo -e "${COLOR_BOLD}${total} repositories: ${COLOR_GREEN}${#PULLED_REPOS[@]} pulled (+${total_commits} commits)${COLOR_RESET}${COLOR_BOLD}, ${COLOR_YELLOW}${#SKIPPED_REPOS[@]} skipped${COLOR_RESET}${COLOR_BOLD}, ${COLOR_RED}${#FAILED_REPOS[@]} failed${COLOR_RESET}"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    log_step "Scanning repositories"
    discover_repos
    scan_repos
    present_scan
    prompt_switches

    log_step "Pulling repositories"
    execute_pulls

    print_summary

    [[ ${#FAILED_REPOS[@]} -gt 0 ]] && exit 1
    exit 0
}

main "$@"
