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

declare -a REPO_DIRS=()

declare -a PULLED_REPOS=()
declare -a PULLED_COMMITS=()
declare -a PULLED_STALENESS=()

declare -a SKIPPED_REPOS=()
declare -a SKIPPED_BRANCHES=()

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

# ── Repository discovery ───────────────────────────────────────────────────

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

# ── Per-repo processing ────────────────────────────────────────────────────

process_repos() {
    for repo_dir in "${REPO_DIRS[@]}"; do
        process_repo "$repo_dir"
    done
}

process_repo() {
    local repo_dir="$1"
    local repo_name
    repo_name=$(repo_display_name "$repo_dir")

    echo ""
    log_info "${COLOR_BOLD}${repo_name}${COLOR_RESET}"

    # Detect base branch
    local base_branch
    base_branch=$(get_base_branch "$repo_dir")
    if [[ -z "$base_branch" ]]; then
        log_error "  Could not detect base branch"
        FAILED_REPOS+=("$repo_name")
        FAILED_REASONS+=("could not detect base branch")
        return
    fi

    # Get current branch
    local current_branch
    current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
        log_error "  Detached HEAD state"
        FAILED_REPOS+=("$repo_name")
        FAILED_REASONS+=("detached HEAD")
        return
    fi

    # Handle non-base branch
    if [[ "$current_branch" != "$base_branch" ]]; then
        if ! handle_branch_switch "$repo_dir" "$repo_name" "$current_branch" "$base_branch"; then
            return
        fi
    fi

    pull_repo "$repo_dir" "$repo_name"
}

handle_branch_switch() {
    local repo_dir="$1"
    local repo_name="$2"
    local current_branch="$3"
    local base_branch="$4"

    # Check for uncommitted changes — never switch a dirty tree
    if ! git -C "$repo_dir" diff --quiet 2>/dev/null || ! git -C "$repo_dir" diff --cached --quiet 2>/dev/null; then
        log_warn "  On '${current_branch}' with uncommitted changes — skipping"
        SKIPPED_REPOS+=("$repo_name")
        SKIPPED_BRANCHES+=("${current_branch} (dirty)")
        return 1
    fi

    if [[ "$AUTO_YES" == true ]]; then
        log_info "  Switching '${current_branch}' → '${base_branch}'"
    else
        log_warn "  On '${current_branch}' (base: '${base_branch}')"
        read -rp "  Switch to '${base_branch}'? [y/N] " answer
        if [[ ! "${answer:-}" =~ ^[Yy]$ ]]; then
            log_info "  Skipped"
            SKIPPED_REPOS+=("$repo_name")
            SKIPPED_BRANCHES+=("$current_branch")
            return 1
        fi
    fi

    if ! git -C "$repo_dir" checkout "$base_branch" --quiet 2>/dev/null; then
        log_error "  Failed to checkout '${base_branch}'"
        FAILED_REPOS+=("$repo_name")
        FAILED_REASONS+=("checkout '${base_branch}' failed")
        return 1
    fi

    log_success "  Switched to '${base_branch}'"
    return 0
}

pull_repo() {
    local repo_dir="$1"
    local repo_name="$2"

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
        log_error "  Pull failed — local branch has diverged (rebase/merge needed)"
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

# ── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
    log_step "Summary"

    # Pulled
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

    # Skipped
    if [[ ${#SKIPPED_REPOS[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}Skipped (${#SKIPPED_REPOS[@]}):${COLOR_RESET}"
        printf "  ${COLOR_BOLD}%-30s %s${COLOR_RESET}\n" "REPOSITORY" "BRANCH"
        for i in "${!SKIPPED_REPOS[@]}"; do
            printf "  %-30s ${COLOR_YELLOW}%s${COLOR_RESET}\n" "${SKIPPED_REPOS[$i]}" "${SKIPPED_BRANCHES[$i]}"
        done
        echo ""
    fi

    # Failed
    if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
        echo -e "${COLOR_RED}Failed (${#FAILED_REPOS[@]}):${COLOR_RESET}"
        printf "  ${COLOR_BOLD}%-30s %s${COLOR_RESET}\n" "REPOSITORY" "REASON"
        for i in "${!FAILED_REPOS[@]}"; do
            printf "  %-30s ${COLOR_RED}%s${COLOR_RESET}\n" "${FAILED_REPOS[$i]}" "${FAILED_REASONS[$i]}"
        done
        echo ""
    fi

    # Totals
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

    log_step "Scanning for repositories"
    discover_repos

    log_step "Pulling repositories"
    process_repos

    print_summary

    [[ ${#FAILED_REPOS[@]} -gt 0 ]] && exit 1
    exit 0
}

main "$@"
